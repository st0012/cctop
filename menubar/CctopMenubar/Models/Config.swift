import Foundation

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}

enum Config {
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

    /// Codex's session index (JSONL), which maps `id` (session_id) to the
    /// user-visible `thread_name`. Read-only — never created.
    static func codexSessionIndexPath() -> String {
        if let override = ProcessInfo.processInfo.environment["CCTOP_CODEX_SESSION_INDEX"],
           !override.isEmpty {
            return override
        }
        return NSString(string: "~/.codex/session_index.jsonl").expandingTildeInPath
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
