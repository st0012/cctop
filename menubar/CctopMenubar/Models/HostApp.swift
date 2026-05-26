import Foundation

/// Classifies the application hosting a coding session (editor or terminal).
/// Used by focusTerminal, openInEditor, and editorIcon.
enum HostApp {
    case vscode
    case cursor
    case windsurf
    case zed
    case iterm2
    case warp
    case terminal
    case ghostty
    case kitty
    /// Claude Desktop runs sessions inside the app itself — no terminal, no editor.
    case claudeDesktop
    /// Codex Desktop runs sessions inside the app itself — no terminal, no editor.
    case codexDesktop
    case unknown

    /// Match a bundle identifier to a HostApp. Preferred over program name matching
    /// because `__CFBundleIdentifier` unambiguously identifies VS Code forks.
    static func from(bundleIdentifier: String?) -> HostApp? {
        guard let id = bundleIdentifier, !id.isEmpty else { return nil }
        return allByBundleID[id]
    }

    /// Match program name to a HostApp.
    static func from(editorName: String?) -> HostApp {
        guard let name = editorName, !name.isEmpty else { return .unknown }
        let lower = name.lowercased()

        // Order matters: "cursor" before "code" because Cursor's process name contains "code"
        if lower.contains("cursor") { return .cursor }
        if lower.contains("windsurf") { return .windsurf }
        if lower.contains("zed") { return .zed }
        if lower.contains("code") { return .vscode }
        if lower.contains("iterm") { return .iterm2 }
        if lower.contains("warp") { return .warp }
        if lower.contains("ghostty") { return .ghostty }
        if lower.contains("kitty") { return .kitty }
        if lower.contains("terminal") { return .terminal }
        return .unknown
    }

    var bundleID: String? {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .windsurf: return "com.codeium.windsurf"
        case .zed: return "dev.zed.Zed"
        case .iterm2: return "com.googlecode.iterm2"
        case .warp: return "dev.warp.Warp-Stable"
        case .terminal: return "com.apple.Terminal"
        case .ghostty: return "com.mitchellh.ghostty"
        case .kitty: return "net.kovidgoyal.kitty"
        case .claudeDesktop: return HostAppBundleID.claudeDesktop
        case .codexDesktop: return HostAppBundleID.codexDesktop
        case .unknown: return nil
        }
    }

    /// Lowercased name for matching against `NSRunningApplication.localizedName`.
    /// Nil for desktop AI apps — bundle ID is exact and avoids substring collisions.
    var activationName: String? {
        switch self {
        case .vscode: return "code"
        case .cursor: return "cursor"
        case .windsurf: return "windsurf"
        case .zed: return "zed"
        case .iterm2: return "iterm2"
        case .warp: return "warp"
        case .terminal: return "terminal"
        case .ghostty: return "ghostty"
        case .kitty: return "kitty"
        case .claudeDesktop, .codexDesktop, .unknown: return nil
        }
    }

    var sfSymbol: String {
        switch self {
        case .vscode, .cursor, .windsurf, .zed:
            return "chevron.left.forwardslash.chevron.right"
        case .iterm2, .warp, .terminal, .ghostty, .kitty, .unknown:
            return "terminal"
        case .claudeDesktop, .codexDesktop:
            return "sparkles"
        }
    }

    /// Whether this app supports `.code-workspace` files.
    var usesWorkspaceFile: Bool {
        switch self {
        case .vscode, .cursor, .windsurf, .zed: return true
        case .iterm2, .warp, .terminal, .ghostty, .kitty,
             .claudeDesktop, .codexDesktop, .unknown: return false
        }
    }

    /// Apps that host AI coding sessions inside themselves (no project folder to reopen).
    /// Used to: skip path-based focus, skip Recent Projects archival.
    var isDesktopApp: Bool {
        switch self {
        case .claudeDesktop, .codexDesktop: return true
        default: return false
        }
    }

    /// Reverse lookup: bundle ID → HostApp.
    static let allByBundleID: [String: HostApp] = {
        let all: [HostApp] = [
            .vscode, .cursor, .windsurf, .zed,
            .iterm2, .warp, .terminal, .ghostty, .kitty,
            .claudeDesktop, .codexDesktop
        ]
        return Dictionary(uniqueKeysWithValues: all.compactMap { app in
            app.bundleID.map { ($0, app) }
        })
    }()

    /// CLI command name for opening files (used by focusTerminal for active sessions).
    var cliCommand: String? {
        switch self {
        case .vscode: return "code"
        case .cursor: return "cursor"
        case .windsurf: return "windsurf"
        case .zed: return "zed"
        default: return nil
        }
    }
}

extension Session {
    /// True when the session is hosted by an AI desktop app (Claude Desktop, Codex Desktop)
    /// rather than a terminal/editor. These sessions have no project folder worth reopening,
    /// so they're excluded from Recent Projects.
    var isHostedByDesktopApp: Bool {
        guard let bundleId = terminal?.bundleId else { return false }
        return HostApp.from(bundleIdentifier: bundleId)?.isDesktopApp == true
    }
}

/// File-local classification of a session's host, used by lifecycle cleanup to decide which
/// files can be retained after their process disappears. Deliberately strict: `source` never
/// classifies (terminal Claude Code and Codex CLI share `source` strings with their desktop
/// counterparts), and env-only signals are not trusted — only a recognized `bundle_id` is.
enum SessionHostClass: Equatable {
    case desktop    // confident: a desktop AI app (Claude Desktop, Codex Desktop)
    case terminal   // confident: a known terminal or editor
    case ambiguous  // unknown — preserve existing terminal-style cleanup semantics
}

extension Session {
    /// Phase-1 host classification from file-local signals only.
    /// Precedence: a recognized bundle id (`__CFBundleIdentifier`, the same trusted signal
    /// `isHostedByDesktopApp` uses) classifies desktop vs terminal. Failing that, a terminal
    /// multiplexer (tmux/zellij) is hard terminal evidence — desktop is already returned
    /// above, so a leaked `TMUX` env can't misclassify a desktop session here. Everything
    /// else (no/unknown bundle id, only env-copyable `tty` or program name) → ambiguous.
    var hostClass: SessionHostClass {
        SessionIdentityPolicy.hostClass(for: self)
    }
}

extension HostApp {
    /// Deep-link URL that focuses a specific session inside this app, if supported.
    /// Returns nil when the app has no session-jump scheme, or `sessionId` isn't a
    /// canonical UUID — the URL handler rejects non-UUID values, so we mirror its
    /// validation client-side and fall back to plain app activation upstream.
    /// - Codex Desktop: `codex://threads/<uuid>` — navigates to a local conversation.
    /// - Claude Desktop: no deep link. `claude://resume?session=<uuid>` exists but
    ///   forks the conversation rather than focusing the existing one, which would
    ///   silently pollute the user's history. We just activate the app instead.
    func sessionDeepLink(sessionId: String) -> URL? {
        guard Self.isUUID(sessionId) else { return nil }
        switch self {
        case .codexDesktop:
            return URL(string: "codex://threads/\(sessionId)")
        default:
            return nil
        }
    }

    /// The host-app URL handler validates with this exact pattern (8-4-4-4-12 hex).
    static func isUUID(_ value: String) -> Bool {
        value.range(
            of: #"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }
}
