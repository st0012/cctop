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
    case jetbrains
    case unknown

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
        if lower.contains("jetbrains") { return .jetbrains }
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
        case .jetbrains: return nil  // varies per IDE; handled via terminal.program
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
        case .jetbrains: return nil  // activated by bundle ID in focusTerminal
        case .unknown: return nil
        }
    }

    var sfSymbol: String {
        switch self {
        case .vscode, .cursor, .windsurf, .zed:
            return "chevron.left.forwardslash.chevron.right"
        case .iterm2, .warp, .terminal, .jetbrains, .unknown:
            return "terminal"
        }
    }

    /// Whether this app supports `.code-workspace` files.
    var usesWorkspaceFile: Bool {
        switch self {
        case .vscode, .cursor, .windsurf, .zed: return true
        case .iterm2, .warp, .terminal, .jetbrains, .unknown: return false
        }
    }

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
