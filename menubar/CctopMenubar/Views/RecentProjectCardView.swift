import SwiftUI

struct RecentProjectCardView: View {
    let target: RecentResumeTarget
    var isSelected = false
    var relativeTimeNow = Date()
    @State private var isHovered = false

    init(target: RecentResumeTarget, isSelected: Bool = false, relativeTimeNow: Date = Date()) {
        self.target = target
        self.isSelected = isSelected
        self.relativeTimeNow = relativeTimeNow
    }

    init(project: RecentProject, isSelected: Bool = false, relativeTimeNow: Date = Date()) {
        self.init(target: .project(project), isSelected: isSelected, relativeTimeNow: relativeTimeNow)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: target.icon)
                .font(.system(size: 11))
                .foregroundStyle(Color.textMuted)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(target.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(target.metadataText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 2) {
                if let inlineActionLabel = target.inlineActionLabel {
                    Text(inlineActionLabel)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }

                Text(target.lastSessionAt.relativeDescription(asOf: relativeTimeNow))
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
            .layoutPriority(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .cardSelectionStyle(isSelected: isSelected, isHovered: isHovered)
        .padding(.horizontal, AppChrome.rowSelectionHorizontalInset)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}

#Preview("Cursor project") {
    RecentProjectCardView(project: .mock(project: "billing-api", branch: "feature/invoices", editor: "Cursor"))
        .frame(width: 300).padding()
}
#Preview("VS Code project") {
    RecentProjectCardView(project: .mock(project: "landing-page", branch: "redesign", editor: "Code"))
        .frame(width: 300).padding()
}
#Preview("Terminal project") {
    RecentProjectCardView(project: .mock(project: "infra", branch: "main", editor: "iTerm2"))
        .frame(width: 300).padding()
}
#Preview("Unknown editor") {
    RecentProjectCardView(project: .mock(project: "data-pipeline", branch: "fix/backfill", editor: nil))
        .frame(width: 300).padding()
}
#Preview("Single session") {
    RecentProjectCardView(project: .mock(project: "side-project", sessionCount: 1))
        .frame(width: 300).padding()
}
