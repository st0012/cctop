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

    /// The single user-facing source label API for badge rendering.
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

    /// Desktop variants keep their full app label and desktop-specific layout behavior.
    var isDesktop: Bool {
        switch self {
        case .claudeDesktop, .codexDesktop: return true
        default: return false
        }
    }
}

extension Session {
    /// Classify the session's source + host app into one of six badge kinds.
    ///
    /// A trusted Desktop bundle ID wins so pre-harness Desktop records still classify correctly.
    /// Harnesses keep their own badge when a FOREIGN desktop bundle ID leaked through the
    /// launcher environment (e.g. a cc session started under Codex Desktop, issue #155).
    var agentBadge: AgentBadge {
        switch trustedHostApp {
        case .claudeDesktop: return .claudeDesktop
        case .codexDesktop: return .codexDesktop
        default: break
        }
        // Non-Desktop: dispatch on the source harness.
        switch source {
        case "opencode": return .opencode
        case "pi": return .pi
        case "codex": return .codex
        default: return .cc
        }
    }
}
