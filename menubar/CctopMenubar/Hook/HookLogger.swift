import Foundation

/// Writes per-session hook logs and the error log under `logsDir`
/// (default: `~/.cctop/logs`). Construct with a custom directory to keep
/// test runs out of the real home directory.
struct HookLogger {
    let logsDir: String

    init(logsDir: String = HookLogger.defaultLogsDir()) {
        self.logsDir = logsDir
    }

    static func defaultLogsDir() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".cctop/logs")
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    static func sessionLabel(cwd: String, sessionId: String) -> String {
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let abbrev = String(sessionId.prefix(8))
        return "\(project):\(abbrev)"
    }

    /// Convenience for call sites without an injected logger (e.g. HookMain's
    /// argument/stdin errors, before any dependencies are constructed).
    /// Writes to the default logs directory.
    static func logError(_ msg: String) {
        HookLogger().logError(msg)
    }

    func appendHookLog(
        sessionId: String,
        event: String,
        label: String,
        transition: String
    ) {
        let timestamp = Self.dateFormatter.string(from: Date())
        appendLine("\(timestamp) HOOK \(event) \(label) \(transition)\n", to: sessionLogPath(sessionId: sessionId))
    }

    func logError(_ msg: String) {
        let logPath = (logsDir as NSString).appendingPathComponent("_errors.log")
        let timestamp = Self.dateFormatter.string(from: Date())
        appendLine("\(timestamp) ERROR \(msg)\n", to: logPath)
    }

    func cleanupSessionLog(sessionId: String) {
        try? FileManager.default.removeItem(atPath: sessionLogPath(sessionId: sessionId))
    }

    private func sessionLogPath(sessionId: String) -> String {
        (logsDir as NSString).appendingPathComponent("\(sessionId).log")
    }

    private func appendLine(_ line: String, to path: String) {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try? fm.createDirectory(
            atPath: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            fm.createFile(atPath: path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}
