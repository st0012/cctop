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

        if candidate.state.isClean && !preflightCandidate.state.isClean {
            return .refused(preflightCandidate)
        }
        if preflightCandidate.changesLocalFileReviewEvidence(comparedTo: candidate) {
            return .refused(preflightCandidate)
        }

        let inspection = scanner.inspectGit(preflightCandidate.worktreePath)
        guard let mainWorktreePath = inspection.mainWorktreePath,
              inspection.isRegisteredWorktree,
              inspection.isLinkedWorktree else {
            return .refused(preflightCandidate)
        }
        guard inspection.branchName != nil else {
            return .refused(preflightCandidate)
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
