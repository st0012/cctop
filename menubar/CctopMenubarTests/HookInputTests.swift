import XCTest
@testable import CctopMenubar

final class HookInputTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> Data {
        let projectDir = ProcessInfo.processInfo.environment["PROJECT_DIR"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // CctopMenubarTests/
                .deletingLastPathComponent()  // menubar/
                .deletingLastPathComponent()  // repo root
                .path
        let path = (projectDir as NSString).appendingPathComponent("fixtures/\(name).json")
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    // MARK: - SessionStart

    func testDecodeSessionStart() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SessionStart"))
        XCTAssertEqual(input.sessionId, "test-session-001")
        XCTAssertEqual(input.cwd, "/tmp/test-project")
        XCTAssertEqual(input.hookEventName, "SessionStart")
        XCTAssertEqual(input.transcriptPath, "/tmp/transcript.jsonl")
    }

    // MARK: - UserPromptSubmit

    func testDecodeUserPromptSubmit() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("UserPromptSubmit"))
        XCTAssertEqual(input.hookEventName, "UserPromptSubmit")
        XCTAssertEqual(input.prompt, "Fix the login bug")
    }

    // MARK: - Stop

    func testDecodeStop() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("Stop"))
        XCTAssertEqual(input.hookEventName, "Stop")
    }

    // MARK: - PreToolUse

    func testDecodePreToolUse() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PreToolUse"))
        XCTAssertEqual(input.hookEventName, "PreToolUse")
        XCTAssertEqual(input.toolName, "Bash")
        XCTAssertEqual(input.toolInput?["command"], "npm test")
    }

    // MARK: - PostToolUse

    func testDecodePostToolUse() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PostToolUse"))
        XCTAssertEqual(input.hookEventName, "PostToolUse")
        XCTAssertEqual(input.toolName, "Bash")
    }

    // MARK: - PostToolUseFailure

    func testDecodePostToolUseFailure() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PostToolUseFailure"))
        XCTAssertEqual(input.hookEventName, "PostToolUseFailure")
        XCTAssertEqual(input.error, "Command exited with code 1")
    }

    // MARK: - PermissionRequest

    func testDecodePermissionRequest() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PermissionRequest"))
        XCTAssertEqual(input.hookEventName, "PermissionRequest")
        XCTAssertEqual(input.toolName, "Bash")
        XCTAssertEqual(input.title, "Allow Bash: rm -rf /tmp/old")
        XCTAssertEqual(input.toolInput?["command"], "rm -rf /tmp/old")
    }

    // MARK: - Notification (idle)

    func testDecodeNotificationIdle() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("Notification-idle"))
        XCTAssertEqual(input.hookEventName, "Notification")
        XCTAssertEqual(input.notificationType, "idle_prompt")
        XCTAssertEqual(input.message, "Claude is waiting for input")
    }

    // MARK: - Notification (permission)

    func testDecodeNotificationPermission() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("Notification-permission"))
        XCTAssertEqual(input.hookEventName, "Notification")
        XCTAssertEqual(input.notificationType, "permission_prompt")
        XCTAssertEqual(input.message, "Permission needed for Bash")
    }

    // MARK: - SubagentStart

    func testDecodeSubagentStart() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SubagentStart"))
        XCTAssertEqual(input.hookEventName, "SubagentStart")
        XCTAssertEqual(input.agentId, "agent-abc-123")
        XCTAssertEqual(input.agentType, "general-purpose")
    }

    // MARK: - SubagentStop

    func testDecodeSubagentStop() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SubagentStop"))
        XCTAssertEqual(input.hookEventName, "SubagentStop")
        XCTAssertEqual(input.agentId, "agent-abc-123")
        XCTAssertEqual(input.agentType, "general-purpose")
    }

    // MARK: - PreCompact

    func testDecodePreCompact() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PreCompact"))
        XCTAssertEqual(input.hookEventName, "PreCompact")
    }

    // MARK: - PostCompact

    func testDecodePostCompact() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("PostCompact"))
        XCTAssertEqual(input.hookEventName, "PostCompact")
    }

    // MARK: - SessionError

    func testDecodeSessionError() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SessionError"))
        XCTAssertEqual(input.hookEventName, "SessionError")
        XCTAssertEqual(input.error, "Context window exceeded")
        XCTAssertEqual(input.message, "Session encountered an error")
    }

    // MARK: - SessionStart (opencode)

    func testDecodeSessionStartOpencode() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SessionStart-opencode"))
        XCTAssertEqual(input.sessionId, "opencode-12345")
        XCTAssertEqual(input.hookEventName, "SessionStart")
        XCTAssertEqual(input.source, "opencode")
        XCTAssertEqual(input.sessionName, "Fix login bug")
    }

    // MARK: - SessionEnd

    func testDecodeSessionEnd() throws {
        let input = try JSONDecoder().decode(HookInput.self, from: loadFixture("SessionEnd"))
        XCTAssertEqual(input.hookEventName, "SessionEnd")
    }

    // MARK: - Unknown fields are ignored

    func testUnknownFieldsIgnored() throws {
        let json = """
        {
          "session_id": "test",
          "cwd": "/tmp",
          "hook_event_name": "SessionStart",
          "model": "gpt-5.1-codex",
          "unknown_future_field": true
        }
        """
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        XCTAssertEqual(input.sessionId, "test")
    }

    // MARK: - Schema coverage

    func testAllFixturesHaveValidEventNames() throws {
        let validEvents: Set<String> = [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop",
            "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionRequest", "Notification",
            "SubagentStart", "SubagentStop", "PreCompact",
            "PostCompact", "SessionError"
        ]

        let fixtureNames = [
            "SessionStart", "SessionEnd", "UserPromptSubmit", "Stop",
            "PreToolUse", "PostToolUse", "PostToolUseFailure",
            "PermissionRequest", "Notification-idle", "Notification-permission",
            "SubagentStart", "SubagentStop", "PreCompact",
            "PostCompact", "SessionError",
            "SessionStart-opencode"
        ]

        for name in fixtureNames {
            let input = try JSONDecoder().decode(HookInput.self, from: loadFixture(name))
            XCTAssertTrue(
                validEvents.contains(input.hookEventName),
                "Fixture \(name) has unexpected event: \(input.hookEventName)"
            )
        }
    }
}
