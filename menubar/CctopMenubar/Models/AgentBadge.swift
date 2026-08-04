import Foundation

/// Source classification for session badge rendering.
/// Drives source badge rendering in `SessionCardView` and `SourceBadgeView`.
enum AgentBadge: Equatable {
    case cc            // Claude Code CLI
    case claudeDesktop // Claude Desktop app
    case codex
    case opencode
    case pi

    /// The single user-facing source label API for badge rendering.
    var label: String {
        switch self {
        case .cc: return "CC"
        case .claudeDesktop: return "Claude Desktop"
        case .codex: return "Codex"
        case .opencode: return "OC"
        case .pi: return "Pi"
        }
    }

    /// Desktop variants keep their full app label and desktop-specific layout behavior.
    var isDesktop: Bool {
        switch self {
        case .claudeDesktop: return true
        default: return false
        }
    }
}

extension Session {
    /// Classify the session source. Codex is one source across every surface.
    ///
    var agentBadge: AgentBadge {
        if isCodex { return .codex }
        if trustedHostApp == .claudeDesktop { return .claudeDesktop }
        switch source {
        case "opencode": return .opencode
        case "pi": return .pi
        default: return .cc
        }
    }
}
