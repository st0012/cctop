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
        let entries = try FileManager.default.contentsOfDirectory(atPath: sessionsDir)
        let jsonFiles = entries.filter { $0.hasSuffix(".json") }
        XCTAssertEqual(
            jsonFiles.count, 1,
            "Expected exactly 1 session file, found \(jsonFiles.count): \(jsonFiles)"
        )
        let path = (sessionsDir as NSString).appendingPathComponent(jsonFiles[0])
        return try Session.fromFile(path: path)
    }

    private func sessionFileExists() -> Bool {
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: sessionsDir)) ?? []
        return entries.contains { $0.hasSuffix(".json") }
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
}
