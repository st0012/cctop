import Foundation

struct RecentProject: Identifiable, Equatable {
    let projectPath: String
    let projectName: String
    let lastBranch: String
    let lastSessionAt: Date
    let sessionCount: Int
    let lastEditor: String?
    let lastAgent: String?
    let workspaceFile: String?

    var id: String { projectPath }

    var relativeTime: String {
        lastSessionAt.relativeDescription
    }

    var editorIcon: String {
        guard let editorHostApp else { return "folder" }
        return editorHostApp.sfSymbol
    }

    var opensWithProjectEditor: Bool {
        editorHostApp != nil
    }

    var openActionLabel: String {
        guard let openerName else { return "Open Project Folder" }
        return "Open in \(openerName)"
    }

    var openHelpText: String {
        guard let openerName else { return "Click to open project folder" }
        return "Click to open project in \(openerName)"
    }

    var metadataText: String {
        metadataParts.joined(separator: " \u{00B7} ")
    }

    var pathContext: String {
        compactProjectPath
    }

    var metadataEvidenceText: String {
        metadataEvidenceParts.joined(separator: " \u{00B7} ")
    }

    var metadataParts: [String] {
        [pathContext] + metadataEvidenceParts
    }

    private var metadataEvidenceParts: [String] {
        var parts: [String] = []
        if let displayBranch { parts.append(displayBranch) }
        if let lastAgent { parts.append(lastAgent) }
        parts.append("\(sessionCount) session\(sessionCount == 1 ? "" : "s")")
        return parts
    }

    static func projectEditorName(from terminal: TerminalInfo?) -> String? {
        guard let program = terminal?.program, !program.isEmpty else { return nil }
        guard HostApp.projectEditor(fromProgramName: program) != nil else { return nil }
        return program
    }

    static func agentName(from session: Session) -> String? {
        if session.isCodexDesktopHost { return "Codex Desktop" }
        if session.isClaudeDesktopHost { return "Claude Desktop" }
        switch session.source {
        case Session.codexSource?: return "Codex"
        case Session.ccSource?: return "Claude Code"
        case Session.opencodeSource?: return "opencode"
        case Session.piSource?: return "pi"
        case .some(let source) where !source.isEmpty: return source
        default: return nil
        }
    }

    private var editorHostApp: HostApp? {
        HostApp.projectEditor(fromProgramName: lastEditor)
    }

    private var openerName: String? {
        switch editorHostApp {
        case .vscode?: return "VS Code"
        case .cursor?: return "Cursor"
        case .windsurf?: return "Windsurf"
        case .zed?: return "Zed"
        default: return nil
        }
    }

    private var displayBranch: String? {
        let trimmed = lastBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "unknown" else { return nil }
        return trimmed
    }

    private var compactProjectPath: String {
        let home = NSHomeDirectory()
        if projectPath == home { return "~" }
        if projectPath.hasPrefix(home + "/") {
            return "~" + String(projectPath.dropFirst(home.count))
        }
        return projectPath
    }
}
