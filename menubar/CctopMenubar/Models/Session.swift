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
    var pidStartTime: TimeInterval?
    var lastTool: String?
    var lastToolDetail: String?
    var notificationMessage: String?
    var sessionName: String?

    var id: String { pid.map { String($0) } ?? sessionId }

    var displayName: String {
        sessionName ?? projectName
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case projectPath = "project_path"
        case projectName = "project_name"
        case branch, status
        case lastPrompt = "last_prompt"
        case lastActivity = "last_activity"
        case startedAt = "started_at"
        case terminal, pid
        case pidStartTime = "pid_start_time"
        case lastTool = "last_tool"
        case lastToolDetail = "last_tool_detail"
        case notificationMessage = "notification_message"
        case sessionName = "session_name"
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
        pidStartTime: TimeInterval? = nil,
        lastTool: String?,
        lastToolDetail: String?,
        notificationMessage: String?,
        sessionName: String? = nil
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
        self.pidStartTime = pidStartTime
        self.lastTool = lastTool
        self.lastToolDetail = lastToolDetail
        self.notificationMessage = notificationMessage
        self.sessionName = sessionName
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
        self.pidStartTime = nil
        self.lastTool = nil
        self.lastToolDetail = nil
        self.notificationMessage = nil
        self.sessionName = nil
    }

    // MARK: - File I/O

    static func fromFile(path: String) throws -> Session {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
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

    // MARK: - Utilities

    static func sanitizeSessionId(raw: String) -> String {
        raw.replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "..", with: "")
    }

    /// Returns a copy with a new session_id (and optionally updated branch/terminal).
    /// Used when the same OS process gets a new CC session_id on resume.
    func withSessionId(_ newId: String, branch: String? = nil, terminal: TerminalInfo? = nil) -> Session {
        Session(
            sessionId: newId,
            projectPath: projectPath,
            projectName: projectName,
            branch: branch ?? self.branch,
            status: status,
            lastPrompt: lastPrompt,
            lastActivity: lastActivity,
            startedAt: startedAt,
            terminal: terminal ?? self.terminal,
            pid: pid,
            pidStartTime: pidStartTime,
            lastTool: lastTool,
            lastToolDetail: lastToolDetail,
            notificationMessage: notificationMessage,
            sessionName: sessionName
        )
    }

    static func extractProjectName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    static func processStartTime(pid: UInt32) -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_starttime
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
    }

    var isAlive: Bool {
        if let pid {
            let processRunning: Bool
            if kill(Int32(pid), 0) == 0 {
                processRunning = true
            } else {
                processRunning = errno == EPERM
            }
            guard processRunning else { return false }
            // Check PID reuse: if we recorded a start time, verify it still matches
            if let stored = pidStartTime,
               let current = Self.processStartTime(pid: pid),
               abs(stored - current) > 1.0 {
                return false
            }
            return true
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
