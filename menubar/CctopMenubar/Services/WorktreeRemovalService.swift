import Foundation

struct WorktreeRemovalService {
    enum RemovalResult: Equatable {
        case removed(GitCommandResult)
        case refused(WorktreeCleanupCandidate)
        case forceRequired(WorktreeForceRemovalOffer)
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

    func remove(
        _ candidate: WorktreeCleanupCandidate,
        sourceSessions: [Session],
        activeProjectPaths: Set<String>
    ) -> RemovalResult {
        switch readyCandidate(candidate, sourceSessions: sourceSessions, activeProjectPaths: activeProjectPaths) {
        case .ready(let readiness):
            let result = runGit(removeArguments(for: readiness, force: false))
            guard result.exitCode == 0 else {
                guard readiness.candidate.canOfferForceRemoval(for: result) else {
                    return .failed(result)
                }
                return .forceRequired(WorktreeForceRemovalOffer(candidate: readiness.candidate, failure: result))
            }
            return .removed(result)
        case .refused(let latestCandidate):
            return .refused(latestCandidate)
        }
    }

    func forceRemove(
        _ offer: WorktreeForceRemovalOffer,
        sourceSessions: [Session],
        activeProjectPaths: Set<String>
    ) -> RemovalResult {
        switch readyCandidate(offer.candidate, sourceSessions: sourceSessions, activeProjectPaths: activeProjectPaths) {
        case .ready(let readiness):
            guard readiness.candidate.hasSameForceRemovalReasons(as: offer.candidate) else {
                return .refused(readiness.candidate)
            }
            guard readiness.candidate.canOfferForceRemoval(for: offer.failure) else {
                return .refused(readiness.candidate)
            }
            let result = runGit(removeArguments(for: readiness, force: true))
            return result.exitCode == 0 ? .removed(result) : .failed(result)
        case .refused(let latestCandidate):
            return .refused(latestCandidate)
        }
    }

    private enum ReadinessResult {
        case ready(RemovalReadiness)
        case refused(WorktreeCleanupCandidate)
    }

    private func readyCandidate(
        _ candidate: WorktreeCleanupCandidate,
        sourceSessions: [Session],
        activeProjectPaths: Set<String>
    ) -> ReadinessResult {
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

        return .ready(RemovalReadiness(candidate: finalCandidate, mainWorktreePath: mainWorktreePath))
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
        return localFileEvidencePairs.contains { pair in
            let addedReason = state.reasons.contains(pair.reason) && !confirmedReasons.contains(pair.reason)
            return pair.preflightPreview != pair.confirmedPreview || addedReason
        }
    }

    func canOfferForceRemoval(for result: GitCommandResult) -> Bool {
        isForceEligibleGitFailure(result)
            && state.reasons.allSatisfy(Self.isForceEligibleReason)
    }

    func hasSameForceRemovalReasons(as candidate: WorktreeCleanupCandidate) -> Bool {
        Set(state.reasons) == Set(candidate.state.reasons)
    }

    private func isForceEligibleGitFailure(_ result: GitCommandResult) -> Bool {
        guard result.exitCode != 0 else { return false }
        let output = "\(result.stderr)\n\(result.stdout)".lowercased()
        guard output.contains("--force") else { return false }
        return output.contains("modified")
            || output.contains("untracked")
            || output.contains("dirty")
            || output.contains("local changes")
    }

    private static func isForceEligibleReason(_ reason: String) -> Bool {
        reason == WorktreeCleanupCandidate.untrackedFilesReason
            || reason == WorktreeCleanupCandidate.ignoredFilesReason
            || reason == WorktreeCleanupCandidate.trackedChangesReason
    }
}
