import Foundation

/// Unified editor classification used by focusTerminal, openInEditor, and editorIcon.
enum EditorKind {
    case vscode
    case cursor
    case windsurf
    case zed
    case iterm2
    case warp
    case terminal
    case unknown

    /// Match lowercased editor/program name to an EditorKind.
    static func from(editorName: String?) -> EditorKind {
        guard let name = editorName, !name.isEmpty else { return .unknown }
        let lower = name.lowercased()

        // Order matters: "cursor" before "code" because Cursor's process name contains "code"
        if lower.contains("cursor") { return .cursor }
        if lower.contains("windsurf") { return .windsurf }
        if lower.contains("zed") { return .zed }
        if lower.contains("code") { return .vscode }
        if lower.contains("iterm") { return .iterm2 }
        if lower.contains("warp") { return .warp }
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
        case .unknown: return nil
        }
    }

    var sfSymbol: String {
        switch self {
        case .vscode, .cursor, .windsurf, .zed:
            return "chevron.left.forwardslash.chevron.right"
        case .iterm2, .warp, .terminal, .unknown:
            return "terminal"
        }
    }

    /// Whether this editor supports `.code-workspace` files.
    var usesWorkspaceFile: Bool {
        switch self {
        case .vscode, .cursor, .windsurf, .zed: return true
        case .iterm2, .warp, .terminal, .unknown: return false
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
