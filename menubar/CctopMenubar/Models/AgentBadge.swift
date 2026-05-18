import Foundation

/// Six-way classification of a session's source + host app.
/// Drives source badge rendering in `SessionCardView` and `SourceBadgeView`.
enum AgentBadge: Equatable {
    case cc            // Claude Code CLI
    case claudeDesktop // Claude Desktop app
    case codex         // Codex CLI
    case codexDesktop  // Codex Desktop app
    case opencode
    case pi

    /// Short user-facing label rendered in the meta row.
    var label: String {
        switch self {
        case .cc: return "CC"
        case .claudeDesktop: return "Claude Desktop"
        case .codex: return "Codex"
        case .codexDesktop: return "Codex Desktop"
        case .opencode: return "OC"
        case .pi: return "Pi"
        }
    }

    /// Desktop variants render as a filled chip with a ✦ sparkle marker.
    /// CLI variants render as bare brand-colored text.
    var isDesktop: Bool {
        switch self {
        case .claudeDesktop, .codexDesktop: return true
        default: return false
        }
    }
}

extension Session {
    /// Classify the session's source + host app into one of six badge kinds.
    /// Legacy CC sessions (`source == nil`, no Desktop bundle ID) classify as `.cc`.
    ///
    /// `("cc", true)` is defensive: today Claude Desktop sessions always have
    /// `source == nil` (the Desktop hook integration predates the `harness_name`
    /// migration), but if that ever changes the bundle ID should still win.
    var agentBadge: AgentBadge {
        let isDesktop = isHostedByDesktopApp
        switch (source, isDesktop) {
        case ("opencode", _): return .opencode
        case ("pi", _): return .pi
        case ("codex", true): return .codexDesktop
        case ("codex", _): return .codex
        case ("cc", true), (nil, true): return .claudeDesktop
        default: return .cc
        }
    }
}
