import Foundation

struct GitWorktreeInspection: Equatable {
    let isRegisteredWorktree: Bool
    let isLinkedWorktree: Bool
    let isLocked: Bool
    let mainWorktreePath: String?
    let branchName: String?
    let statusEntries: [String]?
    let uniqueCommitCount: Int?
    let failureReasons: [String]
}

struct WorktreeCleanupScanner {
    var fileExists: (String) -> Bool
    var resolveWorktreeRoot: (String) -> String?
    var inspectGit: (String) -> GitWorktreeInspection
    var measureSize: (String) -> Int64?

    static func live() -> WorktreeCleanupScanner {
        let inspector = GitWorktreeInspector()
        return WorktreeCleanupScanner(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            resolveWorktreeRoot: { inspector.worktreeRoot(containing: $0) },
            inspectGit: { inspector.inspect(path: $0) },
            measureSize: { DirectorySizeScanner.sizeOfDirectory(atPath: $0) }
        )
    }

    func candidates(
        from sourceSessions: [Session],
        activeProjectPaths: Set<String>
    ) -> [WorktreeCleanupCandidate] {
        let activePaths = Set(activeProjectPaths.map(Self.standardizedPath))
        let contexts = candidateContexts(from: sourceSessions)

        return contexts.values
            .map { candidate(from: $0, activeProjectPaths: activePaths) }
            .sorted { lhs, rhs in
                if lhs.state.sortOrder != rhs.state.sortOrder {
                    return lhs.state.sortOrder < rhs.state.sortOrder
                }
                return lhs.lastActiveAt > rhs.lastActiveAt
            }
    }

    private func candidateContexts(from sessions: [Session]) -> [String: CandidateContext] {
        latestEndedSessionContextsByPath(sessions)
    }

    private func latestEndedSessionContextsByPath(_ sessions: [Session]) -> [String: CandidateContext] {
        var result: [String: CandidateContext] = [:]
        var resolvedPaths: [String: String] = [:]
        for session in sessions {
            guard session.endedAt != nil else { continue }
            let rawPath = Self.standardizedPath(session.projectPath)
            let path = resolvedPaths[rawPath] ?? {
                let resolvedPath = fileExists(rawPath) ? resolveWorktreeRoot(rawPath).map(Self.standardizedPath) : nil
                let path = resolvedPath ?? rawPath
                resolvedPaths[rawPath] = path
                return path
            }()
            guard let existing = result[path] else {
                result[path] = CandidateContext(session: session, path: path)
                continue
            }
            if session.effectiveEndDate > existing.lastActiveAt {
                result[path] = CandidateContext(session: session, path: path)
            }
        }
        return result
    }

    private func candidate(from context: CandidateContext, activeProjectPaths: Set<String>) -> WorktreeCleanupCandidate {
        guard !isProtectedByActiveSession(context.path, activeProjectPaths: activeProjectPaths) else {
            return ignoredCandidate(
                context: context,
                state: .ignored(["Active cctop session is using this path"]),
                checks: [WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ignored)]
            )
        }

        guard fileExists(context.path) else {
            return ignoredCandidate(
                context: context,
                state: .ignored(["Path no longer exists"]),
                checks: [WorktreeCleanupCheck(label: "Worktree path exists", status: .ignored)]
            )
        }

        let inspection = inspectGit(context.path)
        let branchName = inspection.branchName ?? context.fallbackBranch
        guard inspection.isRegisteredWorktree else {
            return ignoredCandidate(
                context: context,
                branchName: branchName,
                state: .ignored(inspection.failureReasons.nonEmptyOr(["Path is not a registered Git worktree"])),
                checks: [WorktreeCleanupCheck(label: "Path is a registered Git worktree", status: .ignored)]
            )
        }
        guard inspection.isLinkedWorktree else {
            return ignoredCandidate(
                context: context,
                branchName: branchName,
                state: .ignored(["Path is the main checkout, not a linked worktree"]),
                checks: [WorktreeCleanupCheck(label: "Path is a linked Git worktree", status: .ignored)]
            )
        }

        return inspectedCandidate(
            context: context,
            branchName: branchName,
            inspection: inspection,
            storageBytes: measureSize(context.path)
        )
    }

    private func isProtectedByActiveSession(_ path: String, activeProjectPaths: Set<String>) -> Bool {
        let descendantPrefix = path.hasSuffix("/") ? path : "\(path)/"
        return activeProjectPaths.contains { activePath in
            activePath == path || activePath.hasPrefix(descendantPrefix)
        }
    }

    private func ignoredCandidate(
        context: CandidateContext,
        branchName: String? = nil,
        state: WorktreeCleanupCandidate.State,
        checks: [WorktreeCleanupCheck]
    ) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            id: context.path,
            sessionName: context.sessionName,
            worktreePath: context.path,
            worktreeName: context.worktreeName,
            branchName: context.displayBranch(branchName),
            lastActiveAt: context.lastActiveAt,
            storageBytes: nil,
            state: state,
            checks: checks
        )
    }

    private func inspectedCandidate(
        context: CandidateContext,
        branchName: String,
        inspection: GitWorktreeInspection,
        storageBytes: Int64?
    ) -> WorktreeCleanupCandidate {
        let reasons = reviewReasons(for: inspection, storageBytes: storageBytes)
        let state: WorktreeCleanupCandidate.State = reasons.isEmpty ? .clean : .review(reasons)
        let reviewEvidence = Self.reviewEvidence(for: inspection)

        return WorktreeCleanupCandidate(
            id: context.path,
            sessionName: context.sessionName,
            worktreePath: context.path,
            worktreeName: context.worktreeName,
            branchName: context.displayBranch(branchName),
            lastActiveAt: context.lastActiveAt,
            storageBytes: storageBytes,
            state: state,
            checks: checks(for: inspection, storageBytes: storageBytes, active: true),
            reviewEvidence: reviewEvidence
        )
    }

    private func reviewReasons(for inspection: GitWorktreeInspection, storageBytes: Int64?) -> [String] {
        var reasons = inspection.failureReasons
        if inspection.branchName?.isEmpty ?? true {
            reasons.appendUnique("Branch is unknown or detached")
        }
        if inspection.mainWorktreePath == nil {
            reasons.appendUnique("Main checkout path could not be verified")
        }
        if inspection.isLocked {
            reasons.appendUnique("Worktree is locked")
        }
        if let statusEntries = inspection.statusEntries {
            if !Self.untrackedPaths(fromStatusEntries: statusEntries).isEmpty {
                reasons.appendUnique(WorktreeCleanupCandidate.untrackedFilesReason)
            }
            if !Self.ignoredPaths(fromStatusEntries: statusEntries).isEmpty {
                reasons.appendUnique(WorktreeCleanupCandidate.ignoredFilesReason)
            }
            if Self.hasTrackedChanges(fromStatusEntries: statusEntries) {
                reasons.appendUnique("Worktree has uncommitted tracked changes")
            }
        } else {
            reasons.appendUnique("Git status could not be read")
        }
        if let count = inspection.uniqueCommitCount {
            if count > 0 {
                reasons.appendUnique("Branch has \(count) unique local commit\(count == 1 ? "" : "s")")
            }
        } else if !reasons.contains(where: Self.isCommitSafetyReason) {
            reasons.appendUnique("Branch upstream or commit safety could not be verified")
        }
        return reasons
    }

    private static func isCommitSafetyReason(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("upstream")
            || reason.localizedCaseInsensitiveContains("commit")
            || reason.localizedCaseInsensitiveContains("Branch is unknown")
    }

    static func untrackedPaths(fromStatusEntries entries: [String]) -> [String] {
        paths(fromStatusEntries: entries, prefix: "?? ")
    }

    static func ignoredPaths(fromStatusEntries entries: [String]) -> [String] {
        paths(fromStatusEntries: entries, prefix: "!! ")
    }

    static func hasTrackedChanges(fromStatusEntries entries: [String]) -> Bool {
        entries.contains { entry in
            guard entry.count >= 3,
                  entry[entry.index(entry.startIndex, offsetBy: 2)] == " " else {
                return false
            }
            guard !entry.hasPrefix("?? "), !entry.hasPrefix("!! ") else {
                return false
            }
            return entry.prefix(2).contains { $0 != " " }
        }
    }

    private static func paths(fromStatusEntries entries: [String], prefix: String) -> [String] {
        entries.compactMap { entry in
            guard entry.hasPrefix(prefix) else { return nil }
            return String(entry.dropFirst(prefix.count))
        }
    }

    static func reviewEvidence(for inspection: GitWorktreeInspection) -> WorktreeCleanupReviewEvidence {
        guard let statusEntries = inspection.statusEntries else {
            return .empty
        }
        let untrackedPreview = WorktreeCleanupUntrackedPreview(paths: untrackedPaths(fromStatusEntries: statusEntries))
        let ignoredPreview = WorktreeCleanupUntrackedPreview(paths: ignoredPaths(fromStatusEntries: statusEntries))
        guard untrackedPreview != nil || ignoredPreview != nil else {
            return .empty
        }
        return WorktreeCleanupReviewEvidence(
            untrackedPreview: untrackedPreview,
            ignoredPreview: ignoredPreview
        )
    }

    private func checks(
        for inspection: GitWorktreeInspection,
        storageBytes: Int64?,
        active: Bool
    ) -> [WorktreeCleanupCheck] {
        let statusEntries = inspection.statusEntries ?? []
        let statusUnavailable = inspection.statusEntries == nil
        let trackedDirty = Self.hasTrackedChanges(fromStatusEntries: statusEntries)
        let untrackedDirty = !Self.untrackedPaths(fromStatusEntries: statusEntries).isEmpty
        let ignoredDirty = !Self.ignoredPaths(fromStatusEntries: statusEntries).isEmpty
        let commitCount = inspection.uniqueCommitCount
        return [
            WorktreeCleanupCheck(label: "No active cctop sessions here", status: active ? .ok : .ignored),
            WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: inspection.isLinkedWorktree ? .ok : .ignored),
            WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: statusUnavailable || trackedDirty ? .review : .ok),
            WorktreeCleanupCheck(label: "No untracked files", status: statusUnavailable || untrackedDirty ? .review : .ok),
            WorktreeCleanupCheck(label: "No ignored files", status: statusUnavailable || ignoredDirty ? .review : .ok),
            WorktreeCleanupCheck(label: "Branch has no unique local commits", status: commitCount == 0 ? .ok : .review),
            WorktreeCleanupCheck(label: "Main checkout path is known", status: inspection.mainWorktreePath == nil ? .review : .ok),
            WorktreeCleanupCheck(label: "Worktree is not locked", status: inspection.isLocked ? .review : .ok),
            WorktreeCleanupCheck(label: "Storage size scan completed", status: storageBytes == nil ? .ignored : .ok),
        ]
    }

    static func standardizedPath(_ path: String) -> String {
        Config.standardizedPath(path)
    }
}

private struct CandidateContext {
    let sessionName: String
    let path: String
    let worktreeName: String
    let fallbackBranch: String
    let lastActiveAt: Date

    init(session: Session, path: String? = nil) {
        self.path = path ?? WorktreeCleanupScanner.standardizedPath(session.projectPath)
        sessionName = session.displayName
        worktreeName = URL(fileURLWithPath: self.path).lastPathComponent
        fallbackBranch = session.branch
        lastActiveAt = session.effectiveEndDate
    }

    func displayBranch(_ branchName: String?) -> String {
        let branch = branchName ?? fallbackBranch
        return branch.isEmpty ? "unknown" : branch
    }
}

private extension WorktreeCleanupCandidate.State {
    var sortOrder: Int {
        switch self {
        case .clean: return 0
        case .review: return 1
        case .ignored: return 2
        }
    }
}

private extension Array where Element == String {
    func nonEmptyOr(_ fallback: [String]) -> [String] {
        isEmpty ? fallback : self
    }

    mutating func appendUnique(_ reason: String) {
        guard !contains(reason) else { return }
        append(reason)
    }
}
