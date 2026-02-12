import XCTest
@testable import CctopMenubar

/// Tests for PID-keyed session handling.
///
/// Session files are now keyed by PID (`{pid}.json`) instead of CC's
/// session_id. These tests verify:
/// - Dead sessions are cleaned up by project cleanup
/// - PID reuse is detected via process start time mismatch
/// - Session_id changes (resume) are handled by updating in place
final class ForkSessionTests: XCTestCase {
    var sessionsDir: String!
    var hookBinary: String!

    override func setUp() {
        super.setUp()
        sessionsDir = NSTemporaryDirectory()
            + "cctop-fork-test-\(UUID().uuidString)/"
        try! FileManager.default.createDirectory(
            atPath: sessionsDir,
            withIntermediateDirectories: true
        )

        let buildDir = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "build/Build/Products/Debug/cctop-hook"
            )
        hookBinary = buildDir.path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: sessionsDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func writeSession(
        id: String,
        projectPath: String,
        pid: UInt32,
        pidStartTime: TimeInterval? = nil,
        status: SessionStatus = .working
    ) {
        let session = Session(
            sessionId: id,
            projectPath: projectPath,
            projectName: Session.extractProjectName(projectPath),
            branch: "main",
            status: status,
            lastPrompt: nil,
            lastActivity: Date(),
            startedAt: Date(),
            terminal: TerminalInfo(program: "Code"),
            pid: pid,
            pidStartTime: pidStartTime,
            lastTool: nil,
            lastToolDetail: nil,
            notificationMessage: nil
        )
        // PID-keyed file path
        let path = (sessionsDir as NSString)
            .appendingPathComponent("\(pid).json")
        try! session.writeToFile(path: path)
    }

    private func pidPath(_ pid: UInt32) -> String {
        (sessionsDir as NSString)
            .appendingPathComponent("\(pid).json")
    }

    private func pidExists(_ pid: UInt32) -> Bool {
        FileManager.default.fileExists(atPath: pidPath(pid))
    }

    private func readPid(_ pid: UInt32) -> Session? {
        try? Session.fromFile(path: pidPath(pid))
    }

    @discardableResult
    private func fireSessionStart(
        sessionId: String,
        cwd: String
    ) -> UInt32? {
        guard FileManager.default.fileExists(atPath: hookBinary)
        else {
            XCTFail(
                "cctop-hook not found at \(hookBinary!)."
                + " Run `make build` first."
            )
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: hookBinary)
        process.arguments = ["SessionStart"]
        process.environment = [
            "CCTOP_SESSIONS_DIR": sessionsDir,
            "TERM_PROGRAM": "Test",
        ]

        let json = """
        {"session_id":"\(sessionId)",\
        "cwd":"\(cwd)",\
        "hook_event_name":"SessionStart"}
        """
        let inputPipe = Pipe()
        inputPipe.fileHandleForWriting.write(Data(json.utf8))
        inputPipe.fileHandleForWriting.closeFile()
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        try? process.run()
        process.waitUntilExit()

        // Find the session file created by the hook (scan for live PID)
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            atPath: sessionsDir
        ) else { return nil }
        for entry in entries where entry.hasSuffix(".json") {
            let path = (sessionsDir as NSString)
                .appendingPathComponent(entry)
            guard let session = try? Session.fromFile(path: path),
                  session.sessionId == sessionId
            else { continue }
            return session.pid
        }
        return nil
    }

    // MARK: - Dead sessions get cleaned up

    func testCleansUpDeadSiblingInSameProject() {
        let deadPID: UInt32 = 2_000_000
        writeSession(
            id: "dead-sibling",
            projectPath: "/tmp/same-project",
            pid: deadPID
        )

        let hookPID = fireSessionStart(
            sessionId: "new-session",
            cwd: "/tmp/same-project"
        )

        XCTAssertFalse(
            pidExists(deadPID),
            "Dead sibling's PID-keyed file should be cleaned up"
        )
        XCTAssertNotNil(hookPID, "Hook should create a session")
        if let hookPID {
            XCTAssertTrue(pidExists(hookPID))
        }
    }

    // MARK: - PID reuse detected by start time

    func testPIDReuseReplacesStaleSession() {
        // Fire once to discover the hook's resolved PID
        let hookPID = fireSessionStart(
            sessionId: "probe",
            cwd: "/tmp/probe-project"
        )
        guard let pid = hookPID else {
            XCTFail("Could not determine hook PID")
            return
        }

        // Overwrite with a stale session: same PID, wrong start time
        writeSession(
            id: "stale-session",
            projectPath: "/tmp/same-project",
            pid: pid,
            pidStartTime: 1.0
        )
        XCTAssertEqual(readPid(pid)?.sessionId, "stale-session")

        // Fire again — hook detects start time mismatch → replaces
        fireSessionStart(
            sessionId: "new-session",
            cwd: "/tmp/same-project"
        )

        let current = readPid(pid)
        XCTAssertEqual(
            current?.sessionId, "new-session",
            "Stale session with reused PID should be replaced"
        )
    }

    // MARK: - Session_id change on resume carries over state

    func testSessionIdChangePreservesState() {
        // Fire once to create a session and discover the PID
        let hookPID = fireSessionStart(
            sessionId: "original-id",
            cwd: "/tmp/my-project"
        )
        guard let pid = hookPID else {
            XCTFail("Could not determine hook PID")
            return
        }

        let original = readPid(pid)
        XCTAssertEqual(original?.sessionId, "original-id")

        // Fire again with different session_id (simulates CC resume
        // reassigning the session_id). Same process → same PID file.
        fireSessionStart(
            sessionId: "resumed-id",
            cwd: "/tmp/my-project"
        )

        let resumed = readPid(pid)
        XCTAssertEqual(
            resumed?.sessionId, "resumed-id",
            "Session_id should be updated to the new CC value"
        )
        XCTAssertEqual(
            resumed?.projectPath, "/tmp/my-project",
            "Project path should be preserved"
        )
    }

    // MARK: - Different PIDs coexist (live sessions)

    func testLiveSessionsSurviveProjectCleanup() {
        // Use PID 1 (launchd) — always alive and different from
        // the hook's resolved PID (which is the test runner)
        let otherPID: UInt32 = 1
        let otherStart = Session.processStartTime(pid: otherPID)
        writeSession(
            id: "other-session",
            projectPath: "/tmp/project",
            pid: otherPID,
            pidStartTime: otherStart
        )

        let hookPID = fireSessionStart(
            sessionId: "hook-session",
            cwd: "/tmp/project"
        )

        // Both should survive — different live PIDs in same project
        XCTAssertTrue(
            pidExists(otherPID),
            "Live session with different PID should survive cleanup"
        )
        if let hookPID {
            XCTAssertNotEqual(hookPID, otherPID)
            XCTAssertTrue(pidExists(hookPID))
        }
    }
}
