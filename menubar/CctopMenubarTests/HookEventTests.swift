import XCTest
@testable import CctopMenubar

final class HookEventTests: XCTestCase {

    // MARK: - HookEvent.parse()

    func testParseSessionStart() {
        XCTAssertEqual(HookEvent.parse(hookName: "SessionStart", notificationType: nil), .sessionStart)
    }

    func testParseUserPromptSubmit() {
        XCTAssertEqual(HookEvent.parse(hookName: "UserPromptSubmit", notificationType: nil), .userPromptSubmit)
    }

    func testParsePreToolUse() {
        XCTAssertEqual(HookEvent.parse(hookName: "PreToolUse", notificationType: nil), .preToolUse)
    }

    func testParsePostToolUse() {
        XCTAssertEqual(HookEvent.parse(hookName: "PostToolUse", notificationType: nil), .postToolUse)
    }

    func testParseStop() {
        XCTAssertEqual(HookEvent.parse(hookName: "Stop", notificationType: nil), .stop)
    }

    func testParsePermissionRequest() {
        XCTAssertEqual(HookEvent.parse(hookName: "PermissionRequest", notificationType: nil), .permissionRequest)
    }

    func testParsePreCompact() {
        XCTAssertEqual(HookEvent.parse(hookName: "PreCompact", notificationType: nil), .preCompact)
    }

    func testParseSessionEnd() {
        XCTAssertEqual(HookEvent.parse(hookName: "SessionEnd", notificationType: nil), .sessionEnd)
    }

    func testParseUnknownHookName() {
        XCTAssertEqual(HookEvent.parse(hookName: "FutureHook", notificationType: nil), .unknown)
    }

    func testParseNotificationIdlePrompt() {
        XCTAssertEqual(HookEvent.parse(hookName: "Notification", notificationType: "idle_prompt"), .notificationIdle)
    }

    func testParseNotificationPermissionPrompt() {
        XCTAssertEqual(HookEvent.parse(hookName: "Notification", notificationType: "permission_prompt"), .notificationPermission)
    }

    func testParseNotificationNilType() {
        XCTAssertEqual(HookEvent.parse(hookName: "Notification", notificationType: nil), .notificationOther)
    }

    func testParseNotificationUnknownType() {
        XCTAssertEqual(HookEvent.parse(hookName: "Notification", notificationType: "future_type"), .notificationOther)
    }

    // MARK: - Transition.forEvent() — Stop always idles

    func testStopAlwaysTransitionsToIdle() {
        let allStatuses: [SessionStatus] = [.idle, .working, .compacting, .waitingPermission, .waitingInput, .needsAttention]
        for status in allStatuses {
            XCTAssertEqual(Transition.forEvent(status, event: .stop), .idle, "Stop from \(status) should -> idle")
        }
    }

    // MARK: - Transition.forEvent() — SessionStart always idles

    func testSessionStartAlwaysTransitionsToIdle() {
        let allStatuses: [SessionStatus] = [.idle, .working, .compacting, .waitingPermission, .waitingInput, .needsAttention]
        for status in allStatuses {
            XCTAssertEqual(Transition.forEvent(status, event: .sessionStart), .idle, "SessionStart from \(status) should -> idle")
        }
    }

    // MARK: - Transition.forEvent() — Working transitions

    func testUserPromptSubmitTransitionsToWorking() {
        XCTAssertEqual(Transition.forEvent(.idle, event: .userPromptSubmit), .working)
        XCTAssertEqual(Transition.forEvent(.waitingInput, event: .userPromptSubmit), .working)
    }

    func testPreToolUseTransitionsToWorking() {
        XCTAssertEqual(Transition.forEvent(.working, event: .preToolUse), .working)
        XCTAssertEqual(Transition.forEvent(.idle, event: .preToolUse), .working)
    }

    func testPostToolUseTransitionsToWorking() {
        XCTAssertEqual(Transition.forEvent(.working, event: .postToolUse), .working)
    }

    // MARK: - Transition.forEvent() — Notification transitions

    func testNotificationIdleTransitionsToWaitingInput() {
        XCTAssertEqual(Transition.forEvent(.working, event: .notificationIdle), .waitingInput)
        XCTAssertEqual(Transition.forEvent(.idle, event: .notificationIdle), .waitingInput)
    }

    func testNotificationPermissionPreservesStatus() {
        // PermissionRequest handles the transition; Notification fires ~6s later and would race with PostToolUse.
        XCTAssertNil(Transition.forEvent(.working, event: .notificationPermission))
        XCTAssertNil(Transition.forEvent(.waitingPermission, event: .notificationPermission))
    }

    func testPermissionRequestTransitionsToWaitingPermission() {
        XCTAssertEqual(Transition.forEvent(.working, event: .permissionRequest), .waitingPermission)
        XCTAssertEqual(Transition.forEvent(.idle, event: .permissionRequest), .waitingPermission)
    }

    func testPreCompactTransitionsToCompacting() {
        XCTAssertEqual(Transition.forEvent(.working, event: .preCompact), .compacting)
    }

    // MARK: - Transition.forEvent() — Preserve status (nil return)

    func testNotificationOtherPreservesStatus() {
        XCTAssertNil(Transition.forEvent(.working, event: .notificationOther))
        XCTAssertNil(Transition.forEvent(.idle, event: .notificationOther))
    }

    func testSessionEndPreservesStatus() {
        XCTAssertNil(Transition.forEvent(.working, event: .sessionEnd))
        XCTAssertNil(Transition.forEvent(.idle, event: .sessionEnd))
    }

    func testUnknownEventPreservesStatus() {
        XCTAssertNil(Transition.forEvent(.working, event: .unknown))
        XCTAssertNil(Transition.forEvent(.idle, event: .unknown))
    }

    // MARK: - Exhaustive transition test

    func testAllTransitionsExhaustive() {
        let allStatuses: [SessionStatus] = [.idle, .working, .compacting, .waitingPermission, .waitingInput, .needsAttention]
        let allEvents: [HookEvent] = [
            .sessionStart, .userPromptSubmit, .preToolUse, .postToolUse,
            .stop, .notificationIdle, .notificationPermission, .notificationOther,
            .permissionRequest, .preCompact, .sessionEnd, .unknown
        ]

        // Every event x status combination should not crash
        for status in allStatuses {
            for event in allEvents {
                // Just verify it doesn't crash — specific values tested above
                _ = Transition.forEvent(status, event: event)
            }
        }

        // Verify expected transition counts:
        // Events that always transition (non-nil): sessionStart, userPromptSubmit, preToolUse,
        //   postToolUse, stop, notificationIdle, permissionRequest, preCompact
        // Events that always preserve (nil): notificationPermission, notificationOther, sessionEnd, unknown
        for status in allStatuses {
            XCTAssertNotNil(Transition.forEvent(status, event: .sessionStart))
            XCTAssertNotNil(Transition.forEvent(status, event: .userPromptSubmit))
            XCTAssertNotNil(Transition.forEvent(status, event: .preToolUse))
            XCTAssertNotNil(Transition.forEvent(status, event: .postToolUse))
            XCTAssertNotNil(Transition.forEvent(status, event: .stop))
            XCTAssertNotNil(Transition.forEvent(status, event: .notificationIdle))
            XCTAssertNotNil(Transition.forEvent(status, event: .permissionRequest))
            XCTAssertNotNil(Transition.forEvent(status, event: .preCompact))
            XCTAssertNil(Transition.forEvent(status, event: .notificationPermission))
            XCTAssertNil(Transition.forEvent(status, event: .notificationOther))
            XCTAssertNil(Transition.forEvent(status, event: .sessionEnd))
            XCTAssertNil(Transition.forEvent(status, event: .unknown))
        }
    }

    // MARK: - sanitizeSessionId

    func testSanitizeRemovesForwardSlash() {
        XCTAssertEqual(Session.sanitizeSessionId(raw: "foo/bar"), "foobar")
    }

    func testSanitizeRemovesBackslash() {
        XCTAssertEqual(Session.sanitizeSessionId(raw: "foo\\bar"), "foobar")
    }

    func testSanitizeRemovesDoubleDot() {
        XCTAssertEqual(Session.sanitizeSessionId(raw: "../../.bashrc"), "bashrc")
    }

    func testSanitizePathTraversal() {
        XCTAssertEqual(Session.sanitizeSessionId(raw: "../etc/passwd"), "etcpasswd")
    }

    func testSanitizeDoubleDotOnly() {
        XCTAssertEqual(Session.sanitizeSessionId(raw: ".."), "")
    }

    func testSanitizeCapsLength() {
        let long = String(repeating: "a", count: 100)
        XCTAssertEqual(Session.sanitizeSessionId(raw: long).count, 64)
    }

    func testSanitizeNormalIdUnchanged() {
        XCTAssertEqual(Session.sanitizeSessionId(raw: "abc-123-def"), "abc-123-def")
    }

    func testSanitizeUUIDUnchanged() {
        let uuid = "550e8400-e29b-41d4-a716-446655440000"
        XCTAssertEqual(Session.sanitizeSessionId(raw: uuid), uuid)
    }
}
