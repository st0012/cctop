import XCTest
@testable import CctopMenubar

final class HookHandlerTests: XCTestCase {

    private var sessionsDir: String!

    override func setUp() {
        super.setUp()
        sessionsDir = NSTemporaryDirectory() + "cctop-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: sessionsDir, withIntermediateDirectories: true
        )
        setenv("CCTOP_SESSIONS_DIR", sessionsDir, 1)
    }

    override func tearDown() {
        unsetenv("CCTOP_SESSIONS_DIR")
        try? FileManager.default.removeItem(atPath: sessionsDir)
        HookLogger.cleanupSessionLog(sessionId: "test-session-001")
        super.tearDown()
    }

    private func loadFixture(_ name: String) throws -> Data {
        let projectDir = ProcessInfo.processInfo.environment["PROJECT_DIR"]
            ?? URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .path
        let path = (projectDir as NSString).appendingPathComponent("fixtures/\(name).json")
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private func handleFixture(_ name: String, hookName: String? = nil) throws {
        let data = try loadFixture(name)
        let input = try JSONDecoder().decode(HookInput.self, from: data)
        try HookHandler.handleHook(hookName: hookName ?? input.hookEventName, input: input)
    }

    private func loadSession() throws -> Session {
        try Session.fromFile(path: sessionFilePath())
    }

    private func sessionFilePath() throws -> String {
        let entries = try FileManager.default.contentsOfDirectory(atPath: sessionsDir)
        let jsonFiles = entries.filter { $0.hasSuffix(".json") }
        XCTAssertEqual(
            jsonFiles.count, 1,
            "Expected exactly 1 session file, found \(jsonFiles.count): \(jsonFiles)"
        )
        return (sessionsDir as NSString).appendingPathComponent(jsonFiles[0])
    }

    private func sessionFileExists() -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir)) ?? []
        return entries.contains { $0.hasSuffix(".json") }
    }

    // MARK: - Shared host app bundle IDs

    func testDesktopBundleIDsAreSharedWithHostApp() {
        XCTAssertEqual(HostApp.claudeDesktop.bundleID, HostAppBundleID.claudeDesktop)
        XCTAssertEqual(HostApp.codexDesktop.bundleID, HostAppBundleID.codexDesktop)
    }

    // MARK: - SessionStart creates idle session

    func testSessionStartCreatesIdleSession() throws {
        try handleFixture("SessionStart")
        let session = try loadSession()
        XCTAssertEqual(session.status, .idle)
        XCTAssertEqual(session.sessionId, "test-session-001")
        XCTAssertEqual(session.projectPath, "/tmp/test-project")
        XCTAssertEqual(session.projectName, "test-project")
        XCTAssertNotNil(session.pid)
        XCTAssertEqual(session.activeSubagents?.count, 0)
    }

    func testNewHookSessionFileRecordsWriterMetadata() throws {
        try handleFixture("SessionStart")
        let session = try loadSession()

        XCTAssertEqual(session.createdByHookVersion, Config.hookVersion)
        XCTAssertEqual(session.lastWrittenByHookVersion, Config.hookVersion)
    }

    func testCurrentHookUpdateDoesNotBackfillLegacyCreatedByVersion() throws {
        try handleFixture("SessionStart")

        let path = try sessionFilePath()
        var legacy = try Session.fromFile(path: path)
        legacy.createdByHookVersion = nil
        legacy.lastWrittenByHookVersion = nil
        try legacy.writeToFile(path: path)

        try handleFixture("UserPromptSubmit")
        let session = try loadSession()

        XCTAssertNil(session.createdByHookVersion)
        XCTAssertEqual(session.lastWrittenByHookVersion, Config.hookVersion)
    }

    func testSessionEndRefreshesLastWrittenByHookVersion() throws {
        try handleFixture("SessionStart")

        let path = try sessionFilePath()
        var session = try Session.fromFile(path: path)
        session.lastWrittenByHookVersion = "0.16.0-dev"
        try session.writeToFile(path: path)

        try handleFixture("SessionEnd")
        session = try loadSession()

        XCTAssertEqual(session.createdByHookVersion, Config.hookVersion)
        XCTAssertEqual(session.lastWrittenByHookVersion, Config.hookVersion)
    }

    // MARK: - UserPromptSubmit transitions to working

    func testUserPromptSubmitSetsWorking() throws {
        try handleFixture("SessionStart")
        try handleFixture("UserPromptSubmit")
        let session = try loadSession()
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.lastPrompt, "Fix the login bug")
    }

    // MARK: - PreToolUse sets tool info

    func testPreToolUseSetsToolInfo() throws {
        try handleFixture("SessionStart")
        try handleFixture("PreToolUse")
        let session = try loadSession()
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.lastTool, "Bash")
        XCTAssertEqual(session.lastToolDetail, "npm test")
    }

    // MARK: - PostToolUse stays working

    func testPostToolUseStaysWorking() throws {
        try handleFixture("SessionStart")
        try handleFixture("PreToolUse")
        try handleFixture("PostToolUse")
        let session = try loadSession()
        XCTAssertEqual(session.status, .working)
    }

    // MARK: - PostToolUseFailure stores error

    func testPostToolUseFailureStoresError() throws {
        try handleFixture("SessionStart")
        try handleFixture("PostToolUseFailure")
        let session = try loadSession()
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.notificationMessage, "Command exited with code 1")
    }

    // MARK: - Stop transitions to waiting_input

    func testStopSetsWaitingInput() throws {
        try handleFixture("SessionStart")
        try handleFixture("UserPromptSubmit")
        try handleFixture("Stop")
        let session = try loadSession()
        XCTAssertEqual(session.status, .waitingInput)
        XCTAssertNil(session.lastTool)
        XCTAssertNil(session.lastToolDetail)
    }

    // MARK: - PermissionRequest transitions to waiting_permission

    func testPermissionRequestSetsWaitingPermission() throws {
        try handleFixture("SessionStart")
        try handleFixture("PermissionRequest")
        let session = try loadSession()
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(session.notificationMessage, "Allow Bash: rm -rf /tmp/old")
    }

    // MARK: - Notification (idle) transitions to waiting_input

    func testNotificationIdleSetsWaitingInput() throws {
        try handleFixture("SessionStart")
        try handleFixture("UserPromptSubmit")
        try handleFixture("Notification-idle", hookName: "Notification")
        let session = try loadSession()
        XCTAssertEqual(session.status, .waitingInput)
    }

    func testOpencodeQuestionPermissionRequestSetsWaitingPermission() throws {
        try handleFixture("SessionStart-opencode")
        try handleFixture("UserPromptSubmit-opencode")
        try handleFixture("PermissionRequest-opencode-question")

        let session = try loadSession()
        XCTAssertEqual(session.status, .waitingPermission)
        XCTAssertEqual(session.source, "opencode")
        XCTAssertEqual(session.notificationMessage, "Which direction should I take?")
    }

    // MARK: - Notification (permission) preserves status

    func testNotificationPermissionPreservesStatus() throws {
        try handleFixture("SessionStart")
        try handleFixture("PermissionRequest")
        try handleFixture("Notification-permission", hookName: "Notification")
        let session = try loadSession()
        XCTAssertEqual(session.status, .waitingPermission)
        // notificationPermission is a no-op — must not clobber the earlier PermissionRequest message
        XCTAssertEqual(session.notificationMessage, "Allow Bash: rm -rf /tmp/old")
    }

    // MARK: - SubagentStart adds to active_subagents

    func testSubagentStartAddsAgent() throws {
        try handleFixture("SessionStart")
        try handleFixture("SubagentStart")
        let session = try loadSession()
        XCTAssertEqual(session.activeSubagents?.count, 1)
        XCTAssertEqual(session.activeSubagents?.first?.agentId, "agent-abc-123")
        XCTAssertEqual(session.activeSubagents?.first?.agentType, "general-purpose")
    }

    // MARK: - SubagentStop removes from active_subagents

    func testSubagentStopRemovesAgent() throws {
        try handleFixture("SessionStart")
        try handleFixture("SubagentStart")
        try handleFixture("SubagentStop")
        let session = try loadSession()
        XCTAssertEqual(session.activeSubagents?.count, 0)
    }

    // MARK: - PreCompact transitions to compacting

    func testPreCompactSetsCompacting() throws {
        try handleFixture("SessionStart")
        try handleFixture("PreCompact")
        let session = try loadSession()
        XCTAssertEqual(session.status, .compacting)
    }

    // MARK: - PostCompact transitions to idle

    func testPostCompactSetsIdle() throws {
        try handleFixture("SessionStart")
        try handleFixture("PreCompact")
        XCTAssertEqual(try loadSession().status, .compacting)
        try handleFixture("PostCompact")
        let session = try loadSession()
        XCTAssertEqual(session.status, .idle)
    }

    // MARK: - SessionError transitions to needs_attention

    func testSessionErrorSetsNeedsAttention() throws {
        try handleFixture("SessionStart")
        try handleFixture("SessionError")
        let session = try loadSession()
        XCTAssertEqual(session.status, .needsAttention)
        XCTAssertEqual(session.notificationMessage, "Context window exceeded")
    }

    // MARK: - SessionEnd stamps endedAt for archiving

    func testSessionEndStampsEndedAt() throws {
        try handleFixture("SessionStart")
        XCTAssertTrue(sessionFileExists())
        XCTAssertNil(try loadSession().endedAt)
        try handleFixture("SessionEnd")
        XCTAssertTrue(sessionFileExists(), "File should remain for menubar to archive")
        XCTAssertNotNil(try loadSession().endedAt)
    }

    func testDesktopSessionEndStampsDisconnectedAt() throws {
        setenv("__CFBundleIdentifier", HostAppBundleID.claudeDesktop, 1)
        defer { unsetenv("__CFBundleIdentifier") }

        try handleFixture("SessionStart")
        XCTAssertNil(try loadSession().disconnectedAt)

        try handleFixture("SessionEnd")

        let session = try loadSession()
        XCTAssertNotNil(session.endedAt)
        XCTAssertNotNil(session.disconnectedAt)
    }

    func testSessionStartClearsEndedAndDisconnectedAt() throws {
        setenv("__CFBundleIdentifier", HostAppBundleID.claudeDesktop, 1)
        defer { unsetenv("__CFBundleIdentifier") }

        try handleFixture("SessionStart")
        try handleFixture("SessionEnd")
        XCTAssertNotNil(try loadSession().endedAt)
        XCTAssertNotNil(try loadSession().disconnectedAt)

        try handleFixture("SessionStart")

        let session = try loadSession()
        XCTAssertNil(session.endedAt)
        XCTAssertNil(session.disconnectedAt)
    }

    func testNoOpHooksPreserveEndedAndDisconnectedAt() throws {
        setenv("__CFBundleIdentifier", HostAppBundleID.claudeDesktop, 1)
        defer { unsetenv("__CFBundleIdentifier") }

        try handleFixture("SessionStart")
        try handleFixture("SessionEnd")
        let endedAt = try XCTUnwrap(try loadSession().endedAt)
        let disconnectedAt = try XCTUnwrap(try loadSession().disconnectedAt)

        try handleFixture("Notification-permission", hookName: "Notification")
        XCTAssertEqual(try loadSession().endedAt, endedAt)
        XCTAssertEqual(try loadSession().disconnectedAt, disconnectedAt)

        try handleHook("""
        {"session_id":"test-session-001","cwd":"/tmp/test-project","hook_event_name":"Notification","notification_type":"future_type"}
        """, hookName: "Notification")
        XCTAssertEqual(try loadSession().endedAt, endedAt)
        XCTAssertEqual(try loadSession().disconnectedAt, disconnectedAt)

        try handleFixture("SessionStart", hookName: "FutureHook")
        XCTAssertEqual(try loadSession().endedAt, endedAt)
        XCTAssertEqual(try loadSession().disconnectedAt, disconnectedAt)
    }

    func testSubagentHooksPreserveEndedAndDisconnectedAt() throws {
        setenv("__CFBundleIdentifier", HostAppBundleID.claudeDesktop, 1)
        defer { unsetenv("__CFBundleIdentifier") }

        try handleFixture("SessionStart")
        try handleFixture("SessionEnd")
        let endedAt = try XCTUnwrap(try loadSession().endedAt)
        let disconnectedAt = try XCTUnwrap(try loadSession().disconnectedAt)

        try handleFixture("SubagentStart")
        var session = try loadSession()
        XCTAssertEqual(session.endedAt, endedAt)
        XCTAssertEqual(session.disconnectedAt, disconnectedAt)
        XCTAssertEqual(session.activeSubagents?.count, 1)

        try handleFixture("SubagentStop")
        session = try loadSession()
        XCTAssertEqual(session.endedAt, endedAt)
        XCTAssertEqual(session.disconnectedAt, disconnectedAt)
        XCTAssertEqual(session.activeSubagents?.count, 0)
    }

    // MARK: - Source passthrough (opencode)

    func testSourcePassthrough() throws {
        try handleFixture("SessionStart-opencode")
        let session = try loadSession()
        XCTAssertEqual(session.source, "opencode")
    }

    // MARK: - Session name from input

    func testSessionNameFromInput() throws {
        try handleFixture("SessionStart-opencode")
        let session = try loadSession()
        XCTAssertEqual(session.sessionName, "Fix login bug")
    }

    // MARK: - Source passthrough (pi)

    func testSourcePassthroughPi() throws {
        try handleFixture("SessionStart-pi")
        let session = try loadSession()
        XCTAssertEqual(session.source, "pi")
        XCTAssertEqual(session.sessionName, "Refactor auth module")
    }

    // MARK: - Session name preservation across events

    /// Regression: previously, UserPromptSubmit re-looked up the session name from
    /// the transcript and overwrote `sessionName` with nil when no `custom-title`
    /// entry was present. Subsequent prompts kept clobbering it. The fix: only
    /// overwrite sessionName when the lookup actually returns a value.
    func testUserPromptSubmit_doesNotClobberSessionName_whenLookupFails() throws {
        try handleFixture("SessionStart-opencode")  // sets sessionName = "Fix login bug"
        XCTAssertEqual(try loadSession().sessionName, "Fix login bug")

        // Same session_id, UserPromptSubmit with no `session_name` field and no
        // transcript_path. Lookup will return nil. sessionName should be preserved.
        try handleFixture("UserPromptSubmit-opencode")
        XCTAssertEqual(try loadSession().sessionName, "Fix login bug",
                       "sessionName should be preserved when lookup returns nil within the same session")
    }

    /// Regression: same OS process, new session_id (Codex Desktop's "new chat"
    /// flow) used to carry over all conversation state — name, project, prompt,
    /// tool detail — from the previous conversation, surfacing the old chat's
    /// title under the new one. The fix drops conversation-specific state and
    /// keeps only PID liveness metadata.
    func testSessionIdChange_inSamePID_resetsConversationState() throws {
        try handleFixture("SessionStart-opencode")
        let first = try loadSession()
        XCTAssertEqual(first.sessionId, "opencode-12345")
        XCTAssertEqual(first.sessionName, "Fix login bug")
        XCTAssertEqual(first.projectName, "test-project")

        // Same PID (test runner), different session_id. Simulates Codex Desktop
        // spawning a new conversation inside the same OS process.
        try handleFixture("SessionStart")
        let second = try loadSession()
        XCTAssertEqual(second.sessionId, "test-session-001",
                       "session_id should update to the new conversation's id")
        XCTAssertNil(second.sessionName,
                     "sessionName should be reset — not carried over from the previous conversation")
        XCTAssertEqual(second.pid, first.pid,
                       "PID liveness metadata should carry over")
        XCTAssertEqual(second.pidStartTime, first.pidStartTime,
                       "pidStartTime should carry over for the process-alive check")
    }

    // MARK: - Full lifecycle sequence

    func testFullLifecycle() throws {
        try handleFixture("SessionStart")
        XCTAssertEqual(try loadSession().status, .idle)

        try handleFixture("UserPromptSubmit")
        XCTAssertEqual(try loadSession().status, .working)

        try handleFixture("PreToolUse")
        XCTAssertEqual(try loadSession().lastTool, "Bash")

        try handleFixture("PostToolUse")
        XCTAssertEqual(try loadSession().status, .working)

        try handleFixture("Stop")
        XCTAssertEqual(try loadSession().status, .waitingInput)

        try handleFixture("SessionEnd")
        XCTAssertTrue(sessionFileExists())
        XCTAssertNotNil(try loadSession().endedAt)
    }

    // MARK: - Claude Desktop session naming (claude-code-sessions lookup)

    func testClaudeDesktop_namesSessionFromClaudeCodeSessions() throws {
        let ccsDir = NSTemporaryDirectory() + "cctop-ccs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: ccsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: ccsDir) }

        let content = """
        {"cliSessionId":"test-session-001","title":"Investigate RBS RDoc plugin","lastActivityAt":1779281104333}
        """
        try content.write(toFile: ccsDir + "/local_x.json", atomically: true, encoding: .utf8)

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", ccsDir, 1)
        setenv("__CFBundleIdentifier", HostAppBundleID.claudeDesktop, 1)
        defer { unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR"); unsetenv("__CFBundleIdentifier") }

        try handleFixture("SessionStart")  // session_id test-session-001, no session_name
        XCTAssertEqual(try loadSession().sessionName, "Investigate RBS RDoc plugin")
    }

    /// A just-started Desktop session has no title yet at SessionStart; Claude Desktop
    /// auto-titles after the first turn. The lookup must re-run on Stop so the name
    /// appears without waiting for the next prompt.
    func testClaudeDesktop_refreshesNameOnStop() throws {
        let ccsDir = NSTemporaryDirectory() + "cctop-ccs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: ccsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: ccsDir) }

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", ccsDir, 1)
        setenv("__CFBundleIdentifier", HostAppBundleID.claudeDesktop, 1)
        defer { unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR"); unsetenv("__CFBundleIdentifier") }

        // No title file yet → name stays nil at SessionStart.
        try handleFixture("SessionStart")
        XCTAssertNil(try loadSession().sessionName)

        // Claude Desktop writes the auto title after the first turn.
        let content = """
        {"cliSessionId":"test-session-001","title":"Auto title","lastActivityAt":1}
        """
        try content.write(toFile: ccsDir + "/local_x.json", atomically: true, encoding: .utf8)

        // Stop re-runs the lookup and picks it up.
        try handleFixture("Stop")
        XCTAssertEqual(try loadSession().sessionName, "Auto title")
    }

    /// Codex never fires Stop and titles its thread mid-turn, so the name lookup must
    /// re-run on non-prompt events (e.g. PreToolUse) while sessionName is still nil —
    /// otherwise the name wouldn't appear until the user's next prompt.
    func testCodex_fillsNameOnToolEventWhileNil() throws {
        let idx = NSTemporaryDirectory() + "cctop-codex-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: idx) }
        setenv("CCTOP_CODEX_SESSION_INDEX", idx, 1)
        defer { unsetenv("CCTOP_CODEX_SESSION_INDEX") }

        func handle(_ json: String, _ hook: String) throws {
            let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
            try HookHandler.handleHook(hookName: hook, input: input)
        }

        // SessionStart before Codex has titled the thread → name stays nil.
        let startJSON = """
        {"session_id":"codex-1","cwd":"/tmp/p","hook_event_name":"SessionStart","harness_name":"codex"}
        """
        try handle(startJSON, "SessionStart")
        XCTAssertNil(try loadSession().sessionName)

        // Codex writes the thread name to its index mid-turn.
        try """
        {"id":"codex-1","thread_name":"Investigate session name capture"}
        """.write(toFile: idx, atomically: true, encoding: .utf8)

        // A tool event (not a prompt boundary) picks it up because the name is still nil.
        let toolJSON = """
        {"session_id":"codex-1","cwd":"/tmp/p","hook_event_name":"PreToolUse","harness_name":"codex","tool_name":"Bash"}
        """
        try handle(toolJSON, "PreToolUse")
        XCTAssertEqual(try loadSession().sessionName, "Investigate session name capture")
    }

    func testCodexDesktopTitleGenerationPromptWritesHiddenSession() throws {
        setenv("__CFBundleIdentifier", HostAppBundleID.codexDesktop, 1)
        defer { unsetenv("__CFBundleIdentifier") }

        func handle(_ json: String, _ hook: String) throws {
            let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
            try HookHandler.handleHook(hookName: hook, input: input)
        }

        let startJSON = """
        {"session_id":"title-helper","cwd":"/tmp/cctop","hook_event_name":"SessionStart","harness_name":"codex"}
        """
        try handle(startJSON, "SessionStart")
        XCTAssertFalse(try loadSession().hidden)

        let titlePrompt = """
        You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.
        The tasks typically have to do with coding-related tasks, for example requests for bug fixes or questions about a codebase. The title you generate will be shown in the UI to represent the prompt.
        Generate a concise UI title (up to 36 characters) for this task.
        Fill the structured title field with plain text.

        User prompt:
        You are the navigator for a cctop implementation task.
        """
        let promptJSON = """
        {"session_id":"title-helper","cwd":"/tmp/cctop","hook_event_name":"UserPromptSubmit","harness_name":"codex","prompt":\(try jsonString(titlePrompt))}
        """
        try handle(promptJSON, "UserPromptSubmit")
        XCTAssertTrue(try loadSession().hidden)
    }

    func testHookInputMarkedSubagentWritesHiddenSession() throws {
        let json = """
        {
          "session_id": "delegated-agent-session",
          "cwd": "/tmp/p",
          "hook_event_name": "SessionStart",
          "harness_name": "opencode",
          "is_subagent": true
        }
        """
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        try HookHandler.handleHook(hookName: "SessionStart", input: input)

        XCTAssertTrue(try loadSession().hidden)
    }

    func testProjectCleanupPreservesHookMarkedSubagentSession() throws {
        let project = "/tmp/cctop-subagent-cleanup-\(UUID().uuidString)"
        let json = """
        {
          "session_id": "delegated-agent-session",
          "cwd": "\(project)",
          "hook_event_name": "SessionStart",
          "harness_name": "opencode",
          "is_subagent": true
        }
        """
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        try HookHandler.handleHook(hookName: "SessionStart", input: input)

        let path = try sessionFilePath()
        var session = try Session.fromFile(path: path)
        session.pid = 999_999
        try session.writeToFile(path: path)

        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir,
            projectPath: project,
            currentPid: UInt32(getpid())
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    /// Codex Desktop fires every conversation's hooks from one shared host process, so
    /// PID keying collapses them into a single file. Keyed by session_id, two concurrent
    /// Codex conversations (same host PID — here the test runner's PID) get two files.
    func testCodex_keepsSeparateFilePerSessionId() throws {
        func handle(_ json: String, _ hook: String) throws {
            let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
            try HookHandler.handleHook(hookName: hook, input: input)
        }
        let convoA = """
        {"session_id":"019e0000-aaaa-7000-8000-000000000001","cwd":"/tmp/p","hook_event_name":"SessionStart","harness_name":"codex"}
        """
        let convoB = """
        {"session_id":"019e0000-bbbb-7000-8000-000000000002","cwd":"/tmp/p","hook_event_name":"SessionStart","harness_name":"codex"}
        """
        try handle(convoA, "SessionStart")
        try handle(convoB, "SessionStart")

        let files = try FileManager.default.contentsOfDirectory(atPath: sessionsDir)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(files, [
            "codex-019e0000-aaaa-7000-8000-000000000001.json",
            "codex-019e0000-bbbb-7000-8000-000000000002.json"
        ])
    }

    private func jsonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func handleHook(_ json: String, hookName: String) throws {
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        try HookHandler.handleHook(hookName: hookName, input: input)
    }
}
