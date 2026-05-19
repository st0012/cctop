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
    ///
    /// The bundle ID is the most authoritative signal — it tells us exactly
    /// which Desktop app is hosting the session. We check it first so a
    /// Codex Desktop session whose `harness_name` field is missing (e.g. the
    /// shim didn't pass `--harness codex`, or the hook fired before the
    /// harness was established) still classifies as `.codexDesktop` instead
    /// of falling into the `.claudeDesktop` default. The `source` string is
    /// only consulted for non-Desktop sessions.
    var agentBadge: AgentBadge {
        // Desktop bundle ID wins — it's the most authoritative signal.
        switch HostApp.from(bundleIdentifier: terminal?.bundleId) {
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
