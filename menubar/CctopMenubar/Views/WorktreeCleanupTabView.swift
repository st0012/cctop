import SwiftUI

struct WorktreeCleanupTabView: View {
    let candidates: [WorktreeCleanupCandidate]
    let selectedIndex: Int?
    @Binding var selectedCandidate: WorktreeCleanupCandidate?
    var relativeTimeNow = Date()
    var onSelect: (WorktreeCleanupCandidate) -> Void = { _ in }
    var onRemove: (WorktreeCleanupCandidate, WorktreeForceRemovalOffer?) -> Void = { _, _ in }
    var removalNotice: WorktreeRemovalNotice?
    var removingCandidateID: String?

    var body: some View {
        if let candidate = selectedCandidate {
            WorktreeCleanupDetailView(
                candidate: candidate,
                relativeTimeNow: relativeTimeNow,
                onBack: { selectedCandidate = nil },
                onRemove: { onRemove(candidate, removalNotice?.forceOffer) },
                removalNotice: removalNotice,
                isRemoving: removingCandidateID == candidate.id
            )
        } else if candidates.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.textMuted)
                Text("No cleanup candidates")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            cleanupList
        }
    }

    private var cleanupList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 && selectedIndex != index && selectedIndex != index - 1 {
                            Rectangle()
                                .fill(Color.panelControlBorder)
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                        cleanupCard(candidate, isSelected: selectedIndex == index)
                            .id(candidate.id)
                    }
                }
                .padding(.vertical, AppChrome.listVerticalPadding)
            }
            .frame(maxHeight: AppChrome.overlayMinimumContentHeight)
            .onChange(of: selectedIndex) { newIndex in
                guard let idx = newIndex, idx < candidates.count else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(candidates[idx].id, anchor: .center)
                }
            }
        }
    }

    private func cleanupCard(_ candidate: WorktreeCleanupCandidate, isSelected: Bool = false) -> some View {
        WorktreeCleanupCardView(candidate: candidate, isSelected: isSelected, relativeTimeNow: relativeTimeNow)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedCandidate = candidate
                onSelect(candidate)
            }
            .help("Click to review cleanup details")
    }
}

#Preview("Cleanup tab") {
    WorktreeCleanupTabView(
        candidates: WorktreeCleanupCandidate.mockCandidates,
        selectedIndex: nil,
        selectedCandidate: .constant(nil),
        onRemove: { _, _ in }
    )
    .frame(width: 320)
}
