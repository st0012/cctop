import SwiftUI

struct WorktreeCleanupCardView: View {
    let candidate: WorktreeCleanupCandidate
    var isSelected = false
    var relativeTimeNow = Date()
    var isRemoving = false
    var onSelect: () -> Void = {}
    var onRemove: () -> Void = {}
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            selectionButton
            actionColumn
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .cardSelectionStyle(isSelected: isSelected, isHovered: isHovered)
        .padding(.horizontal, AppChrome.rowSelectionHorizontalInset)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(candidate.sessionName), \(candidate.state.label), \(candidate.formattedStorage)")
    }

    private var selectionButton: some View {
        Button(action: onSelect) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.sessionName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    HStack(spacing: 5) {
                        Text(candidate.worktreeName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text("\u{00B7}")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.textMuted.opacity(0.6))
                        Text(candidate.branchName)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.textMuted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Text("Last active \(candidate.lastActiveAt.relativeDescription(asOf: relativeTimeNow))")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to review cleanup details")
    }

    private var actionColumn: some View {
        VStack(alignment: .trailing, spacing: 5) {
            cleanupBadge
            Text(candidate.formattedStorage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textMuted)
                .lineLimit(1)
            removeButton
        }
    }

    private var removeButton: some View {
        Button(action: onRemove) {
            HStack(spacing: 4) {
                Image(systemName: isRemoving ? "hourglass" : "trash")
                    .font(.system(size: 9, weight: .semibold))
                Text(isRemoving ? "Removing" : "Remove")
                    .font(.system(size: 9, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(Color.statusAttention)
            .frame(width: 74, height: 23)
            .background {
                RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                    .fill(Color.statusAttention.opacity(isRemoving ? 0.06 : 0.10))
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                    .stroke(Color.statusAttention.opacity(0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isRemoving)
        .help("Remove worktree")
    }

    private var cleanupBadge: some View {
        Text(candidate.state.label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule()
                    .fill(badgeColor.opacity(0.10))
            }
            .overlay {
                Capsule()
                    .stroke(badgeColor.opacity(0.22), lineWidth: 1)
            }
    }

    private var badgeColor: Color {
        switch candidate.state {
        case .clean: return Color.statusGreen
        case .review: return Color.statusAttention
        case .ignored: return Color.agentBadge
        }
    }
}

#Preview("Cleanup rows") {
    VStack(spacing: 0) {
        ForEach(WorktreeCleanupCandidate.mockCandidates) { candidate in
            WorktreeCleanupCardView(candidate: candidate)
        }
    }
    .frame(width: 320)
    .padding()
}
