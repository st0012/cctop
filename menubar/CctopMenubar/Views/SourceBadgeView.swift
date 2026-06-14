import SwiftUI

/// Renders a session's source/host badge as quiet metadata.
/// Harness labels stay neutral so project names and session state remain primary.
struct SourceBadgeView: View {
    let badge: AgentBadge

    var body: some View {
        Text(badge.label)
            .font(.system(size: 9.5, weight: .medium))
            .tracking(0.4)
            .foregroundStyle(Color.textMuted.opacity(0.82))
            .accessibilityLabel(badge.label)
    }
}

#Preview("CC") {
    SourceBadgeView(badge: .cc).padding()
}
#Preview("Claude Desktop") {
    SourceBadgeView(badge: .claudeDesktop).padding()
}
#Preview("Codex") {
    SourceBadgeView(badge: .codex).padding()
}
#Preview("Codex Desktop") {
    SourceBadgeView(badge: .codexDesktop).padding()
}
#Preview("Opencode") {
    SourceBadgeView(badge: .opencode).padding()
}
#Preview("Pi") {
    SourceBadgeView(badge: .pi).padding()
}
#Preview("All variants") {
    VStack(alignment: .leading, spacing: 12) {
        SourceBadgeView(badge: .cc)
        SourceBadgeView(badge: .claudeDesktop)
        SourceBadgeView(badge: .codex)
        SourceBadgeView(badge: .codexDesktop)
        SourceBadgeView(badge: .opencode)
        SourceBadgeView(badge: .pi)
    }
    .padding()
}
