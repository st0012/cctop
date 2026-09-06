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
        guard let openerHostApp else { return "folder" }
        return openerHostApp.sfSymbol
    }

    var opensWithProjectApp: Bool {
        openerHostApp != nil
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
        Self.compactProjectPath(projectPath)
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

    static func projectOpenerName(from terminal: TerminalInfo?) -> String? {
        guard let hostApp = projectOpener(from: terminal) else { return nil }
        return hostApp.displayName
    }

    static func agentName(from session: SessionData) -> String? {
        if session.isClaudeDesktopHost { return "Claude Desktop" }
        switch session.source {
        case SessionData.codexSource?: return "Codex"
        case SessionData.ccSource?: return "Claude Code"
        case SessionData.opencodeSource?: return "opencode"
        case SessionData.piSource?: return "pi"
        case .some(let source) where !source.isEmpty: return source
        default: return nil
        }
    }

    private static func projectOpener(from terminal: TerminalInfo?) -> HostApp? {
        guard let terminal else { return nil }
        return HostApp.projectOpener(fromBundleIdentifier: terminal.bundleId)
            ?? HostApp.projectOpener(fromProgramName: terminal.program)
    }

    private var openerHostApp: HostApp? {
        HostApp.projectOpener(fromProgramName: lastEditor)
    }

    private var openerName: String? {
        openerHostApp?.displayName
    }

    private var displayBranch: String? {
        let trimmed = lastBranch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lowercased() != "unknown" else { return nil }
        return trimmed
    }

    /// Abbreviate the current user's home directory prefix to `~`.
    static func compactProjectPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}
