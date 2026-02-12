import Foundation

enum HookLogger {
    private static let dateFormatter: ISO8601DateFormatter = {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fmt
    }()

    private static func logsDir() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".cctop/logs")
    }

    private static func sessionLogPath(sessionId: String) -> String? {
        guard let dir = logsDir() else { return nil }
        return (dir as NSString).appendingPathComponent("\(sessionId).log")
    }

    static func sessionLabel(cwd: String, sessionId: String) -> String {
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        let abbrev = String(sessionId.prefix(8))
        return "\(project):\(abbrev)"
    }

    static func appendHookLog(
        sessionId: String,
        event: String,
        label: String,
        transition: String
    ) {
        guard let logPath = sessionLogPath(sessionId: sessionId) else { return }
        let timestamp = dateFormatter.string(from: Date())
        appendLine("\(timestamp) HOOK \(event) \(label) \(transition)\n", to: logPath)
    }

    static func logError(_ msg: String) {
        guard let dir = logsDir() else { return }
        let logPath = (dir as NSString).appendingPathComponent("_errors.log")
        let timestamp = dateFormatter.string(from: Date())
        appendLine("\(timestamp) ERROR \(msg)\n", to: logPath)
    }

    private static func appendLine(_ line: String, to path: String) {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    static func cleanupSessionLog(sessionId: String) {
        guard let logPath = sessionLogPath(sessionId: sessionId) else { return }
        try? FileManager.default.removeItem(atPath: logPath)
    }
}
