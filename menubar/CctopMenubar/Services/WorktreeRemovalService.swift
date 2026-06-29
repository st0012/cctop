import Foundation

struct WorktreeRemovalService {
    enum RemovalResult: Equatable {
        case removed(GitCommandResult)
        case refused(WorktreeCleanupCandidate)
        case failed(GitCommandResult)
    }

    var scanner: WorktreeCleanupScanner
    var runGit: ([String]) -> GitCommandResult

    static func live() -> WorktreeRemovalService {
        WorktreeRemovalService(
            scanner: .live(),
            runGit: GitCommand.run(arguments:)
        )
    }

    func remove(
        _ candidate: WorktreeCleanupCandidate,
        sourceSessions: [Session],
        activeProjectPaths: Set<String>
    ) -> RemovalResult {
        guard candidate.state.isActionable else {
            return .refused(candidate)
        }

        guard let preflightCandidate = scanner
            .candidates(from: sourceSessions, activeProjectPaths: activeProjectPaths)
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

        let result = runGit([
            "-C",
            mainWorktreePath,
            "worktree",
            "remove",
            preflightCandidate.worktreePath,
        ])
        guard result.exitCode == 0 else {
            return .failed(result)
        }
        return .removed(result)
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
            || state.reasons.contains(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason) {
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
        return localFileEvidencePairs.contains { pair in
            let addedReason = state.reasons.contains(pair.reason) && !confirmedReasons.contains(pair.reason)
            return pair.preflightPreview != pair.confirmedPreview || addedReason
        }
    }
}
