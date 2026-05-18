import SwiftUI

/// Renders a session's source/host badge.
/// CLI variants → bare brand-colored caps text.
/// Desktop variants → filled chip with `✦` sparkle marker.
struct SourceBadgeView: View {
    let badge: AgentBadge

    var body: some View {
        if badge.isDesktop {
            HStack(spacing: 3) {
                Text("✦")
                    .font(.system(size: 9))
                    .foregroundStyle(color.opacity(0.9))
                Text(badge.label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.16))
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(badge.label)
        } else {
            Text(badge.label)
                .font(.system(size: 9.5, weight: .medium))
                .tracking(0.4)
                .foregroundStyle(color)
                .accessibilityLabel(badge.label)
        }
    }

    private var color: Color {
        switch badge {
        case .cc: return .amber
        case .claudeDesktop: return .claudeDesktopBadge
        case .codex: return .codexBadge
        case .codexDesktop: return .codexDesktopBadge
        case .opencode: return .opencodeBadge
        case .pi: return .piBadge
        }
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
