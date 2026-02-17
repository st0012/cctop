import SwiftUI

struct RecentProjectCardView: View {
    let project: RecentProject
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: project.editorIcon)
                .font(.system(size: 11))
                .foregroundStyle(Color.textMuted)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(project.projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)

                HStack(spacing: 5) {
                    Text(project.lastBranch)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)

                    Text("\u{00B7}")
                        .foregroundStyle(Color.textMuted)

                    Text("\(project.sessionCount) session\(project.sessionCount == 1 ? "" : "s")")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.textMuted)
                }
            }

            Spacer()

            TimelineView(.periodic(from: .now, by: 60)) { _ in
                Text(project.relativeTime)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isHovered ? Color.primary.opacity(0.15) : Color.cardBorder, lineWidth: 1)
        )
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(Color.textMuted.opacity(0.3))
                .frame(width: 2, height: 20)
                .padding(.leading, 4)
        }
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
