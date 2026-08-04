import Foundation

struct RecentProject: Identifiable, Equatable {
    let projectPath: String
    let projectName: String
    let lastBranch: String
    let lastSessionAt: Date
    let sessionCount: Int
    let lastEditor: String?
    /// Captured host bundle ID, kept alongside the display name because one name
    /// can cover several bundle IDs (Warp release channels). Defaults to nil so
    /// legacy history projections keep name-based opening.
    var lastEditorBundleId: String?
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

    static func projectOpenerName(from terminal: TerminalInfo?) -> String? {
        guard let hostApp = projectOpener(from: terminal) else { return nil }
        return hostApp.displayName
    }

    /// The captured bundle ID, kept only when it identifies a known project
    /// opener on its own. History files are user-writable, so the resolver
    /// validates again before opening anything with it.
    static func projectOpenerBundleId(from terminal: TerminalInfo?) -> String? {
        guard let bundleId = terminal?.bundleId,
              HostApp.projectOpener(fromBundleIdentifier: bundleId) != nil else { return nil }
        return bundleId
    }

    static func agentName(from session: Session) -> String? {
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

    private var compactProjectPath: String {
        let home = NSHomeDirectory()
        if projectPath == home { return "~" }
        if projectPath.hasPrefix(home + "/") {
            return "~" + String(projectPath.dropFirst(home.count))
        }
        return projectPath
    }
}
