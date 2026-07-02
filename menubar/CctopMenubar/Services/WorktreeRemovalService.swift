import Foundation

struct WorktreeRemovalService {
    enum RemovalAction: Equatable {
        case normalRemove(WorktreeCleanupCandidate)
        case forceRemove(WorktreeCleanupCandidate)
        case blocked(WorktreeCleanupCandidate, String)
    }

    enum RemovalResult: Equatable {
        case removed(GitCommandResult)
        case refused(WorktreeCleanupCandidate)
        case failed(GitCommandResult)
    }

    private struct RemovalReadiness {
        let candidate: WorktreeCleanupCandidate
        let mainWorktreePath: String
    }

    var scanner: WorktreeCleanupScanner
    var runGit: ([String]) -> GitCommandResult

    static func live() -> WorktreeRemovalService {
        WorktreeRemovalService(
            scanner: .live(),
            runGit: GitCommand.run(arguments:)
        )
    }

    func selectedAction(
        for candidate: WorktreeCleanupCandidate,
        cleanupSources: [SessionCleanupSource],
        activeProjectPaths: Set<String>
    ) -> RemovalAction {
        switch readyCandidate(candidate, cleanupSources: cleanupSources, activeProjectPaths: activeProjectPaths) {
        case .ready(let readiness):
            if readiness.candidate.state.reasons.contains(WorktreeCleanupCandidate.lockedReason) {
                return .blocked(readiness.candidate, readiness.candidate.blockedRemovalReason)
            }
            if readiness.candidate.requiresForceWorktreeRemoval {
                return .forceRemove(readiness.candidate)
            }
            return .normalRemove(readiness.candidate)
        case .refused(let latestCandidate):
            return .blocked(latestCandidate, latestCandidate.blockedRemovalReason)
        }
    }

    func execute(_ action: RemovalAction) -> RemovalResult {
        switch action {
        case .normalRemove(let candidate):
            guard let readiness = removalReadiness(from: candidate) else {
                return .refused(candidate)
            }
            let result = runGit(removeArguments(for: readiness, force: false))
            return result.exitCode == 0 ? .removed(result) : .failed(result)
        case .forceRemove(let candidate):
            guard let readiness = removalReadiness(from: candidate) else {
                return .refused(candidate)
            }
            let result = runGit(removeArguments(for: readiness, force: true))
            return result.exitCode == 0 ? .removed(result) : .failed(result)
        case .blocked(let candidate, _):
            return .refused(candidate)
        }
    }

    func executeConfirmed(
        _ action: RemovalAction,
        cleanupSources: [SessionCleanupSource],
        activeProjectPaths: Set<String>
    ) -> RemovalResult {
        if case .blocked(let candidate, _) = action {
            return .refused(candidate)
        }

        let refreshedAction = selectedAction(
            for: action.candidate,
            cleanupSources: cleanupSources,
            activeProjectPaths: activeProjectPaths
        )

        switch (action, refreshedAction) {
        case (.normalRemove(let confirmedCandidate), .normalRemove(let refreshedCandidate)):
            guard refreshedCandidate.matchesConfirmedRemovalEvidence(comparedTo: confirmedCandidate) else {
                return .refused(refreshedCandidate)
            }
            return execute(.normalRemove(refreshedCandidate))
        case (.forceRemove(let confirmedCandidate), .forceRemove(let refreshedCandidate)):
            guard refreshedCandidate.matchesConfirmedRemovalEvidence(comparedTo: confirmedCandidate) else {
                return .refused(refreshedCandidate)
            }
            return execute(.forceRemove(refreshedCandidate))
        case (_, .blocked(let refreshedCandidate, _)):
            return .refused(refreshedCandidate)
        case (_, .normalRemove(let refreshedCandidate)), (_, .forceRemove(let refreshedCandidate)):
            return .refused(refreshedCandidate)
        }
    }

    func remove(
        _ candidate: WorktreeCleanupCandidate,
        cleanupSources: [SessionCleanupSource],
        activeProjectPaths: Set<String>
    ) -> RemovalResult {
        executeConfirmed(
            .normalRemove(candidate),
            cleanupSources: cleanupSources,
            activeProjectPaths: activeProjectPaths
        )
    }

    private enum ReadinessResult {
        case ready(RemovalReadiness)
        case refused(WorktreeCleanupCandidate)
    }

    private func readyCandidate(
        _ candidate: WorktreeCleanupCandidate,
        cleanupSources: [SessionCleanupSource],
        activeProjectPaths: Set<String>
    ) -> ReadinessResult {
        guard candidate.state.isActionable else {
            return .refused(candidate)
        }

        guard let preflightCandidate = scanner
            .candidates(from: cleanupSources, activeProjectPaths: activeProjectPaths)
            .first(where: { $0.id == candidate.id }) else {
            return .refused(candidate)
        }

        guard preflightCandidate.state.isActionable else {
            return .refused(preflightCandidate)
        }

        if let refusal = preflightCandidate.refusalCandidate(
            comparedTo: candidate,
            refuseCleanDowngrade: candidate.state.isClean
        ) {
            return .refused(refusal)
        }

        let inspection = scanner.inspectGit(preflightCandidate.worktreePath)
        guard let mainWorktreePath = inspection.mainWorktreePath,
              inspection.isRegisteredWorktree,
              inspection.isLinkedWorktree else {
            return .refused(preflightCandidate)
        }
        guard let branchName = inspection.branchName else {
            return .refused(preflightCandidate)
        }
        let finalCandidate = preflightCandidate.refreshed(with: inspection, branchName: branchName)
        if let refusal = finalCandidate.refusalCandidate(
            comparedTo: preflightCandidate,
            refuseCleanDowngrade: preflightCandidate.state.isClean
        ) {
            return .refused(refusal)
        }

        return .ready(RemovalReadiness(candidate: finalCandidate, mainWorktreePath: mainWorktreePath))
    }

    private func removalReadiness(from candidate: WorktreeCleanupCandidate) -> RemovalReadiness? {
        guard let mainWorktreePath = candidate.mainWorktreePath,
              candidate.state.isActionable else {
            return nil
        }
        return RemovalReadiness(candidate: candidate, mainWorktreePath: mainWorktreePath)
    }

    private func removeArguments(for readiness: RemovalReadiness, force: Bool) -> [String] {
        var arguments = [
            "-C",
            readiness.mainWorktreePath,
            "worktree",
            "remove",
        ]
        if force {
            arguments.append("--force")
        }
        arguments.append(readiness.candidate.worktreePath)
        return arguments
    }
}

private extension WorktreeCleanupCandidate {
    func refusalCandidate(
        comparedTo candidate: WorktreeCleanupCandidate,
        refuseCleanDowngrade: Bool
    ) -> WorktreeCleanupCandidate? {
        if refuseCleanDowngrade && !state.isClean {
            return self
        }
        if changesWorktreeIdentity(comparedTo: candidate) || changesLocalFileReviewEvidence(comparedTo: candidate) {
            return self
        }
        if state.reasons.contains(WorktreeCleanupCandidate.initializedSubmodulesReason)
            || state.reasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason)
            || state.reasons.contains(WorktreeCleanupCandidate.statusUnreadableReason) {
            return self
        }
        return nil
    }

    func refreshed(with inspection: GitWorktreeInspection, branchName: String) -> WorktreeCleanupCandidate {
        WorktreeCleanupCandidate(
            id: id,
            sessionName: sessionName,
            worktreePath: worktreePath,
            worktreeName: worktreeName,
            mainWorktreePath: inspection.mainWorktreePath,
            branchName: branchName,
            lastActiveAt: lastActiveAt,
            storageBytes: storageBytes,
            state: WorktreeCleanupScanner.state(for: inspection, storageBytes: storageBytes),
            checks: WorktreeCleanupScanner.checks(for: inspection, storageBytes: storageBytes, active: true),
            reviewEvidence: WorktreeCleanupScanner.reviewEvidence(for: inspection)
        )
    }

    func changesWorktreeIdentity(comparedTo candidate: WorktreeCleanupCandidate) -> Bool {
        worktreePath != candidate.worktreePath
            || mainWorktreePath != candidate.mainWorktreePath
            || branchName != candidate.branchName
    }

    func changesLocalFileReviewEvidence(comparedTo candidate: WorktreeCleanupCandidate) -> Bool {
        let confirmedReasons = Set(candidate.state.reasons)
        let localFileEvidencePairs = [
            (
                reason: WorktreeCleanupCandidate.untrackedFilesReason,
                preflightPreview: reviewEvidence.untrackedPreview,
                confirmedPreview: candidate.reviewEvidence.untrackedPreview
            ),
            (
                reason: WorktreeCleanupCandidate.ignoredFilesReason,
                preflightPreview: reviewEvidence.ignoredPreview,
                confirmedPreview: candidate.reviewEvidence.ignoredPreview
            ),
        ]
        let changedPreview = localFileEvidencePairs.contains { pair in
            let addedReason = state.reasons.contains(pair.reason) && !confirmedReasons.contains(pair.reason)
            return pair.preflightPreview != pair.confirmedPreview || addedReason
        }
        return changedPreview || reviewEvidence.trackedPathSignature != candidate.reviewEvidence.trackedPathSignature
    }

    func matchesConfirmedRemovalEvidence(comparedTo candidate: WorktreeCleanupCandidate) -> Bool {
        !changesWorktreeIdentity(comparedTo: candidate)
            && !changesLocalFileReviewEvidence(comparedTo: candidate)
            && Set(state.reasons) == Set(candidate.state.reasons)
    }

    var blockedRemovalReason: String {
        if state.reasons.contains(Self.statusUnreadableReason) {
            return "Git status could not be read, so cctop cannot verify what removal would delete."
        }
        if state.reasons.contains(Self.initializedSubmodulesReason) {
            return "This worktree contains initialized submodules, which cctop cannot safely remove yet."
        }
        if state.reasons.contains(Self.indexHiddenTrackedFilesReason) {
            return "This worktree has tracked files hidden by Git index flags, so cctop cannot verify local changes safely."
        }
        if state.reasons.contains(Self.lockedReason) {
            return "This worktree is locked. Unlock it before removing."
        }
        if state.reasons.contains(Self.branchUnknownReason) {
            return "The branch is unknown or detached, so cctop cannot verify branch safety."
        }
        if state.reasons.contains(Self.mainWorktreePathUnverifiedReason) {
            return "The main checkout path could not be verified, so cctop cannot run worktree removal safely."
        }
        return state.reasons.first ?? "Cleanup evidence changed. Review the updated worktree before removing."
    }
}
