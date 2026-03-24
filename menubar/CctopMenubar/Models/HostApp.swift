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
        case .unknown: return nil
        }
    }

    /// Lowercased name for matching against `NSRunningApplication.localizedName`.
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
        case .unknown: return nil
        }
    }

    var sfSymbol: String {
        switch self {
        case .vscode, .cursor, .windsurf, .zed:
            return "chevron.left.forwardslash.chevron.right"
        case .iterm2, .warp, .terminal, .ghostty, .unknown:
            return "terminal"
        }
    }

    /// Whether this app supports `.code-workspace` files.
    var usesWorkspaceFile: Bool {
        switch self {
        case .vscode, .cursor, .windsurf, .zed: return true
        case .iterm2, .warp, .terminal, .ghostty, .unknown: return false
        }
    }

    /// Reverse lookup: bundle ID → HostApp.
    static let allByBundleID: [String: HostApp] = {
        let all: [HostApp] = [.vscode, .cursor, .windsurf, .zed, .iterm2, .warp, .terminal, .ghostty]
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
