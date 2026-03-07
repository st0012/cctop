import Foundation

enum HookEvent: Equatable {
    case sessionStart
    case userPromptSubmit
    case preToolUse
    case postToolUse
    case postToolUseFailure
    case stop
    case notificationIdle
    case notificationPermission
    case notificationOther
    case permissionRequest
    case subagentStart
    case subagentStop
    case preCompact
    case sessionEnd
    case unknown

    private static let hookNameMap: [String: HookEvent] = [
        "SessionStart": .sessionStart, "UserPromptSubmit": .userPromptSubmit,
        "PreToolUse": .preToolUse, "PostToolUse": .postToolUse,
        "PostToolUseFailure": .postToolUseFailure, "Stop": .stop,
        "PermissionRequest": .permissionRequest, "PreCompact": .preCompact,
        "SubagentStart": .subagentStart, "SubagentStop": .subagentStop,
        "SessionEnd": .sessionEnd,
    ]

    static func parse(hookName: String, notificationType: String?) -> HookEvent {
        if hookName == "Notification" {
            switch notificationType {
            case "idle_prompt", "elicitation_dialog": return .notificationIdle
            case "permission_prompt": return .notificationPermission
            default: return .notificationOther
            }
        }
        return hookNameMap[hookName] ?? .unknown
    }
}

enum Transition {
    /// Returns nil to mean "preserve current status".
    static func forEvent(_ current: SessionStatus, event: HookEvent) -> SessionStatus? {
        switch event {
        case .sessionStart: return .idle
        case .stop: return .waitingInput
        case .userPromptSubmit, .preToolUse, .postToolUse, .postToolUseFailure: return .working
        case .notificationIdle: return .waitingInput
        case .permissionRequest: return .waitingPermission
        case .preCompact: return .compacting
        // notificationPermission: PermissionRequest already sets waitingPermission immediately.
        // The Notification fires ~6s later and would race with PostToolUse if the user allows quickly.
        case .subagentStart, .subagentStop: return nil
        case .notificationPermission, .notificationOther, .sessionEnd, .unknown: return nil
        }
    }
}
