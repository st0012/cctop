import SwiftUI

extension PopupView {
    static func noticeAfterCleanupCandidatesChanged(_ notice: WorktreeRemovalNotice?) -> WorktreeRemovalNotice? {
        notice?.blocksRemoval == true ? notice : nil
    }

    static func syncedCleanupCandidate(
        _ selectedCandidate: WorktreeCleanupCandidate?,
        in candidates: [WorktreeCleanupCandidate]
    ) -> WorktreeCleanupCandidate? {
        guard let selectedCandidate else { return nil }
        return candidates.first { $0.id == selectedCandidate.id }
    }

    var cleanupContent: some View {
        WorktreeCleanupTabView(
            candidates: actionableCleanupCandidates,
            selectedIndex: selectedIndex,
            selectedCandidate: $selectedCleanupCandidate,
            isScanning: cleanupIsScanning,
            relativeTimeNow: relativeTimeNow,
            onSelect: openCleanupDetail,
            onRemove: requestCleanupRemoval,
            removalNotice: cleanupRemovalNotice,
            removingCandidateID: removingCleanupCandidateID
        )
    }

    func requestCleanupRemoval(_ candidate: WorktreeCleanupCandidate) {
        guard let onSelectCleanupRemovalAction else { return }
        let selectsCandidateOnResult = selectedCleanupCandidate?.id == candidate.id
        cleanupRemovalNotice = nil
        removingCleanupCandidateID = candidate.id
        notifyLayoutChanged()

        Task {
            let action = await onSelectCleanupRemovalAction(candidate)
            await MainActor.run {
                removingCleanupCandidateID = nil
                if selectsCandidateOnResult {
                    selectedCleanupCandidate = action.candidate
                }

                switch action {
                case .blocked(_, let reason):
                    cleanupRemovalNotice = WorktreeRemovalNotice(
                        title: "Removal Blocked",
                        message: reason,
                        blocksRemoval: true
                    )
                default:
                    if let confirmation = WorktreeRemovalConfirmation.review(for: action) {
                        cleanupRemovalSelectsCandidateOnResult = selectsCandidateOnResult
                        pendingRemovalConfirmation = confirmation
                    } else {
                        performCleanupRemovalAction(action, selectsCandidateOnResult: selectsCandidateOnResult)
                    }
                }

                notifyLayoutChanged()
            }
        }
    }

    func handleSelectedTabChanged(_ newTab: PopupTab) {
        selectedIndex = nil
        if newTab == .cleanup {
            onCleanupTabVisible()
        } else {
            onCleanupTabHidden()
            selectedCleanupCandidate = nil
            cleanupRemovalNotice = nil
        }
    }

    func handleCleanupScanningChanged() {
        notifyLayoutChanged()
    }

    func performCleanupRemovalAction(
        _ action: WorktreeRemovalService.RemovalAction,
        selectsCandidateOnResult: Bool = true
    ) {
        guard let onExecuteCleanupRemovalAction else { return }
        let candidate = action.candidate
        cleanupRemovalNotice = nil
        removingCleanupCandidateID = candidate.id
        notifyLayoutChanged()

        Task {
            let result = await onExecuteCleanupRemovalAction(action)
            await MainActor.run {
                removingCleanupCandidateID = nil
                handleCleanupRemovalResult(
                    result,
                    originalCandidate: candidate,
                    selectsCandidateOnResult: selectsCandidateOnResult
                )
                notifyLayoutChanged()
            }
        }
    }

    func handleCleanupRemovalResult(
        _ result: WorktreeRemovalService.RemovalResult,
        originalCandidate: WorktreeCleanupCandidate,
        selectsCandidateOnResult: Bool = true
    ) {
        switch result {
        case .removed:
            selectedCleanupCandidate = nil
            cleanupRemovalNotice = nil
        case .refused(let latestCandidate):
            if selectsCandidateOnResult {
                selectedCleanupCandidate = latestCandidate
            }
            cleanupRemovalNotice = WorktreeRemovalNotice(
                title: "Removal Blocked",
                message: latestCandidate.state.reasons.first ?? "Cleanup cannot confidently remove this worktree right now.",
                blocksRemoval: true
            )
        case .failed(let gitResult):
            if selectsCandidateOnResult {
                selectedCleanupCandidate = originalCandidate
            }
            cleanupRemovalNotice = WorktreeRemovalNotice(
                title: "Remove Failed",
                message: cleanupFailureMessage(from: gitResult)
            )
        }
    }

    func cleanupFailureMessage(from result: GitCommandResult) -> String {
        Config.nonEmpty(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? Config.nonEmpty(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            ?? "git exited with status \(result.exitCode)"
    }

    func removalAlert(for confirmation: WorktreeRemovalConfirmation) -> Alert {
        switch confirmation {
        case .review(let action):
            return Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.primaryButtonTitle)) {
                    performCleanupRemovalAction(
                        action,
                        selectsCandidateOnResult: cleanupRemovalSelectsCandidateOnResult
                    )
                },
                secondaryButton: .cancel()
            )
        }
    }
}
