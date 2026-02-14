import XCTest
@testable import CctopMenubar

final class SessionTests: XCTestCase {
    func testDecodesRealSessionJSON() throws {
        let json = """
        {
            "session_id": "abc-123",
            "project_path": "/Users/test/projects/myapp",
            "project_name": "myapp",
            "branch": "main",
            "status": "working",
            "last_prompt": "Fix the bug",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code", "session_id": null, "tty": null},
            "pid": 12345,
            "last_tool": "Bash",
            "last_tool_detail": "npm test",
            "notification_message": null
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))

        XCTAssertEqual(session.sessionId, "abc-123")
        XCTAssertEqual(session.projectName, "myapp")
        XCTAssertEqual(session.status, .working)
        XCTAssertEqual(session.lastTool, "Bash")
        XCTAssertEqual(session.pid, 12345)
    }

    func testDecodesDateWithFractionalSeconds() throws {
        let json = """
        {
            "session_id": "frac-test",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00.123456Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"}
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.sessionId, "frac-test")
    }

    func testContextLineIdle() {
        let session = Session.mock(status: .idle)
        XCTAssertNil(session.contextLine)
    }

    func testContextLineWorking() {
        let session = Session.mock(status: .working, lastTool: "Bash", lastToolDetail: "npm test")
        XCTAssertEqual(session.contextLine, "Running: npm test")
    }

    func testContextLinePermission() {
        let session = Session.mock(status: .waitingPermission, notificationMessage: "Allow Bash: rm -rf /")
        XCTAssertEqual(session.contextLine, "Allow Bash: rm -rf /")
    }

    func testContextLinePermissionDefault() {
        let session = Session.mock(status: .waitingPermission)
        XCTAssertEqual(session.contextLine, "Permission needed")
    }

    func testContextLineCompacting() {
        let session = Session.mock(status: .compacting)
        XCTAssertEqual(session.contextLine, "Compacting context...")
    }

    func testDecodesSessionName() throws {
        let json = """
        {
            "session_id": "named-1",
            "project_path": "/Users/test/projects/myapp",
            "project_name": "myapp",
            "branch": "main",
            "status": "working",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "session_name": "refactor auth"
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.sessionName, "refactor auth")
        XCTAssertEqual(session.displayName, "refactor auth")
    }

    func testDecodesWithoutSessionName() throws {
        let json = """
        {
            "session_id": "no-name-1",
            "project_path": "/Users/test/projects/myapp",
            "project_name": "myapp",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"}
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(session.sessionName)
        XCTAssertEqual(session.displayName, "myapp")
    }

    func testDisplayNameReturnsSessionNameWhenSet() {
        let session = Session.mock(sessionName: "my task")
        XCTAssertEqual(session.displayName, "my task")
    }

    func testDisplayNameFallsBackToProjectName() {
        let session = Session.mock(project: "myapp")
        XCTAssertEqual(session.displayName, "myapp")
    }

    // MARK: - PID-keyed identity

    func testIdUsesPIDWhenAvailable() {
        let session = Session.mock(pid: 12345)
        XCTAssertEqual(session.id, "12345")
    }

    func testIdFallsBackToSessionIdWhenNoPID() {
        let session = Session.mock(id: "abc-123")
        XCTAssertEqual(session.id, "abc-123")
    }

    func testDecodesPidStartTime() throws {
        let json = """
        {
            "session_id": "pid-test",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "pid": 9999,
            "pid_start_time": 1707400000.123
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.pid, 9999)
        XCTAssertEqual(session.pidStartTime!, 1707400000.123, accuracy: 0.001)
    }

    func testDecodesWithoutPidStartTime() throws {
        let json = """
        {
            "session_id": "old-format",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "pid": 5555
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.pid, 5555)
        XCTAssertNil(session.pidStartTime)
    }

    func testProcessStartTimeReturnsValueForCurrentProcess() {
        let pid = UInt32(getpid())
        let startTime = Session.processStartTime(pid: pid)
        XCTAssertNotNil(startTime, "Should get start time for current process")
        XCTAssertGreaterThan(startTime ?? 0, 0)
    }

    func testDecodesWorkspaceFile() throws {
        let json = """
        {
            "session_id": "ws-1",
            "project_path": "/Users/test/projects/myapp",
            "project_name": "myapp",
            "branch": "main",
            "status": "working",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "workspace_file": "/Users/test/projects/myapp/myapp.code-workspace"
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.workspaceFile, "/Users/test/projects/myapp/myapp.code-workspace")
    }

    func testDecodesWithoutWorkspaceFile() throws {
        let json = """
        {
            "session_id": "no-ws",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "idle",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"}
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertNil(session.workspaceFile)
    }

    func testOldJsonWithContextCompactedStillDecodes() throws {
        let json = """
        {
            "session_id": "old-session",
            "project_path": "/tmp",
            "project_name": "test",
            "branch": "main",
            "status": "working",
            "last_activity": "2026-02-08T12:00:00Z",
            "started_at": "2026-02-08T11:00:00Z",
            "terminal": {"program": "Code"},
            "context_compacted": true
        }
        """
        let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: Data(json.utf8))
        XCTAssertEqual(session.sessionId, "old-session")
        XCTAssertEqual(session.status, .working)
    }
}
