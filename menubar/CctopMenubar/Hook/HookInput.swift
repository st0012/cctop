import Foundation

/// Input JSON schema from Claude Code hooks.
struct HookInput: Codable {
    let sessionId: String
    let cwd: String
    var transcriptPath: String?
    var permissionMode: String?
    let hookEventName: String
    var prompt: String?
    var toolName: String?
    var toolInput: [String: String]?
    var notificationType: String?
    var message: String?
    var title: String?
    var trigger: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case permissionMode = "permission_mode"
        case hookEventName = "hook_event_name"
        case prompt
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case notificationType = "notification_type"
        case message, title, trigger
    }

    /// Custom decoder to handle tool_input which may contain non-string values.
    /// We extract only the string values we care about.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cwd = try container.decode(String.self, forKey: .cwd)
        transcriptPath = try container.decodeIfPresent(String.self, forKey: .transcriptPath)
        permissionMode = try container.decodeIfPresent(String.self, forKey: .permissionMode)
        hookEventName = try container.decode(String.self, forKey: .hookEventName)
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        notificationType = try container.decodeIfPresent(String.self, forKey: .notificationType)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        trigger = try container.decodeIfPresent(String.self, forKey: .trigger)

        // tool_input is a JSON object with mixed value types.
        // We only need string values, so extract those and ignore the rest.
        if container.contains(.toolInput) {
            let rawDict = try? container.decode([String: ToolInputValue].self, forKey: .toolInput)
            toolInput = rawDict?.compactMapValues { $0.stringValue }
        } else {
            toolInput = nil
        }
    }
}

/// Helper to decode mixed JSON values from tool_input, extracting strings only.
private enum ToolInputValue: Codable {
    case string(String)
    case other

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            self = .other
        }
    }

    func encode(to encoder: Encoder) throws {
        // Not needed for our use case
    }
}
