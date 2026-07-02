import SwiftUI

struct WorktreeCleanupDetailView: View {
    let candidate: WorktreeCleanupCandidate
    var relativeTimeNow = Date()
    let onBack: () -> Void
    var onRemove: () -> Void = {}
    var removalNotice: WorktreeRemovalNotice?
    var isRemoving = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: detailContentSpacing) {
                    header
                    summaryBlock
                    pathBlock
                    noticeBlock
                    if !showsNoticeLocalFileEvidence {
                        reviewReasonsBlock
                    }
                    if candidate.state.isClean {
                        checksBlock
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, detailTopPadding)
                .padding(.bottom, 8)
            }
            .frame(maxHeight: AppChrome.overlayMinimumContentHeight - 48)

            actionSection
        }
        .frame(maxHeight: AppChrome.overlayMinimumContentHeight)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 26, height: 26)
                    .background {
                        RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                            .fill(Color.panelControlBackground)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                            .stroke(Color.panelControlBorder, lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .help("Back to cleanup list")

            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.sessionName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(candidate.worktreeName) \u{00B7} \(candidate.branchName)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 6)
            stateBadge
        }
    }

    private var summaryBlock: some View {
        HStack(spacing: 8) {
            summaryMetric(label: "Last active", value: candidate.lastActiveAt.relativeDescription(asOf: relativeTimeNow))
            divider
            summaryMetric(label: "Storage", value: candidate.formattedStorage)
            divider
            summaryMetric(label: "Checks", value: checksSummary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, summaryVerticalPadding)
        .background {
            RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                .fill(Color.groupedContentBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                .stroke(Color.groupedRowBorder, lineWidth: 1)
        }
    }

    private var pathBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Path")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.textMuted)
                .textCase(.uppercase)
            Text(displayPath)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var reviewReasonsBlock: some View {
        if !candidate.state.reasons.isEmpty {
            VStack(alignment: .leading, spacing: reviewReasonsSpacing) {
                sectionLabel("Needs review")
                ForEach(Array(visibleReasons.enumerated()), id: \.offset) { _, reason in
                    reviewReasonRow(reason)
                }
                if remainingReasonCount > 0 {
                    let noun = remainingReasonCount == 1 ? "item" : "items"
                    evidenceRow("\(remainingReasonCount) more review \(noun)", systemImage: "ellipsis.circle", color: stateColor)
                }
            }
        }
    }

    private func reviewReasonRow(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: reviewReasonRowSpacing) {
            evidenceRow(reason, systemImage: "exclamationmark.triangle", color: stateColor)
            if reason == WorktreeCleanupCandidate.untrackedFilesReason,
               let preview = candidate.reviewEvidence.untrackedPreview {
                CleanupUntrackedPreviewBlock(preview: preview, isCompact: usesCompactUntrackedPreviewLayout)
            } else if reason == WorktreeCleanupCandidate.ignoredFilesReason,
                      let preview = candidate.reviewEvidence.ignoredPreview {
                CleanupUntrackedPreviewBlock(preview: preview, isCompact: usesCompactUntrackedPreviewLayout)
            }
        }
    }

    private var checksBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(nonOKChecks.isEmpty ? "Evidence" : "Checks")
            if nonOKChecks.isEmpty {
                evidenceRow("\(passedCheckCount) checks passed", systemImage: "checkmark.circle", color: Color.statusGreen)
            } else {
                evidenceRow("\(nonOKChecks.count) checks need review", systemImage: "exclamationmark.circle", color: stateColor)
            }
        }
    }

    @ViewBuilder
    private var actionSection: some View {
        if candidate.state.isActionable && removalNotice?.blocksRemoval != true {
            actionRow
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
    }

    private var actionRow: some View {
        VStack(spacing: 6) {
            CleanupDetailActionButton(
                title: actionTitle,
                systemImage: isRemoving ? "hourglass" : "trash",
                isPrimary: true,
                isDisabled: isRemoving,
                action: onRemove
            )
            .help(removeHelp)
            .accessibilityLabel("Remove worktree")
            .accessibilityHint(removeHelp)
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private var noticeBlock: some View {
        if let removalNotice {
            VStack(alignment: .leading, spacing: 4) {
                Text(removalNotice.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.statusAttention)
                Text(removalNotice.message)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                if showsNoticeLocalFileEvidence {
                    CleanupForceRemovalEvidenceBlock(evidence: candidate.reviewEvidence)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                    .fill(Color.statusAttention.opacity(0.08))
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                    .stroke(Color.statusAttention.opacity(0.22), lineWidth: 1)
            }
        }
    }

    private var stateBadge: some View {
        Text(candidate.state.label)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(stateColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background {
                Capsule().fill(stateColor.opacity(0.10))
            }
            .overlay {
                Capsule().stroke(stateColor.opacity(0.22), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
    }

    private func summaryMetric(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Color.textMuted)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.groupedRowBorder)
            .frame(width: 1, height: 22)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.textMuted)
    }

    private func evidenceRow(_ text: String, systemImage: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 12)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var stateColor: Color {
        switch candidate.state {
        case .clean: return Color.statusGreen
        case .review: return Color.statusAttention
        case .ignored: return Color.agentBadge
        }
    }

    private func color(for status: WorktreeCleanupCheck.Status) -> Color {
        switch status {
        case .ok: return Color.statusGreen
        case .review: return Color.statusAttention
        case .ignored: return Color.textMuted
        }
    }

    private var nonOKChecks: [WorktreeCleanupCheck] {
        candidate.checks.filter { $0.status == .review }
    }

    private var visibleReasons: [String] {
        candidate.visibleReviewReasons()
    }

    private var remainingReasonCount: Int {
        candidate.remainingReviewReasonCount()
    }

    private var passedCheckCount: Int {
        candidate.checks.filter { $0.status == .ok }.count
    }

    private var checksSummary: String {
        if nonOKChecks.isEmpty { return "\(passedCheckCount) passed" }
        return "\(nonOKChecks.count) review"
    }

    private var usesCompactUntrackedPreviewLayout: Bool {
        candidate.state.reasons.count > 1 && candidate.reviewEvidence.hasLocalFilePreview
    }

    private var detailContentSpacing: CGFloat {
        usesCompactUntrackedPreviewLayout ? 7 : 10
    }

    private var detailTopPadding: CGFloat {
        usesCompactUntrackedPreviewLayout ? 8 : 10
    }

    private var summaryVerticalPadding: CGFloat {
        usesCompactUntrackedPreviewLayout ? 6 : 8
    }

    private var reviewReasonsSpacing: CGFloat {
        usesCompactUntrackedPreviewLayout ? 4 : 6
    }

    private var reviewReasonRowSpacing: CGFloat {
        usesCompactUntrackedPreviewLayout ? 2 : 4
    }

    private var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard candidate.worktreePath.hasPrefix(home + "/") else { return candidate.worktreePath }
        return "~" + candidate.worktreePath.dropFirst(home.count)
    }

}

private extension WorktreeCleanupDetailView {
    var removeHelp: String {
        if candidate.state.isClean {
            return "Run git worktree remove"
        }
        return "Review the cleanup evidence before removing this worktree"
    }

    var actionTitle: String {
        isRemoving ? "Removing..." : "Remove"
    }

    var showsNoticeLocalFileEvidence: Bool {
        removalNotice != nil && candidate.reviewEvidence.hasLocalFilePreview
    }
}

private struct CleanupForceRemovalEvidenceBlock: View {
    let evidence: WorktreeCleanupReviewEvidence

    var body: some View {
        if evidence.hasLocalFilePreview {
            VStack(alignment: .leading, spacing: 4) {
                if let preview = evidence.untrackedPreview {
                    previewBlock(label: "Untracked files", preview: preview)
                }
                if let preview = evidence.ignoredPreview {
                    previewBlock(label: "Ignored files", preview: preview)
                }
            }
            .padding(.top, 2)
        }
    }

    private func previewBlock(label: String, preview: WorktreeCleanupUntrackedPreview) -> some View {
        Text("\(label): \(preview.decisionEvidenceText)")
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct CleanupUntrackedPreviewBlock: View {
    let preview: WorktreeCleanupUntrackedPreview
    var isCompact = false

    var body: some View {
        VStack(alignment: .leading, spacing: isCompact ? 1 : 2) {
            ForEach(preview.items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("-")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.textMuted)
                        .frame(width: 7, alignment: .leading)
                    Text(item)
                        .font(.system(size: itemFontSize, design: .monospaced))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if preview.remainingCount > 0 {
                Text("and \(preview.remainingCount) more")
                    .font(.system(size: itemFontSize))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
        }
        .padding(.leading, 19)
    }

    private var itemFontSize: CGFloat {
        isCompact ? 9 : 9.5
    }
}

private struct CleanupDetailActionButton: View {
    let title: String
    let systemImage: String
    var isPrimary = false
    var isDisabled = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(foregroundColor)
            .frame(maxWidth: .infinity, minHeight: 28)
            .background {
                RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                    .fill(backgroundColor)
            }
            .overlay {
                RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }

    private var foregroundColor: Color {
        if isDisabled { return Color.textMuted }
        return isPrimary ? Color.statusAttention : Color.textSecondary
    }

    private var backgroundColor: Color {
        if isDisabled { return Color.panelControlBackground.opacity(0.7) }
        if isPrimary { return Color.statusAttention.opacity(isHovered ? 0.16 : 0.10) }
        return isHovered ? Color.panelSelectionBackground : Color.panelControlBackground
    }

    private var borderColor: Color {
        if isPrimary { return Color.statusAttention.opacity(0.28) }
        return Color.panelControlBorder
    }
}

struct WorktreeRemovalNotice: Equatable {
    let title: String
    let message: String
    var blocksRemoval = false
}

#Preview("Clean detail") {
    WorktreeCleanupDetailView(
        candidate: .mock(),
        onBack: {},
        onRemove: {}
    )
    .frame(width: 320)
    .padding()
}
