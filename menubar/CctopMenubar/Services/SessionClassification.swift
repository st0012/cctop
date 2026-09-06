import Foundation

struct SessionClassificationEvidence {
    let archivedCodexThreadIDs: Set<String>
    let missingCodexThreadIDs: Set<String>
    let codexInternalHelperThreadIDs: Set<String>
    let uncertainCodexDelegationThreadIDs: Set<String>
    let contradictoryCodexDelegationThreadIDs: Set<String>
    let codexExecHelperThreadIDs: Set<String>
    let archivedClaudeSessionIDs: Set<String>
}

struct FrozenCodexThreadState: CodexThreadStateProviding {
    let index: CodexThreadStateIndex?

    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex? {
        guard let index else { return nil }
        return index.filtered(to: threadIDs)
    }

    func existingThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        guard let index, index.unknownThreadIDs.isDisjoint(with: threadIDs) else {
            return nil
        }
        return index.existingThreadIDs.intersection(threadIDs)
    }

    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        guard let index else { return [] }
        guard index.unknownThreadIDs.isDisjoint(with: threadIDs) else {
            return nil
        }
        return index.archivedThreadIDs.intersection(threadIDs)
    }

    func internalHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        index.map { $0.internalHelperThreadIDs.intersection(threadIDs) } ?? []
    }

    func execHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        index.map { $0.execHelperThreadIDs.intersection(threadIDs) } ?? []
    }

}

enum SessionHiddenReason: Equatable {
    case persistedHidden
    case autoHidden
    case archivedCodexThread
    case missingCodexThread
    case codexInternalHelper
    case codexExecHelper
    case archivedClaudeDesktop
    case orphanedEndedClaudeDesktop
    case claudeDesktopStartupPlaceholder

    /// Archived Codex records are explicit cleanup input, never path protection. Helpers and
    /// durable local hides still represent live ownership and remain protective.
    var protectsCleanupPath: Bool {
        switch self {
        case .persistedHidden, .autoHidden, .codexInternalHelper, .codexExecHelper:
            return true
        case .archivedCodexThread, .missingCodexThread, .archivedClaudeDesktop,
             .orphanedEndedClaudeDesktop, .claudeDesktopStartupPlaceholder:
            return false
        }
    }
}

enum SessionDisposition: Equatable {
    case display
    case hidden(SessionHiddenReason)
}

struct ClassifiedSessionRecord {
    let url: URL
    let candidate: SessionRecord
    let disposition: SessionDisposition
}

struct SessionClassificationSnapshot {
    let records: [ClassifiedSessionRecord]
    let evidence: SessionClassificationEvidence

    var displayCandidates: [SessionRecord] {
        records.compactMap { record in
            guard record.disposition == .display else { return nil }
            return record.candidate
        }
    }

    var autoHiddenSessions: [(URL, SessionData)] {
        records.compactMap { record in
            guard case .hidden(.autoHidden) = record.disposition else { return nil }
            return (record.url, record.candidate.data)
        }
    }

    var codexInternalHelperCandidates: [SessionRecord] {
        records.compactMap { record in
            guard case .hidden(.codexInternalHelper) = record.disposition else { return nil }
            return record.candidate
        }
    }

    var protectedProjectPathsForCleanup: Set<String> {
        let displayProtected = SessionIdentityPolicy
            .dedupedCandidatesByStableKey(displayCandidates)
            .filter { $0.lifecycleRank != SessionLifecycle.finished.rawValue }
            .map(\.data.projectPath)
        let hiddenProtected = records.compactMap { record -> String? in
            guard case .hidden(let reason) = record.disposition,
                  reason.protectsCleanupPath,
                  record.candidate.lifecycleRank != SessionLifecycle.finished.rawValue else {
                return nil
            }
            return record.candidate.data.projectPath
        }
        return Set(displayProtected).union(hiddenProtected)
    }

    var finishedNonDesktopCandidates: [SessionRecord] {
        displayCandidates.filter {
            $0.lifecycleRank == SessionLifecycle.finished.rawValue
                && !$0.data.isCodex
                && $0.data.hostClass != .desktop
        }
    }

    func manualHiddenProjectPaths(_ hiddenSessionIDs: Set<String>) -> Set<String> {
        Set(records.compactMap { record in
            guard let cctopSessionID = record.candidate.data.cctopSessionId,
                  hiddenSessionIDs.contains(cctopSessionID) else { return nil }
            return record.candidate.data.projectPath
        })
    }

    /// Archived conversations can seed worktree cleanup while preserving the session file.
    /// Finished non-retained sessions continue to contribute through history.
    var cleanupSources: [SessionDataCleanupSource] {
        records.compactMap { record in
            guard case .hidden(let reason) = record.disposition,
                  reason.emitsCleanupSource,
                  record.candidate.data.hasCleanupSourcePath else {
                return nil
            }
            return SessionDataCleanupSource(data: record.candidate.data)
        }
    }

    var archivedCodexThreadIDs: Set<String> { evidence.archivedCodexThreadIDs }
    var missingCodexThreadIDs: Set<String> { evidence.missingCodexThreadIDs }
    var codexInternalHelperThreadIDs: Set<String> { evidence.codexInternalHelperThreadIDs }
    var uncertainCodexDelegationThreadIDs: Set<String> { evidence.uncertainCodexDelegationThreadIDs }
    var contradictoryCodexDelegationThreadIDs: Set<String> { evidence.contradictoryCodexDelegationThreadIDs }
    var codexExecHelperThreadIDs: Set<String> { evidence.codexExecHelperThreadIDs }
    var archivedClaudeSessionIDs: Set<String> { evidence.archivedClaudeSessionIDs }
}

private extension SessionHiddenReason {
    var emitsCleanupSource: Bool {
        switch self {
        case .archivedCodexThread, .archivedClaudeDesktop:
            return true
        case .persistedHidden, .autoHidden, .missingCodexThread, .codexInternalHelper,
             .codexExecHelper, .orphanedEndedClaudeDesktop, .claudeDesktopStartupPlaceholder:
            return false
        }
    }
}

extension SessionData {
    /// Project paths that can seed worktree cleanup: non-empty and not the filesystem root.
    var hasCleanupSourcePath: Bool {
        let path = WorktreeCleanupScanner.standardizedPath(projectPath)
        return !path.isEmpty && path != "/"
    }
}
