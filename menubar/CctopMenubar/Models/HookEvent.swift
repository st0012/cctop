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
    /// Returns nil to mean "preserve current status".
    static func forEvent(_ current: SessionStatus, event: HookEvent) -> SessionStatus? {
        switch event {
        case .sessionStart, .stop: return .idle
        case .userPromptSubmit, .preToolUse, .postToolUse: return .working
        case .notificationIdle: return .waitingInput
        case .permissionRequest: return .waitingPermission
        case .preCompact: return .compacting
        // notificationPermission: PermissionRequest already sets waitingPermission immediately.
        // The Notification fires ~6s later and would race with PostToolUse if the user allows quickly.
        case .notificationPermission, .notificationOther, .sessionEnd, .unknown: return nil
        }
    }
}
