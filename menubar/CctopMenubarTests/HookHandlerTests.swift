import XCTest
@testable import CctopMenubar

final class HookHandlerTests: XCTestCase {

    private var sessionsDir: String!
    private var logsDir: String!

    override func setUp() {
        super.setUp()
        sessionsDir = NSTemporaryDirectory() + "cctop-test-\(UUID().uuidString)"
        logsDir = NSTemporaryDirectory() + "cctop-test-logs-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(
            atPath: sessionsDir, withIntermediateDirectories: true
        )
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: sessionsDir)
        try? FileManager.default.removeItem(atPath: logsDir)
        super.tearDown()
    }

    // MARK: - Injected dependencies

    /// Scripted process prober: a fixed parent PID (4242 by default, so session
    /// files land at a deterministic "4242.json"), a scripted start time, and a
    /// scripted liveness answer — no getppid/sysctl/kill against the test runner.
    private struct FakeProcessProber: ProcessProbing {
        var pid: UInt32 = 4242
        var start: TimeInterval? = 1000
        var alive: Bool = true
        var comm: String?
        var tty: String?

        func parentPID() -> UInt32 { pid }
        func startTime(pid: UInt32) -> TimeInterval? { start }
        func isAlive(pid: UInt32) -> Bool { alive }
        func commandName(pid: UInt32) -> String? { comm }
        func controllingTTY() -> String? { tty }
    }

    /// Name resolver that answers from fixed values (all nil by default), so tests
    /// never scan the real transcript/index/session-store locations.
    private struct StubNameResolver: SessionNameResolving {
        var codexName: String?
        var desktopTitle: String?
        var transcriptName: String?

        func codexThreadName(sessionId: String) -> String? { codexName }
        func claudeDesktopTitle(cliSessionId: String) -> String? { desktopTitle }
        func transcriptSessionName(transcriptPath: String?, sessionId: String) -> String? { transcriptName }
    }

    private func makeDeps(
        pid: UInt32 = 4242,
        startTime: TimeInterval? = 1000,
        env: [String: String] = [:],
        branch: String = "main",
        names: any SessionNameResolving = StubNameResolver()
    ) -> HookDependencies {
        HookDependencies(
            sessionsDir: { self.sessionsDir },
            environment: { env },
            currentBranch: { _ in branch },
            process: FakeProcessProber(pid: pid, start: startTime),
            names: names,
            logger: HookLogger(logsDir: logsDir)
        )
    }

    // MARK: - Helpers

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

    private func handleFixture(_ name: String, hookName: String? = nil, deps: HookDependencies? = nil) throws {
        let data = try loadFixture(name)
        let input = try JSONDecoder().decode(HookInput.self, from: data)
        try HookHandler.handleHook(hookName: hookName ?? input.hookEventName, input: input, deps: deps ?? makeDeps())
    }

    private func handleHook(_ json: String, hookName: String, deps: HookDependencies? = nil) throws {
        let input = try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        try HookHandler.handleHook(hookName: hookName, input: input, deps: deps ?? makeDeps())
    }

    /// PID-keyed sessions land at "4242.json" (FakeProcessProber's fixed parent PID);
    /// Codex sessions are keyed by session id instead.
    private func sessionFilePath(_ fileName: String = "4242.json") -> String {
        (sessionsDir as NSString).appendingPathComponent(fileName)
    }

    private func loadSession(_ fileName: String = "4242.json") throws -> Session {
        try Session.fromFile(path: sessionFilePath(fileName))
    }

    private func sessionFileExists(_ fileName: String = "4242.json") -> Bool {
        FileManager.default.fileExists(atPath: sessionFilePath(fileName))
    }

    private func jsonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
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
        XCTAssertEqual(session.pid, 4242)
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

        let path = sessionFilePath()
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

        let path = sessionFilePath()
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
        let deps = makeDeps(env: ["__CFBundleIdentifier": HostAppBundleID.claudeDesktop])

        try handleFixture("SessionStart", deps: deps)
        XCTAssertNil(try loadSession().disconnectedAt)

        try handleFixture("SessionEnd", deps: deps)

        let session = try loadSession()
        XCTAssertNotNil(session.endedAt)
        XCTAssertNotNil(session.disconnectedAt)
    }

    func testOpencodeSessionEndIgnoresLeakedCodexDesktopBundle() throws {
        let deps = makeDeps(env: ["__CFBundleIdentifier": HostAppBundleID.codexDesktop])

        try handleFixture("SessionStart-opencode", deps: deps)
        XCTAssertEqual(try loadSession().source, "opencode")
        XCTAssertNil(try loadSession().disconnectedAt)

        try handleHook("""
        {"session_id":"opencode-12345","cwd":"/tmp/test-project","hook_event_name":"SessionEnd","harness_name":"opencode"}
        """, hookName: "SessionEnd", deps: deps)

        let session = try loadSession()
        XCTAssertNotNil(session.endedAt)
        XCTAssertNil(session.disconnectedAt)
    }

    // A `cc` session launched from a Codex Desktop environment inherits that bundle id,
    // but is never actually hosted by Codex Desktop — SessionEnd must not give it the
    // desktop disconnectedAt treatment (issue #155).
    func testCcSessionEndWithLeakedCodexDesktopBundleSkipsDisconnectedAt() throws {
        let deps = makeDeps(env: ["__CFBundleIdentifier": HostAppBundleID.codexDesktop])

        try handleHook("""
        {"session_id":"cc-under-codex","cwd":"/tmp/test-project","hook_event_name":"SessionStart","harness_name":"cc"}
        """, hookName: "SessionStart", deps: deps)
        XCTAssertNil(try loadSession().disconnectedAt)

        try handleHook("""
        {"session_id":"cc-under-codex","cwd":"/tmp/test-project","hook_event_name":"SessionEnd","harness_name":"cc"}
        """, hookName: "SessionEnd", deps: deps)

        let session = try loadSession()
        XCTAssertNotNil(session.endedAt)
        XCTAssertNil(session.disconnectedAt)
    }

    // The end-time parent walk can resolve a different PID than at start (ancestors exit
    // during teardown), missing the PID-derived path. SessionEnd must find the session's
    // file by session_id instead of silently stamping nothing (issue #155 P3).
    func testSessionEndStampsFileFoundBySessionIdWhenPidPathMisses() throws {
        // 7777.json — NOT the fake prober's parent PID (4242), so the primary path misses.
        let session = Session.mock(id: "end-by-sid", pid: 7777)
        let path = (sessionsDir as NSString).appendingPathComponent("7777.json")
        try session.writeToFile(path: path)

        try handleHook("""
        {"session_id":"end-by-sid","cwd":"/tmp/test-project","hook_event_name":"SessionEnd","harness_name":"cc"}
        """, hookName: "SessionEnd")

        XCTAssertNotNil(try Session.fromFile(path: path).endedAt)
    }

    // The PID-derived path can hold a DIFFERENT conversation. SessionEnd must never
    // stamp a foreign session file.
    func testSessionEndLeavesOtherSessionAtPidPathUntouched() throws {
        try handleFixture("SessionStart")
        XCTAssertEqual(try loadSession().sessionId, "test-session-001")

        try handleHook("""
        {"session_id":"some-other-conversation","cwd":"/tmp/test-project","hook_event_name":"SessionEnd","harness_name":"cc"}
        """, hookName: "SessionEnd")

        XCTAssertNil(try loadSession().endedAt)
    }

    // Legacy cleanup preserved: a corrupt file at the PID-derived path is still removed.
    func testSessionEndRemovesCorruptPrimaryFile() throws {
        try handleFixture("SessionStart")
        let path = sessionFilePath()
        try Data("not json".utf8).write(to: URL(fileURLWithPath: path))

        try handleFixture("SessionEnd")

        XCTAssertFalse(sessionFileExists())
    }

    // When two files share a session_id, the PID-derived path is authoritative.
    func testSessionEndPrefersPidPathWhenTwoFilesShareSessionId() throws {
        try handleFixture("SessionStart")
        let primary = sessionFilePath()
        let twinPath = (sessionsDir as NSString).appendingPathComponent("7777.json")
        try Session.mock(id: "test-session-001", pid: 7777).writeToFile(path: twinPath)

        try handleFixture("SessionEnd")

        XCTAssertNotNil(try Session.fromFile(path: primary).endedAt)
        XCTAssertNil(try Session.fromFile(path: twinPath).endedAt)
    }

    // When the PID-derived path misses, the by-session_id scan must pick the live
    // (un-ended) duplicate, not a stale already-ended one.
    func testSessionEndStampsUnendedDuplicateWhenPrimaryMisses() throws {
        var stale = Session.mock(id: "dup-sid", pid: 1111)
        let staleEnd = Date(timeIntervalSince1970: 1_000)
        stale.endedAt = staleEnd
        let stalePath = (sessionsDir as NSString).appendingPathComponent("1111.json")
        try stale.writeToFile(path: stalePath)

        let livePath = (sessionsDir as NSString).appendingPathComponent("2222.json")
        try Session.mock(id: "dup-sid", pid: 2222).writeToFile(path: livePath)

        try handleHook("""
        {"session_id":"dup-sid","cwd":"/tmp/test-project","hook_event_name":"SessionEnd","harness_name":"cc"}
        """, hookName: "SessionEnd")

        XCTAssertNotNil(try Session.fromFile(path: livePath).endedAt)
        XCTAssertEqual(try Session.fromFile(path: stalePath).endedAt, staleEnd)
    }

    func testSessionStartClearsEndedAndDisconnectedAt() throws {
        let deps = makeDeps(env: ["__CFBundleIdentifier": HostAppBundleID.claudeDesktop])

        try handleFixture("SessionStart", deps: deps)
        try handleFixture("SessionEnd", deps: deps)
        XCTAssertNotNil(try loadSession().endedAt)
        XCTAssertNotNil(try loadSession().disconnectedAt)

        try handleFixture("SessionStart", deps: deps)

        let session = try loadSession()
        XCTAssertNil(session.endedAt)
        XCTAssertNil(session.disconnectedAt)
    }

    func testNoOpHooksPreserveEndedAndDisconnectedAt() throws {
        let deps = makeDeps(env: ["__CFBundleIdentifier": HostAppBundleID.claudeDesktop])

        try handleFixture("SessionStart", deps: deps)
        try handleFixture("SessionEnd", deps: deps)
        let endedAt = try XCTUnwrap(try loadSession().endedAt)
        let disconnectedAt = try XCTUnwrap(try loadSession().disconnectedAt)

        try handleFixture("Notification-permission", hookName: "Notification", deps: deps)
        XCTAssertEqual(try loadSession().endedAt, endedAt)
        XCTAssertEqual(try loadSession().disconnectedAt, disconnectedAt)

        try handleHook("""
        {"session_id":"test-session-001","cwd":"/tmp/test-project","hook_event_name":"Notification","notification_type":"future_type"}
        """, hookName: "Notification", deps: deps)
        XCTAssertEqual(try loadSession().endedAt, endedAt)
        XCTAssertEqual(try loadSession().disconnectedAt, disconnectedAt)

        try handleFixture("SessionStart", hookName: "FutureHook", deps: deps)
        XCTAssertEqual(try loadSession().endedAt, endedAt)
        XCTAssertEqual(try loadSession().disconnectedAt, disconnectedAt)
    }

    func testSubagentHooksPreserveEndedAndDisconnectedAt() throws {
        let deps = makeDeps(env: ["__CFBundleIdentifier": HostAppBundleID.claudeDesktop])

        try handleFixture("SessionStart", deps: deps)
        try handleFixture("SessionEnd", deps: deps)
        let endedAt = try XCTUnwrap(try loadSession().endedAt)
        let disconnectedAt = try XCTUnwrap(try loadSession().disconnectedAt)

        try handleFixture("SubagentStart", deps: deps)
        var session = try loadSession()
        XCTAssertEqual(session.endedAt, endedAt)
        XCTAssertEqual(session.disconnectedAt, disconnectedAt)
        XCTAssertEqual(session.activeSubagents?.count, 1)

        try handleFixture("SubagentStop", deps: deps)
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

        // Same session_id, UserPromptSubmit with no `session_name` field and a
        // name resolver that returns nil. sessionName should be preserved.
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

        // Same PID (FakeProcessProber's 4242), different session_id. Simulates Codex
        // Desktop spawning a new conversation inside the same OS process.
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

    // MARK: - PID reuse detection

    /// Same PID, same process start time: the same process is still running, so a
    /// repeated SessionStart must keep the existing session state.
    func testSessionStart_samePIDSameStartTime_keepsSessionState() throws {
        try handleFixture("SessionStart-opencode")
        try handleFixture("UserPromptSubmit-opencode")
        XCTAssertEqual(try loadSession().lastPrompt, "Help me debug this")

        try handleFixture("SessionStart-opencode")
        XCTAssertEqual(try loadSession().lastPrompt, "Help me debug this")
    }

    /// Same PID but a different process start time: the OS reused the PID for a new
    /// process, so SessionStart must start fresh instead of inheriting the previous
    /// process's conversation state.
    func testSessionStart_samePIDDifferentStartTime_dropsPreviousSessionState() throws {
        try handleFixture("SessionStart-opencode", deps: makeDeps(startTime: 1000))
        try handleFixture("UserPromptSubmit-opencode", deps: makeDeps(startTime: 1000))
        XCTAssertEqual(try loadSession().lastPrompt, "Help me debug this")

        try handleFixture("SessionStart-opencode", deps: makeDeps(startTime: 2000))

        let session = try loadSession()
        XCTAssertNil(session.lastPrompt, "conversation state must not leak across PID reuse")
        XCTAssertEqual(session.pidStartTime, 2000)
    }

    // MARK: - Git branch capture

    func testBranchFromDepsLandsInSession() throws {
        try handleFixture("SessionStart", deps: makeDeps(branch: "feature-x"))
        XCTAssertEqual(try loadSession().branch, "feature-x")
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

        let deps = makeDeps(
            env: ["__CFBundleIdentifier": HostAppBundleID.claudeDesktop],
            names: LiveSessionNameResolver(claudeSessionsDir: ccsDir)
        )

        try handleFixture("SessionStart", deps: deps)  // session_id test-session-001, no session_name
        XCTAssertEqual(try loadSession().sessionName, "Investigate RBS RDoc plugin")
    }

    /// A just-started Desktop session has no title yet at SessionStart; Claude Desktop
    /// auto-titles after the first turn. The lookup must re-run on Stop so the name
    /// appears without waiting for the next prompt.
    func testClaudeDesktop_refreshesNameOnStop() throws {
        let ccsDir = NSTemporaryDirectory() + "cctop-ccs-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: ccsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: ccsDir) }

        let deps = makeDeps(
            env: ["__CFBundleIdentifier": HostAppBundleID.claudeDesktop],
            names: LiveSessionNameResolver(claudeSessionsDir: ccsDir)
        )

        // No title file yet → name stays nil at SessionStart.
        try handleFixture("SessionStart", deps: deps)
        XCTAssertNil(try loadSession().sessionName)

        // Claude Desktop writes the auto title after the first turn.
        let content = """
        {"cliSessionId":"test-session-001","title":"Auto title","lastActivityAt":1}
        """
        try content.write(toFile: ccsDir + "/local_x.json", atomically: true, encoding: .utf8)

        // Stop re-runs the lookup and picks it up.
        try handleFixture("Stop", deps: deps)
        XCTAssertEqual(try loadSession().sessionName, "Auto title")
    }

    /// Codex never fires Stop and titles its thread mid-turn, so the name lookup must
    /// re-run on non-prompt events (e.g. PreToolUse) while sessionName is still nil —
    /// otherwise the name wouldn't appear until the user's next prompt.
    func testCodex_fillsNameOnToolEventWhileNil() throws {
        let idx = NSTemporaryDirectory() + "cctop-codex-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: idx) }
        let deps = makeDeps(names: LiveSessionNameResolver(codexIndexPath: idx))

        // SessionStart before Codex has titled the thread → name stays nil.
        let startJSON = """
        {"session_id":"codex-1","cwd":"/tmp/p","hook_event_name":"SessionStart","harness_name":"codex"}
        """
        try handleHook(startJSON, hookName: "SessionStart", deps: deps)
        XCTAssertNil(try loadSession("codex-codex-1.json").sessionName)

        // Codex writes the thread name to its index mid-turn.
        try """
        {"id":"codex-1","thread_name":"Investigate session name capture"}
        """.write(toFile: idx, atomically: true, encoding: .utf8)

        // A tool event (not a prompt boundary) picks it up because the name is still nil.
        let toolJSON = """
        {"session_id":"codex-1","cwd":"/tmp/p","hook_event_name":"PreToolUse","harness_name":"codex","tool_name":"Bash"}
        """
        try handleHook(toolJSON, hookName: "PreToolUse", deps: deps)
        XCTAssertEqual(try loadSession("codex-codex-1.json").sessionName, "Investigate session name capture")
    }

    func testCodexDesktopTitleGenerationPromptWritesHiddenSession() throws {
        let deps = makeDeps(env: ["__CFBundleIdentifier": HostAppBundleID.codexDesktop])

        let startJSON = """
        {"session_id":"title-helper","cwd":"/tmp/cctop","hook_event_name":"SessionStart","harness_name":"codex"}
        """
        try handleHook(startJSON, hookName: "SessionStart", deps: deps)
        XCTAssertFalse(try loadSession("codex-title-helper.json").hidden)

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
        try handleHook(promptJSON, hookName: "UserPromptSubmit", deps: deps)
        XCTAssertTrue(try loadSession("codex-title-helper.json").hidden)
    }

    func testHookInputMarkedSubagentWritesHiddenSession() throws {
        try handleHook("""
        {
          "session_id": "delegated-agent-session",
          "cwd": "/tmp/p",
          "hook_event_name": "SessionStart",
          "harness_name": "opencode",
          "is_subagent": true
        }
        """, hookName: "SessionStart")

        XCTAssertTrue(try loadSession().hidden)
    }

    // MARK: - Project cleanup (stale-PID GC)

    func testProjectCleanupPreservesHookMarkedSubagentSession() throws {
        let project = "/tmp/cctop-subagent-cleanup-\(UUID().uuidString)"
        try handleHook("""
        {
          "session_id": "delegated-agent-session",
          "cwd": "\(project)",
          "hook_event_name": "SessionStart",
          "harness_name": "opencode",
          "is_subagent": true
        }
        """, hookName: "SessionStart")

        // Even with the owning PID dead, hidden subagent sessions must be preserved.
        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir, projectPath: project, currentPid: 1,
            process: FakeProcessProber(alive: false), logger: HookLogger(logsDir: logsDir)
        )

        XCTAssertTrue(sessionFileExists())
    }

    func testProjectCleanupRemovesStaleOpencodeWithLeakedCodexDesktopBundle() throws {
        let project = "/tmp/cctop-opencode-cleanup-\(UUID().uuidString)"
        let deps = makeDeps(env: ["__CFBundleIdentifier": HostAppBundleID.codexDesktop])

        try handleHook("""
        {
          "session_id": "opencode-stale",
          "cwd": "\(project)",
          "hook_event_name": "SessionStart",
          "harness_name": "opencode"
        }
        """, hookName: "SessionStart", deps: deps)

        // The leaked desktop bundle id must not shield an explicit opencode session
        // from PID-staleness GC.
        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir, projectPath: project, currentPid: 1,
            process: FakeProcessProber(alive: false), logger: HookLogger(logsDir: logsDir)
        )

        XCTAssertFalse(sessionFileExists())
    }

    func testProjectCleanupRemovesSessionWhosePIDIsDead() throws {
        let project = "/tmp/cctop-stale-cleanup-\(UUID().uuidString)"
        try handleHook("""
        {"session_id":"stale-cc","cwd":"\(project)","hook_event_name":"SessionStart"}
        """, hookName: "SessionStart")
        XCTAssertTrue(sessionFileExists())

        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir, projectPath: project, currentPid: 1,
            process: FakeProcessProber(alive: false), logger: HookLogger(logsDir: logsDir)
        )

        XCTAssertFalse(sessionFileExists())
    }

    func testProjectCleanupKeepsSessionWhosePIDIsAlive() throws {
        let project = "/tmp/cctop-alive-cleanup-\(UUID().uuidString)"
        try handleHook("""
        {"session_id":"alive-cc","cwd":"\(project)","hook_event_name":"SessionStart"}
        """, hookName: "SessionStart")

        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir, projectPath: project, currentPid: 1,
            process: FakeProcessProber(start: 1000, alive: true), logger: HookLogger(logsDir: logsDir)
        )

        XCTAssertTrue(sessionFileExists())
    }

    func testProjectCleanupRemovesSessionWhosePIDWasReused() throws {
        let project = "/tmp/cctop-reuse-cleanup-\(UUID().uuidString)"
        try handleHook("""
        {"session_id":"reused-cc","cwd":"\(project)","hook_event_name":"SessionStart"}
        """, hookName: "SessionStart")  // stored pidStartTime = 1000

        // PID is alive but now belongs to a different process (start time moved).
        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir, projectPath: project, currentPid: 1,
            process: FakeProcessProber(start: 2000, alive: true), logger: HookLogger(logsDir: logsDir)
        )

        XCTAssertFalse(sessionFileExists())
    }

    // A `cc` file with a leaked Codex Desktop bundle id is NOT a desktop conversation;
    // once its PID is gone it is stale and must be reaped like any terminal session
    // (issue #155 — these files previously survived forever as "desktop" cards).
    func testProjectCleanupRemovesStaleCcWithLeakedCodexDesktopBundle() throws {
        let project = "/tmp/cctop-cc-cleanup-\(UUID().uuidString)"
        let deps = makeDeps(env: ["__CFBundleIdentifier": HostAppBundleID.codexDesktop])

        try handleHook("""
        {
          "session_id": "cc-stale",
          "cwd": "\(project)",
          "hook_event_name": "SessionStart",
          "harness_name": "cc"
        }
        """, hookName: "SessionStart", deps: deps)
        XCTAssertTrue(sessionFileExists())

        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir, projectPath: project, currentPid: 1,
            process: FakeProcessProber(alive: false), logger: HookLogger(logsDir: logsDir)
        )

        XCTAssertFalse(sessionFileExists())
    }

    // A live PID owned by a DIFFERENT harness's binary is not this session's process —
    // start-time coincidence must not keep the file alive (issue #155 P2).
    func testProjectCleanupRemovesSessionWhosePidRunsForeignHarness() throws {
        let project = "/tmp/cctop-foreign-pid-\(UUID().uuidString)"
        try handleHook("""
        {
          "session_id": "cc-foreign-pid",
          "cwd": "\(project)",
          "hook_event_name": "SessionStart",
          "harness_name": "cc"
        }
        """, hookName: "SessionStart")  // stored pidStartTime = 1000

        // PID alive, start time matches — but the process is the codex binary.
        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir, projectPath: project, currentPid: 1,
            process: FakeProcessProber(start: 1000, alive: true, comm: "codex"),
            logger: HookLogger(logsDir: logsDir)
        )

        XCTAssertFalse(sessionFileExists())
    }

    // The same comm answer must NOT reap the harness's own session.
    func testProjectCleanupKeepsSessionWhosePidRunsOwnHarness() throws {
        let project = "/tmp/cctop-own-pid-\(UUID().uuidString)"
        try handleHook("""
        {
          "session_id": "019e0000-cccc-7000-8000-000000000003",
          "cwd": "\(project)",
          "hook_event_name": "SessionStart",
          "harness_name": "codex"
        }
        """, hookName: "SessionStart")

        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir, projectPath: project, currentPid: 1,
            process: FakeProcessProber(start: 1000, alive: true, comm: "codex"),
            logger: HookLogger(logsDir: logsDir)
        )

        XCTAssertTrue(sessionFileExists("codex-019e0000-cccc-7000-8000-000000000003.json"))
    }

    // Reaping a stale duplicate must not delete the per-session log that a surviving
    // file with the same session_id still owns (dual-write case from issue #155).
    func testProjectCleanupKeepsSessionLogWhenAnotherFileSharesSessionId() throws {
        let project = "/tmp/cctop-shared-log-\(UUID().uuidString)"
        let sid = "shared-log-sid"
        let logger = HookLogger(logsDir: logsDir)

        var stale = Session(sessionId: sid, projectPath: project, branch: "main", terminal: TerminalInfo())
        stale.pid = 999_999
        let stalePath = (sessionsDir as NSString).appendingPathComponent("999999.json")
        try stale.writeToFile(path: stalePath)

        // Same conversation dual-written under the codex key; its PID is the currentPid,
        // so cleanup skips it and it remains the log's owner.
        var survivor = Session(sessionId: sid, projectPath: project, branch: "main", terminal: TerminalInfo())
        survivor.pid = 4242
        let survivorPath = (sessionsDir as NSString).appendingPathComponent("codex-\(sid).json")
        try survivor.writeToFile(path: survivorPath)

        logger.appendHookLog(sessionId: sid, event: "Test", label: "t", transition: "noop")
        let logPath = (logsDir as NSString).appendingPathComponent("\(sid).log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath))

        HookHandler.cleanupSessionsForProject(
            sessionsDir: sessionsDir, projectPath: project, currentPid: 4242,
            process: FakeProcessProber(alive: false), logger: logger
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: survivorPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath), "Shared session log must survive")
    }

    /// Codex Desktop fires every conversation's hooks from one shared host process, so
    /// PID keying collapses them into a single file. Keyed by session_id, two concurrent
    /// Codex conversations (same host PID) get two files.
    func testCodex_keepsSeparateFilePerSessionId() throws {
        let convoA = """
        {"session_id":"019e0000-aaaa-7000-8000-000000000001","cwd":"/tmp/p","hook_event_name":"SessionStart","harness_name":"codex"}
        """
        let convoB = """
        {"session_id":"019e0000-bbbb-7000-8000-000000000002","cwd":"/tmp/p","hook_event_name":"SessionStart","harness_name":"codex"}
        """
        try handleHook(convoA, hookName: "SessionStart")
        try handleHook(convoB, hookName: "SessionStart")

        let files = try FileManager.default.contentsOfDirectory(atPath: sessionsDir)
            .filter { $0.hasSuffix(".json") }.sorted()
        XCTAssertEqual(files, [
            "codex-019e0000-aaaa-7000-8000-000000000001.json",
            "codex-019e0000-bbbb-7000-8000-000000000002.json"
        ])
    }

    // MARK: - Session file naming contract

    /// Pins the writer-side naming rule directly: Codex files are keyed by session id
    /// (one host PID serves many conversations), everything else by PID. The codex-
    /// prefix must also keep matching what SessionManager.isLegacyUUIDFilename skips.
    func testSessionFileNameKeysCodexBySessionIdAndOthersByPID() throws {
        func input(_ json: String) throws -> HookInput {
            try JSONDecoder().decode(HookInput.self, from: Data(json.utf8))
        }
        let codex = try input("""
        {"session_id":"thread-1","cwd":"/tmp/p","hook_event_name":"SessionStart","harness_name":"codex"}
        """)
        let claude = try input("""
        {"session_id":"thread-1","cwd":"/tmp/p","hook_event_name":"SessionStart","harness_name":"cc"}
        """)
        let legacy = try input("""
        {"session_id":"thread-1","cwd":"/tmp/p","hook_event_name":"SessionStart"}
        """)

        XCTAssertEqual(sessionFileName(input: codex, pid: 4242, safeSessionId: "thread-1"), "codex-thread-1.json")
        XCTAssertEqual(sessionFileName(input: claude, pid: 4242, safeSessionId: "thread-1"), "4242.json")
        XCTAssertEqual(sessionFileName(input: legacy, pid: 4242, safeSessionId: "thread-1"), "4242.json")
    }
}
