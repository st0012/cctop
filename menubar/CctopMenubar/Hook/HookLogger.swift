import Foundation

enum HookLogger {
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
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
        oldStatus: String,
        newStatus: String,
        note: String
    ) {
        guard let logPath = sessionLogPath(sessionId: sessionId) else { return }
        let dir = (logPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let extra = note.isEmpty ? "" : " (\(note))"
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) HOOK \(event) \(label) \(oldStatus) -> \(newStatus)\(extra)\n"

        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
        }
    }

    static func logError(_ msg: String) {
        guard let dir = logsDir() else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let logPath = (dir as NSString).appendingPathComponent("_errors.log")
        let timestamp = dateFormatter.string(from: Date())
        let line = "\(timestamp) ERROR \(msg)\n"

        if let handle = FileHandle(forWritingAtPath: logPath) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            FileManager.default.createFile(atPath: logPath, contents: Data(line.utf8))
        }
    }

    static func cleanupSessionLog(sessionId: String) {
        guard let logPath = sessionLogPath(sessionId: sessionId) else { return }
        try? FileManager.default.removeItem(atPath: logPath)
    }
}
