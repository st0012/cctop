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
