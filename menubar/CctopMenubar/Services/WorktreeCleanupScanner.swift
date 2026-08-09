import Foundation

/// Minimal session-derived row that the session classifier has deemed safe to use as a cleanup
/// starting point. The scanner intentionally knows nothing about cctop lifecycle, archive state,
/// host metadata, or process liveness; it only validates the filesystem/git worktree from here.
struct SessionDataCleanupSource: Equatable {
    let sessionId: String
    let projectPath: String
    let sessionName: String
    let branch: String
    let lastActiveAt: Date

    init(data: SessionData) {
        sessionId = data.sessionId
        projectPath = data.projectPath
        sessionName = data.displayName
        branch = data.branch
        lastActiveAt = data.effectiveEndDate
    }

    init?(endedSession data: SessionData) {
        guard data.endedAt != nil else { return nil }
        self.init(data: data)
    }
}

struct GitWorktreeInspection: Equatable {
    let isRegisteredWorktree: Bool
    let isLinkedWorktree: Bool
    let isLocked: Bool
    let mainWorktreePath: String?
    let branchName: String?
    let headRevision: String?
    let statusEntries: [String]?
    let uniqueCommitCount: Int?
    let failureReasons: [String]

    init(
        isRegisteredWorktree: Bool,
        isLinkedWorktree: Bool,
        isLocked: Bool,
        mainWorktreePath: String?,
        branchName: String?,
        headRevision: String? = nil,
        statusEntries: [String]?,
        uniqueCommitCount: Int?,
        failureReasons: [String]
    ) {
        self.isRegisteredWorktree = isRegisteredWorktree
        self.isLinkedWorktree = isLinkedWorktree
        self.isLocked = isLocked
        self.mainWorktreePath = mainWorktreePath
        self.branchName = branchName
        self.headRevision = headRevision
        self.statusEntries = statusEntries
        self.uniqueCommitCount = uniqueCommitCount
        self.failureReasons = failureReasons
    }
}

struct WorktreeCleanupScanner {
    var fileExists: (String) -> Bool
    var resolveWorktreeRoot: (String) -> String?
    var inspectGit: (String) -> GitWorktreeInspection
    var measureSize: (String) -> Int64?
    var resolveLinkedWorktreeRoot: (String) -> String? = { _ in nil }

    static func live() -> WorktreeCleanupScanner {
        let inspector = GitWorktreeInspector()
        return WorktreeCleanupScanner(
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            resolveWorktreeRoot: { inspector.worktreeRoot(containing: $0) },
            inspectGit: { inspector.inspect(path: $0) },
            measureSize: { DirectorySizeScanner.sizeOfDirectory(atPath: $0) },
            resolveLinkedWorktreeRoot: { inspector.linkedWorktreeRoot(containing: $0) }
        )
    }

    func candidates(
        from cleanupSources: [SessionDataCleanupSource],
        activeProjectPaths: Set<String>
    ) -> [WorktreeCleanupCandidate] {
        let contexts = candidateContexts(from: cleanupSources)
        let activePaths = resolvedActiveProjectPaths(activeProjectPaths, candidatePaths: Set(contexts.keys))

        return contexts.values
            .map { candidate(from: $0, activeProjectPaths: activePaths) }
            .sorted { lhs, rhs in
                if lhs.state.sortOrder != rhs.state.sortOrder {
                    return lhs.state.sortOrder < rhs.state.sortOrder
                }
                return lhs.lastActiveAt > rhs.lastActiveAt
            }
    }

    private func candidateContexts(from cleanupSources: [SessionDataCleanupSource]) -> [String: CandidateContext] {
        var result: [String: CandidateContext] = [:]
        var resolvedPaths: [String: String] = [:]
        for source in cleanupSources {
            let rawPath = Self.standardizedPath(source.projectPath)
            guard Self.shouldScanCleanupSourcePath(rawPath) else { continue }
            let needsProtectedFolderAccess = Self.needsProtectedFolderAccessReview(rawPath)
            let path = needsProtectedFolderAccess ? Self.cleanupWorktreeRootPath(for: rawPath) ?? rawPath : (resolvedPaths[rawPath] ?? {
                let path = resolvedCandidatePath(for: rawPath)
                resolvedPaths[rawPath] = path
                return path
            }())
            guard let existing = result[path] else {
                result[path] = CandidateContext(source: source, path: path)
                continue
            }
            if source.lastActiveAt > existing.lastActiveAt {
                result[path] = CandidateContext(source: source, path: path)
            }
        }
        return result
    }

    private func resolvedCandidatePath(for rawPath: String) -> String {
        let probePath = nearestExistingPath(atOrAbove: rawPath) ?? rawPath
        return resolveWorktreeRoot(probePath).map(Self.standardizedPath) ?? rawPath
    }

    private func resolvedActiveProjectPaths(_ activeProjectPaths: Set<String>, candidatePaths: Set<String>) -> Set<String> {
        Set(activeProjectPaths.map { activePath in
            let standardizedPath = Self.standardizedPath(activePath)
            guard shouldResolveActiveProjectPath(standardizedPath, candidatePaths: candidatePaths) else {
                return standardizedPath
            }
            return resolvedCandidatePath(for: standardizedPath)
        })
    }

    private func nearestExistingPath(atOrAbove path: String) -> String? {
        var current = path
        while true {
            if fileExists(current) { return current }
            let parent = (current as NSString).deletingLastPathComponent
            guard parent != current else { return nil }
            current = parent
        }
    }

    private func candidate(from context: CandidateContext, activeProjectPaths: Set<String>) -> WorktreeCleanupCandidate {
        guard !isProtectedByActiveSession(context.path, activeProjectPaths: activeProjectPaths) else {
            return ignoredCandidate(
                context: context,
                state: .ignored(["Active cctop session is using this path"]),
                checks: [WorktreeCleanupCheck(label: "No active cctop sessions here", status: .ignored)]
            )
        }

        guard !Self.needsProtectedFolderAccessReview(context.path) else {
            return ignoredCandidate(
                context: context,
                state: .review([WorktreeCleanupCandidate.protectedFolderAccessReason]),
                checks: [WorktreeCleanupCheck(label: "Protected folder access", status: .review)]
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
        let branchName = inspection.branchName
            ?? (inspection.isRegisteredWorktree ? WorktreeCleanupCandidate.unknownBranchDisplayName : context.fallbackBranch)
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
        let state = Self.state(for: inspection, storageBytes: storageBytes)
        let reviewEvidence = Self.reviewEvidence(for: inspection)

        return WorktreeCleanupCandidate(
            id: context.path,
            sessionName: context.sessionName,
            worktreePath: context.path,
            worktreeName: context.worktreeName,
            mainWorktreePath: inspection.mainWorktreePath,
            branchName: context.displayBranch(branchName),
            lastActiveAt: context.lastActiveAt,
            storageBytes: storageBytes,
            state: state,
            checks: Self.checks(for: inspection, storageBytes: storageBytes, active: true),
            reviewEvidence: reviewEvidence
        )
    }

    static func state(for inspection: GitWorktreeInspection, storageBytes: Int64?) -> WorktreeCleanupCandidate.State {
        let reasons = reviewReasons(for: inspection, storageBytes: storageBytes)
        return reasons.isEmpty ? .clean : .review(reasons)
    }

    private static func reviewReasons(for inspection: GitWorktreeInspection, storageBytes: Int64?) -> [String] {
        var reasons = inspection.failureReasons
        if inspection.branchName?.isEmpty ?? true {
            reasons.appendUnique(WorktreeCleanupCandidate.branchUnknownReason)
        }
        if inspection.mainWorktreePath == nil {
            reasons.appendUnique(WorktreeCleanupCandidate.mainWorktreePathUnverifiedReason)
        }
        if inspection.isLocked {
            reasons.appendUnique(WorktreeCleanupCandidate.lockedReason)
        }
        if let statusEntries = inspection.statusEntries {
            if !Self.untrackedPaths(fromStatusEntries: statusEntries).isEmpty {
                reasons.appendUnique(WorktreeCleanupCandidate.untrackedFilesReason)
            }
            if !Self.ignoredPaths(fromStatusEntries: statusEntries).isEmpty {
                reasons.appendUnique(WorktreeCleanupCandidate.ignoredFilesReason)
            }
            if Self.hasTrackedChanges(fromStatusEntries: statusEntries) {
                reasons.appendUnique(WorktreeCleanupCandidate.trackedChangesReason)
            }
        } else {
            reasons.appendUnique(WorktreeCleanupCandidate.statusUnreadableReason)
        }
        if let count = inspection.uniqueCommitCount {
            if count > 0 {
                reasons.appendUnique("Branch has \(count) unique local commit\(count == 1 ? "" : "s")")
            }
        } else if !reasons.contains(where: Self.isCommitSafetyReason) {
            reasons.appendUnique(WorktreeCleanupCandidate.commitSafetyUnknownReason)
        }
        return reasons
    }

    private static func isCommitSafetyReason(_ reason: String) -> Bool {
        reason.localizedCaseInsensitiveContains("upstream")
            || reason.localizedCaseInsensitiveContains("commit")
            || reason == WorktreeCleanupCandidate.branchUnknownReason
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

    static func trackedPaths(fromStatusEntries entries: [String]) -> [String] {
        Array(Set(entries.compactMap { entry in
            guard entry.count >= 3,
                  entry[entry.index(entry.startIndex, offsetBy: 2)] == " ",
                  !entry.hasPrefix("?? "),
                  !entry.hasPrefix("!! "),
                  entry.prefix(2).contains(where: { $0 != " " }) else {
                return nil
            }
            let pathStart = entry.index(entry.startIndex, offsetBy: 3)
            return String(entry[pathStart...])
        })).sorted()
    }

    private static func paths(fromStatusEntries entries: [String], prefix: String) -> [String] {
        entries.compactMap { entry in
            guard entry.hasPrefix(prefix) else { return nil }
            return String(entry.dropFirst(prefix.count))
        }
    }

    static func reviewEvidence(for inspection: GitWorktreeInspection) -> WorktreeCleanupReviewEvidence {
        guard let statusEntries = inspection.statusEntries else {
            return WorktreeCleanupReviewEvidence(headRevision: inspection.headRevision)
        }
        let untrackedPreview = WorktreeCleanupUntrackedPreview(paths: untrackedPaths(fromStatusEntries: statusEntries))
        let ignoredPreview = WorktreeCleanupUntrackedPreview(paths: ignoredPaths(fromStatusEntries: statusEntries))
        let trackedPathSignature = trackedPaths(fromStatusEntries: statusEntries)
        return WorktreeCleanupReviewEvidence(
            untrackedPreview: untrackedPreview,
            ignoredPreview: ignoredPreview,
            trackedPathSignature: trackedPathSignature,
            headRevision: inspection.headRevision
        )
    }

    static func checks(
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
            WorktreeCleanupCheck(
                label: "No index-hidden tracked files",
                status: inspection.failureReasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason) ? .review : .ok
            ),
            WorktreeCleanupCheck(label: "No untracked files", status: statusUnavailable || untrackedDirty ? .review : .ok),
            WorktreeCleanupCheck(label: "No ignored files", status: statusUnavailable || ignoredDirty ? .review : .ok),
            WorktreeCleanupCheck(label: "Branch has no unique local commits", status: commitCount == 0 ? .ok : .review),
            WorktreeCleanupCheck(label: "Main checkout path is known", status: inspection.mainWorktreePath == nil ? .review : .ok),
            WorktreeCleanupCheck(label: "Worktree is not locked", status: inspection.isLocked ? .review : .ok),
            WorktreeCleanupCheck(label: "Storage size scan completed", status: storageBytes == nil ? .ignored : .ok),
        ]
    }

    static func standardizedPath(_ path: String) -> String { Config.standardizedPath(path) }
}

extension WorktreeCleanupScanner {
    func candidate(
        withID id: String,
        from cleanupSources: [SessionDataCleanupSource],
        activeProjectPaths: Set<String>
    ) -> WorktreeCleanupCandidate? {
        let id = Self.standardizedPath(id)
        guard let context = candidateContext(withID: id, from: cleanupSources) else { return nil }
        let activePaths = resolvedActiveProjectPaths(activeProjectPaths, candidatePaths: Set([id]))
        return candidate(from: context, activeProjectPaths: activePaths)
    }

    private func candidateContext(withID id: String, from cleanupSources: [SessionDataCleanupSource]) -> CandidateContext? {
        var result: CandidateContext?
        var resolvedPaths: [String: String] = [:]
        for source in cleanupSources {
            let rawPath = Self.standardizedPath(source.projectPath)
            guard Self.shouldScanCleanupSourcePath(rawPath) else { continue }
            let needsProtectedFolderAccess = Self.needsProtectedFolderAccessReview(rawPath)
            let path = needsProtectedFolderAccess ? Self.cleanupWorktreeRootPath(for: rawPath) ?? rawPath : (resolvedPaths[rawPath] ?? {
                let path = resolvedCandidatePath(for: rawPath)
                resolvedPaths[rawPath] = path
                return path
            }())
            guard path == id else { continue }
            guard let existing = result else {
                result = CandidateContext(source: source, path: path)
                continue
            }
            if source.lastActiveAt > existing.lastActiveAt {
                result = CandidateContext(source: source, path: path)
            }
        }
        return result
    }
}

extension WorktreeCleanupScanner {
    static func shouldScanCleanupSourcePath(_ path: String) -> Bool {
        guard Config.isLikelyPrivacyProtectedUserPath(path) else { return true }
        return isPlausibleCleanupWorktreePath(path)
    }
}

private extension WorktreeCleanupScanner {
    func shouldResolveActiveProjectPath(_ activePath: String, candidatePaths _: Set<String>) -> Bool {
        !Config.isLikelyPrivacyProtectedUserPath(activePath)
    }

    static func needsProtectedFolderAccessReview(_ path: String) -> Bool {
        Config.isLikelyPrivacyProtectedUserPath(path) && isPlausibleCleanupWorktreePath(path)
    }

    static func isPlausibleCleanupWorktreePath(_ path: String) -> Bool { cleanupWorktreeRootPath(for: path) != nil }
    static func cleanupWorktreeRootPath(for path: String) -> String? {
        let pathComponents = URL(fileURLWithPath: path).pathComponents
        guard pathComponents.count >= 3 else { return nil }
        for index in 0..<(pathComponents.count - 2) {
            let marker = pathComponents[index]
            guard marker == ".claude" || marker == ".codex" else { continue }
            if pathComponents[index + 1] == "worktrees", !pathComponents[index + 2].isEmpty {
                return NSString.path(withComponents: Array(pathComponents[0...(index + 2)]))
            }
        }
        return nil
    }
}

private struct CandidateContext {
    let sessionName: String
    let path: String
    let worktreeName: String
    let fallbackBranch: String
    let lastActiveAt: Date

    init(source: SessionDataCleanupSource, path: String? = nil) {
        self.path = path ?? WorktreeCleanupScanner.standardizedPath(source.projectPath)
        sessionName = source.sessionName
        worktreeName = URL(fileURLWithPath: self.path).lastPathComponent
        fallbackBranch = source.branch
        lastActiveAt = source.lastActiveAt
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
    func nonEmptyOr(_ fallback: [String]) -> [String] { isEmpty ? fallback : self }

    mutating func appendUnique(_ reason: String) {
        guard !contains(reason) else { return }
        append(reason)
    }
}
