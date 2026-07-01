import SwiftUI

extension PopupView {
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
            relativeTimeNow: relativeTimeNow,
            onSelect: openCleanupDetail,
            onRemove: requestCleanupRemoval,
            removalNotice: cleanupRemovalNotice,
            removingCandidateID: removingCleanupCandidateID
        )
    }

    func requestCleanupRemoval(_ candidate: WorktreeCleanupCandidate, forceOffer: WorktreeForceRemovalOffer?) {
        if let forceOffer {
            pendingRemovalConfirmation = .force(forceOffer)
        } else {
            pendingRemovalConfirmation = .initial(for: candidate)
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

    func performCleanupRemoval(_ candidate: WorktreeCleanupCandidate) {
        guard let onRemoveCleanupCandidate else { return }
        cleanupRemovalNotice = nil
        removingCleanupCandidateID = candidate.id
        notifyLayoutChanged()

        Task {
            let result = await onRemoveCleanupCandidate(candidate)
            await MainActor.run {
                removingCleanupCandidateID = nil
                handleCleanupRemovalResult(result, originalCandidate: candidate)
                notifyLayoutChanged()
            }
        }
    }

    func performCleanupForceRemoval(_ offer: WorktreeForceRemovalOffer) {
        guard let onForceRemoveCleanupCandidate else { return }
        cleanupRemovalNotice = nil
        removingCleanupCandidateID = offer.candidate.id
        notifyLayoutChanged()

        Task {
            let result = await onForceRemoveCleanupCandidate(offer)
            await MainActor.run {
                removingCleanupCandidateID = nil
                handleCleanupRemovalResult(result, originalCandidate: offer.candidate)
                notifyLayoutChanged()
            }
        }
    }

    func handleCleanupRemovalResult(
        _ result: WorktreeRemovalService.RemovalResult,
        originalCandidate: WorktreeCleanupCandidate
    ) {
        switch result {
        case .removed:
            selectedCleanupCandidate = nil
            cleanupRemovalNotice = nil
        case .forceRequired(let offer):
            selectedCleanupCandidate = offer.candidate
            cleanupRemovalNotice = WorktreeRemovalNotice(
                title: "Remove Failed",
                message: cleanupForceOfferMessage(),
                forceOffer: offer
            )
        case .refused(let latestCandidate):
            selectedCleanupCandidate = latestCandidate
            cleanupRemovalNotice = WorktreeRemovalNotice(
                title: "Review Required",
                message: latestCandidate.state.reasons.first ?? "The worktree is no longer safe to remove automatically."
            )
        case .failed(let gitResult):
            selectedCleanupCandidate = originalCandidate
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

    func cleanupForceOfferMessage() -> String {
        "Plain removal failed; Git suggested --force for local files."
    }

    func removalAlert(for confirmation: WorktreeRemovalConfirmation) -> Alert {
        switch confirmation {
        case .reviewWarning(let candidate):
            return Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .default(Text(confirmation.primaryButtonTitle)) {
                    DispatchQueue.main.async {
                        pendingRemovalConfirmation = .final(candidate)
                    }
                },
                secondaryButton: .cancel()
            )
        case .final(let candidate):
            return Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.primaryButtonTitle)) {
                    performCleanupRemoval(candidate)
                },
                secondaryButton: .cancel()
            )
        case .force(let offer):
            return Alert(
                title: Text(confirmation.title),
                message: Text(confirmation.message),
                primaryButton: .destructive(Text(confirmation.primaryButtonTitle)) {
                    performCleanupForceRemoval(offer)
                },
                secondaryButton: .cancel()
            )
        }
    }
}
