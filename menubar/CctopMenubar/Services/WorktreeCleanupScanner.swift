import Foundation

struct GitWorktreeInspection: Equatable {
    let isRegisteredWorktree: Bool
    let isLinkedWorktree: Bool
    let mainWorktreePath: String?
    let branchName: String?
    let statusEntries: [String]?
    let uniqueCommitCount: Int?
    let failureReasons: [String]
}

struct WorktreeCleanupScanner {
    var fileExists: (String) -> Bool
    var inspectGit: (String) -> GitWorktreeInspection
    var measureSize: (String) -> Int64?

    static func live() -> WorktreeCleanupScanner {
        let inspector = GitWorktreeInspector()
        return WorktreeCleanupScanner(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
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
        for session in sessions {
            guard session.endedAt != nil else { continue }
            let path = Self.standardizedPath(session.projectPath)
            guard let existing = result[path] else {
                result[path] = CandidateContext(session: session)
                continue
            }
            if session.effectiveEndDate > existing.lastActiveAt {
                result[path] = CandidateContext(session: session)
            }
        }
        return result
    }

    private func candidate(from context: CandidateContext, activeProjectPaths: Set<String>) -> WorktreeCleanupCandidate {
        guard !activeProjectPaths.contains(context.path) else {
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
            suggestedCommand: nil,
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
        let command = state.isClean ? suggestedCommand(mainWorktreePath: inspection.mainWorktreePath, worktreePath: context.path) : nil
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
            suggestedCommand: command,
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
        if let statusEntries = inspection.statusEntries {
            if !Self.untrackedPaths(fromStatusEntries: statusEntries).isEmpty {
                reasons.appendUnique(WorktreeCleanupCandidate.untrackedFilesReason)
            }
            if statusEntries.contains(where: { !$0.hasPrefix("??") }) {
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
        if storageBytes == nil {
            reasons.appendUnique("Storage size scan failed")
        }
        return reasons
    }

    private static func isCommitSafetyReason(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("upstream")
            || reason.localizedCaseInsensitiveContains("commit")
            || reason.localizedCaseInsensitiveContains("Branch is unknown")
    }

    static func untrackedPaths(fromStatusEntries entries: [String]) -> [String] {
        entries.compactMap { entry in
            guard entry.hasPrefix("?? ") else { return nil }
            return String(entry.dropFirst(3))
        }
    }

    static func reviewEvidence(for inspection: GitWorktreeInspection) -> WorktreeCleanupReviewEvidence {
        guard let statusEntries = inspection.statusEntries,
              let preview = WorktreeCleanupUntrackedPreview(paths: untrackedPaths(fromStatusEntries: statusEntries)) else {
            return .empty
        }
        return WorktreeCleanupReviewEvidence(untrackedPreview: preview)
    }

    private func checks(
        for inspection: GitWorktreeInspection,
        storageBytes: Int64?,
        active: Bool
    ) -> [WorktreeCleanupCheck] {
        let statusEntries = inspection.statusEntries ?? []
        let statusUnavailable = inspection.statusEntries == nil
        let trackedDirty = statusEntries.contains { !$0.hasPrefix("??") }
        let untrackedDirty = !Self.untrackedPaths(fromStatusEntries: statusEntries).isEmpty
        let commitCount = inspection.uniqueCommitCount
        return [
            WorktreeCleanupCheck(label: "No active cctop sessions here", status: active ? .ok : .ignored),
            WorktreeCleanupCheck(label: "Path is a registered linked worktree", status: inspection.isLinkedWorktree ? .ok : .ignored),
            WorktreeCleanupCheck(label: "No uncommitted tracked changes", status: statusUnavailable || trackedDirty ? .review : .ok),
            WorktreeCleanupCheck(label: "No untracked files", status: statusUnavailable || untrackedDirty ? .review : .ok),
            WorktreeCleanupCheck(label: "Branch has no unique local commits", status: commitCount == 0 ? .ok : .review),
            WorktreeCleanupCheck(label: "Main checkout path is known", status: inspection.mainWorktreePath == nil ? .review : .ok),
            WorktreeCleanupCheck(label: "Storage size scan completed", status: storageBytes == nil ? .review : .ok),
        ]
    }

    private func suggestedCommand(mainWorktreePath: String?, worktreePath: String) -> String? {
        guard let mainWorktreePath else { return nil }
        return "git -C \(Self.shellQuote(mainWorktreePath)) worktree remove \(Self.shellQuote(worktreePath))"
    }

    static func standardizedPath(_ path: String) -> String {
        Config.standardizedPath(path)
    }

    static func shellQuote(_ path: String) -> String {
        guard path.range(of: #"^[A-Za-z0-9_@%+=:,./-]+$"#, options: .regularExpression) == nil else {
            return path
        }
        return "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

private struct CandidateContext {
    let sessionName: String
    let path: String
    let worktreeName: String
    let fallbackBranch: String
    let lastActiveAt: Date

    init(session: Session) {
        path = WorktreeCleanupScanner.standardizedPath(session.projectPath)
        sessionName = session.displayName
        worktreeName = URL(fileURLWithPath: path).lastPathComponent
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
