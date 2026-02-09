import Foundation

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
    var terminal: TerminalInfo
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

    var isAlive: Bool {
        guard let pid else { return true }
        return kill(Int32(pid), 0) == 0
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
