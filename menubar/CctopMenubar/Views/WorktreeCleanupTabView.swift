import SwiftUI

struct WorktreeCleanupTabView: View {
    let candidates: [WorktreeCleanupCandidate]
    let selectedIndex: Int?
    @Binding var selectedCandidate: WorktreeCleanupCandidate?
    var isScanning = false
    var relativeTimeNow = Date()
    var onSelect: (WorktreeCleanupCandidate) -> Void = { _ in }
    var onRemove: (WorktreeCleanupCandidate) -> Void = { _ in }
    var removalNotice: WorktreeRemovalNotice?
    var removingCandidateID: String?

    var body: some View {
        if isScanning && !candidates.isEmpty {
            VStack(spacing: 0) {
                scanningBanner
                cleanupContent
            }
        } else {
            cleanupContent
        }
    }

    @ViewBuilder
    private var cleanupContent: some View {
        if let candidate = selectedCandidate {
            WorktreeCleanupDetailView(
                candidate: candidate,
                relativeTimeNow: relativeTimeNow,
                onBack: { selectedCandidate = nil },
                onRemove: { onRemove(candidate) },
                removalNotice: removalNotice,
                isRemoving: removingCandidateID == candidate.id
            )
        } else {
            VStack(spacing: 0) {
                listRemovalNotice
                listOrEmptyContent
            }
        }
    }

    @ViewBuilder
    private var listOrEmptyContent: some View {
        if candidates.isEmpty {
            VStack(spacing: 8) {
                if isScanning {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Scanning worktrees")
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.textMuted)
                }
                Text(isScanning ? "Scanning worktrees..." : "No cleanup candidates")
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

    @ViewBuilder
    private var listRemovalNotice: some View {
        if let removalNotice {
            VStack(alignment: .leading, spacing: 4) {
                Text(removalNotice.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(removalNotice.blocksRemoval ? Color.statusAttention : Color.textPrimary)
                Text(removalNotice.message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                    .fill(Color.statusAttention.opacity(removalNotice.blocksRemoval ? 0.08 : 0.04))
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                    .stroke(Color.statusAttention.opacity(removalNotice.blocksRemoval ? 0.22 : 0.12), lineWidth: 1)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
    }

    private var scanningBanner: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.mini)
                .frame(width: 12, height: 12)
                .accessibilityLabel("Scanning worktrees")
            Text("Scanning worktrees...")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color.panelControlBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.panelControlBorder)
                .frame(height: 1)
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
        WorktreeCleanupCardView(
            candidate: candidate,
            isSelected: isSelected,
            relativeTimeNow: relativeTimeNow,
            isRemoving: removingCandidateID == candidate.id,
            onSelect: {
                selectedCandidate = candidate
                onSelect(candidate)
            },
            onRemove: { onRemove(candidate) }
        )
    }
}

#Preview("Cleanup tab") {
    WorktreeCleanupTabView(
        candidates: WorktreeCleanupCandidate.mockCandidates,
        selectedIndex: nil,
        selectedCandidate: .constant(nil),
        onRemove: { _ in }
    )
    .frame(width: 320)
}
