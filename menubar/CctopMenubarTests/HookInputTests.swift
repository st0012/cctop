import XCTest
@testable import CctopMenubar

final class HookInputTests: XCTestCase {

    private func loadFixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixturesDirectory().appendingPathComponent("\(name).json"))
    }

    private func fixturesDirectory() -> URL {
        let projectDir = ProcessInfo.processInfo.environment["PROJECT_DIR"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()  // CctopMenubarTests/
                .deletingLastPathComponent()  // menubar/
                .deletingLastPathComponent()  // repo root
                .path
        return URL(fileURLWithPath: projectDir).appendingPathComponent("fixtures")
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
        XCTAssertEqual(input.harnessName, "opencode")
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

    // MARK: - Fixture coverage

    func testAllFixturesDecode() throws {
        let fixtureURLs = try FileManager.default.contentsOfDirectory(
            at: fixturesDirectory(),
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "json" }

        XCTAssertFalse(fixtureURLs.isEmpty)

        for url in fixtureURLs {
            XCTAssertNoThrow(
                try JSONDecoder().decode(HookInput.self, from: Data(contentsOf: url)),
                "Fixture \(url.lastPathComponent) should decode"
            )
        }
    }

    // MARK: - resolvedHarnessName

    func testHarnessNamePrefersHarnessNameField() throws {
        let input = try JSONDecoder().decode(
            HookInput.self, from: loadFixture("SessionStart-opencode")
        )
        XCTAssertEqual(input.harnessName, "opencode")
        XCTAssertEqual(input.source, "opencode")
        XCTAssertEqual(input.resolvedHarnessName, "opencode")
    }

    func testHarnessNameFallsBackToSourceForLegacyPlugins() throws {
        let json = """
        {"session_id":"test","cwd":"/tmp","hook_event_name":"SessionStart","source":"opencode"}
        """
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        XCTAssertNil(input.harnessName)
        XCTAssertEqual(input.resolvedHarnessName, "opencode")
    }

    func testHarnessNameIgnoresCodexTriggerKind() throws {
        let input = try JSONDecoder().decode(
            HookInput.self, from: loadFixture("codex-SessionStart")
        )
        XCTAssertEqual(input.source, "startup")
        XCTAssertNil(input.resolvedHarnessName, "'startup' is not a harness name")
    }

    func testHarnessNameSetViaCLIArg() throws {
        // Codex path: shim passes --harness codex, HookMain sets input.harnessName
        // before calling handleHook. We simulate that by setting harnessName directly.
        var input = try JSONDecoder().decode(
            HookInput.self, from: loadFixture("codex-SessionStart")
        )
        XCTAssertNil(input.harnessName)
        input.harnessName = "codex"
        XCTAssertEqual(input.resolvedHarnessName, "codex")
    }

    func testHarnessNameRejectsUnknownSourceValue() throws {
        let json = """
        {"session_id":"test","cwd":"/tmp","hook_event_name":"SessionStart","source":"../../etc/passwd"}
        """
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        XCTAssertNil(input.resolvedHarnessName, "non-allowlisted source must be rejected")
    }
}
