import Foundation

enum HookEvent: Equatable {
    case sessionStart
    case userPromptSubmit
    case preToolUse
    case postToolUse
    case stop
    case notificationIdle
    case notificationPermission
    case notificationOther
    case permissionRequest
    case preCompact
    case sessionEnd
    case unknown

    static func parse(hookName: String, notificationType: String?) -> HookEvent {
        switch hookName {
        case "SessionStart": return .sessionStart
        case "UserPromptSubmit": return .userPromptSubmit
        case "PreToolUse": return .preToolUse
        case "PostToolUse": return .postToolUse
        case "Stop": return .stop
        case "Notification":
            switch notificationType {
            case "idle_prompt": return .notificationIdle
            case "permission_prompt": return .notificationPermission
            default: return .notificationOther
            }
        case "PermissionRequest": return .permissionRequest
        case "PreCompact": return .preCompact
        case "SessionEnd": return .sessionEnd
        default: return .unknown
        }
    }
}

enum Transition {
    /// Determine the next status for a given hook event.
    /// Returns nil to mean "preserve current status" (different from transitioning to same state).
    static func forEvent(_ current: SessionStatus, event: HookEvent) -> SessionStatus? {
        switch event {
        case .sessionStart: return .idle
        case .userPromptSubmit: return .working
        case .preToolUse: return .working
        case .postToolUse: return .working
        case .stop: return .idle
        case .notificationIdle: return .waitingInput
        case .notificationPermission: return .waitingPermission
        case .notificationOther: return nil
        case .permissionRequest: return .waitingPermission
        case .preCompact: return .compacting
        case .sessionEnd: return nil
        case .unknown: return nil
        }
    }
}
