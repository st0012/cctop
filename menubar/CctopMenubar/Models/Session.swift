import Foundation

extension JSONEncoder {
    static let sessionEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()
}

extension JSONDecoder {
    static let sessionDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFractional.date(from: string) { return date }
            if let date = withoutFractional.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
        return decoder
    }()
}

struct TerminalInfo: Codable {
    let program: String
    let sessionId: String?
    let tty: String?

    enum CodingKeys: String, CodingKey {
        case program
        case sessionId = "session_id"
        case tty
    }

    init(program: String = "", sessionId: String? = nil, tty: String? = nil) {
        self.program = program
        self.sessionId = sessionId
        self.tty = tty
    }
}

struct Session: Codable, Identifiable {
    let sessionId: String
    let projectPath: String
    let projectName: String
    var branch: String
    var status: SessionStatus
    var lastPrompt: String?
    var lastActivity: Date
    var startedAt: Date
    var terminal: TerminalInfo?
    var pid: UInt32?
    var lastTool: String?
    var lastToolDetail: String?
    var notificationMessage: String?

    var id: String { sessionId }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case projectPath = "project_path"
        case projectName = "project_name"
        case branch, status
        case lastPrompt = "last_prompt"
        case lastActivity = "last_activity"
        case startedAt = "started_at"
        case terminal, pid
        case lastTool = "last_tool"
        case lastToolDetail = "last_tool_detail"
        case notificationMessage = "notification_message"
    }

    // MARK: - Constructors

    /// Full memberwise init (used by mocks and tests).
    init(
        sessionId: String,
        projectPath: String,
        projectName: String,
        branch: String,
        status: SessionStatus,
        lastPrompt: String?,
        lastActivity: Date,
        startedAt: Date,
        terminal: TerminalInfo?,
        pid: UInt32?,
        lastTool: String?,
        lastToolDetail: String?,
        notificationMessage: String?
    ) {
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.projectName = projectName
        self.branch = branch
        self.status = status
        self.lastPrompt = lastPrompt
        self.lastActivity = lastActivity
        self.startedAt = startedAt
        self.terminal = terminal
        self.pid = pid
        self.lastTool = lastTool
        self.lastToolDetail = lastToolDetail
        self.notificationMessage = notificationMessage
    }

    /// Convenience init for creating new sessions (used by cctop-hook).
    init(sessionId: String, projectPath: String, branch: String, terminal: TerminalInfo) {
        self.sessionId = sessionId
        self.projectPath = projectPath
        self.projectName = Self.extractProjectName(projectPath)
        self.branch = branch
        self.status = .idle
        self.lastPrompt = nil
        self.lastActivity = Date()
        self.startedAt = Date()
        self.terminal = terminal
        self.pid = nil
        self.lastTool = nil
        self.lastToolDetail = nil
        self.notificationMessage = nil
    }

    // MARK: - File I/O

    static func fromFile(path: String) throws -> Session {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
    }

    static func loadAll(sessionsDir: String) -> [Session] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: sessionsDir),
              let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) else {
            return []
        }

        var sessions: [Session] = []
        for entry in entries {
            guard entry.hasSuffix(".json"), !entry.hasSuffix(".tmp") else { continue }
            let path = (sessionsDir as NSString).appendingPathComponent(entry)
            if let session = try? fromFile(path: path) {
                sessions.append(session)
            }
        }
        return sessions
    }

    func writeToFile(path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try JSONEncoder.sessionEncoder.encode(self)
        let tempPath = path + ".tmp"
        let tempURL = URL(fileURLWithPath: tempPath)
        let destURL = URL(fileURLWithPath: path)
        try data.write(to: tempURL)

        // Atomic replace: rename(2) overwrites existing files on POSIX.
        // Foundation's moveItem does NOT, so use replaceItemAt or POSIX rename.
        if rename(tempPath, path) != 0 {
            // Fallback: remove + move
            try? fm.removeItem(at: destURL)
            try fm.moveItem(at: tempURL, to: destURL)
        }
    }

    func writeToDir(sessionsDir: String) throws {
        let path = filePath(sessionsDir: sessionsDir)
        try writeToFile(path: path)
    }

    func filePath(sessionsDir: String) -> String {
        let safeId = Self.sanitizeSessionId(raw: sessionId)
        return (sessionsDir as NSString).appendingPathComponent("\(safeId).json")
    }

    // MARK: - Mutation

    mutating func reset() {
        status = .idle
        lastTool = nil
        lastToolDetail = nil
        notificationMessage = nil
        lastActivity = Date()
    }

    // MARK: - Utilities

    static func sanitizeSessionId(raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "..", with: "")
    }

    static func extractProjectName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    var isAlive: Bool {
        if let pid {
            if kill(Int32(pid), 0) == 0 { return true }
            return errno == EPERM
        }
        return -lastActivity.timeIntervalSinceNow < 4 * 3600
    }

    var relativeTime: String {
        let seconds = Int(-lastActivity.timeIntervalSinceNow)
        if seconds < 0 { return "just now" }
        if seconds >= 86400 { return "\(seconds / 86400)d ago" }
        if seconds >= 3600 { return "\(seconds / 3600)h ago" }
        if seconds >= 60 { return "\(seconds / 60)m ago" }
        return "\(seconds)s ago"
    }

    var contextLine: String? {
        switch status {
        case .idle: return nil
        case .compacting: return "Compacting context..."
        case .waitingPermission:
            return notificationMessage ?? "Permission needed"
        case .waitingInput, .needsAttention:
            return promptSnippet
        case .working:
            if let tool = lastTool {
                return formatToolDisplay(tool: tool, detail: lastToolDetail)
            }
            return promptSnippet
        }
    }

    private var promptSnippet: String? {
        lastPrompt.map { "\"\(String($0.prefix(36)))\"" }
    }

    private func formatToolDisplay(tool: String, detail: String?) -> String {
        guard let detail else { return "\(tool)..." }
        let fileName = URL(fileURLWithPath: detail).lastPathComponent
        switch tool {
        case "Bash": return "Running: \(detail.prefix(30))"
        case "Edit": return "Editing \(fileName)"
        case "Write": return "Writing \(fileName)"
        case "Read": return "Reading \(fileName)"
        case "Grep": return "Searching: \(detail.prefix(30))"
        case "Glob": return "Finding: \(detail.prefix(30))"
        case "WebFetch": return "Fetching: \(detail.prefix(30))"
        case "WebSearch": return "Searching: \(detail.prefix(30))"
        case "Task": return "Task: \(detail.prefix(30))"
        default: return "\(tool): \(detail.prefix(30))"
        }
    }
}
