import Foundation

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}

enum Config {
    static let hookVersion = "0.17.2"

    static func sessionsDir() -> String {
        if let override = ProcessInfo.processInfo.environment["CCTOP_SESSIONS_DIR"],
           !override.isEmpty {
            ensureDirectoryExists(override)
            return override
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = (home as NSString).appendingPathComponent(".cctop/sessions")
        ensureDirectoryExists(dir)
        return dir
    }

    static func historyDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = (home as NSString).appendingPathComponent(".cctop/history")
        ensureDirectoryExists(dir)
        return dir
    }

    /// Directory where Claude Desktop stores per-session metadata (incl. the
    /// user-visible `title`), keyed by `cliSessionId`. Read-only — never created.
    static func claudeCodeSessionsDir() -> String {
        if let override = ProcessInfo.processInfo.environment["CCTOP_CLAUDE_CODE_SESSIONS_DIR"],
           !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString)
            .appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
    }

    /// Codex's local memory folder. Read-only — never created.
    static func codexMemoriesDir() -> String {
        if let override = ProcessInfo.processInfo.environment["CCTOP_CODEX_MEMORIES_DIR"],
           !override.isEmpty {
            return override
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".codex/memories")
    }

    /// Codex's session index (JSONL), which maps `id` (session_id) to the
    /// user-visible `thread_name`. Read-only — never created.
    static func codexSessionIndexPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CCTOP_CODEX_SESSION_INDEX"],
           !override.isEmpty {
            return override
        }
        return NSString(string: "~/.codex/session_index.jsonl").expandingTildeInPath
    }

    /// Codex Desktop's local thread state database. Read-only — never created.
    static func codexStateDatabasePath() -> String {
        if let override = ProcessInfo.processInfo.environment["CCTOP_CODEX_STATE_DB"],
           !override.isEmpty {
            return override
        }
        return NSString(string: "~/.codex/state_5.sqlite").expandingTildeInPath
    }

    static func standardizedPath(_ path: String) -> String {
        NSString(string: NSString(string: path).expandingTildeInPath).standardizingPath
    }

    private static func ensureDirectoryExists(_ path: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(
                atPath: path, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}

extension Session {
    private static let codexTitleGenerationPromptPrefix =
        "You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title"

    /// True for Codex Desktop's local memory-consolidation runs. These are maintenance
    /// artifacts, not user workspace sessions, so cctop marks their live files hidden.
    var isCodexMemoryMaintenanceSession: Bool {
        source == Session.codexSource
            && terminal?.bundleId == HostAppBundleID.codexDesktop
            && Config.standardizedPath(projectPath) == Config.standardizedPath(Config.codexMemoriesDir())
    }

    /// True for Codex Desktop's internal title-generation helper runs. They briefly create
    /// hook-visible conversations in the current project, but are not user workspace sessions.
    var isCodexDesktopTitleGenerationSession: Bool {
        source == Session.codexSource
            && terminal?.bundleId == HostAppBundleID.codexDesktop
            && (sessionName?.isEmpty ?? true)
            && (lastPrompt?.hasPrefix(Self.codexTitleGenerationPromptPrefix) == true)
            && (lastPrompt?.contains("Generate a concise UI title") == true)
    }

    var shouldAutoHide: Bool {
        isSubagentSession || isCodexMemoryMaintenanceSession || isCodexDesktopTitleGenerationSession
    }
}
