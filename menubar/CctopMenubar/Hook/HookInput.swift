import Foundation

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
    var error: String?
    /// Whether Stop was triggered by user interrupt (Ctrl+C). Reserved for future use:
    /// could distinguish idle (interrupted) from waitingInput (normal completion).
    var isInterrupt: Bool?
    var agentId: String?
    var agentType: String?
    var isSubagentSession: Bool?
    var source: String?
    var harnessName: String?
    var sessionName: String?

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
        case message, title, trigger, error
        case isInterrupt = "is_interrupt"
        case agentId = "agent_id"
        case agentType = "agent_type"
        case isSubagentSession = "is_subagent"
        case source
        case harnessName = "harness_name"
        case sessionName = "session_name"
    }

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
        error = try container.decodeIfPresent(String.self, forKey: .error)
        isInterrupt = try container.decodeIfPresent(Bool.self, forKey: .isInterrupt)
        agentId = try container.decodeIfPresent(String.self, forKey: .agentId)
        agentType = try container.decodeIfPresent(String.self, forKey: .agentType)
        isSubagentSession = try container.decodeIfPresent(Bool.self, forKey: .isSubagentSession)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        harnessName = try container.decodeIfPresent(String.self, forKey: .harnessName)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)

        if container.contains(.toolInput) {
            let rawDict = try? container.decode([String: ToolInputValue].self, forKey: .toolInput)
            toolInput = rawDict?.compactMapValues { $0.stringValue }
        } else {
            toolInput = nil
        }
    }

    /// Identifies which tool harness sent this event. Resolution order:
    ///   1. `harness_name` JSON field (set by plugins, or injected via `--harness` CLI arg)
    ///   2. `source` JSON field (legacy fallback — old opencode/pi plugins send this)
    ///
    /// The allowlist on the `source` fallback guards against Codex's `source` field,
    /// which carries the SessionStart trigger kind ("startup"/"resume"/"clear"), not a
    /// tool name.
    ///
    /// MIGRATION(harness_name): Remove the `source` fallback after opencode/pi plugins
    /// shipping `harness_name` have been in the wild for at least one release cycle.
    private static let knownHarnesses: Set<String> = ["cc", "codex", "opencode", "pi"]

    var resolvedHarnessName: String? {
        if let harnessName { return harnessName }
        // MIGRATION(harness_name): Legacy fallback for old plugins that send `source`.
        if let source, Self.knownHarnesses.contains(source) { return source }
        return nil
    }
}

private enum ToolInputValue: Decodable {
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
}
