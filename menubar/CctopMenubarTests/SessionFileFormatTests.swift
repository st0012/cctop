import XCTest
@testable import CctopMenubar

final class SessionFileFormatTests: XCTestCase {
    func testLegacyUUIDFilenameClassification() {
        // Pre-PID files were keyed by a bare session UUID → should be removed.
        XCTAssertTrue(SessionManager.isLegacyUUIDFilename("019e4b0c-9473-7a33-a4b9-749fd2c83a9e"))
        // PID-keyed files are numeric → keep.
        XCTAssertFalse(SessionManager.isLegacyUUIDFilename("31349"))
        // Codex per-conversation files → keep.
        XCTAssertFalse(SessionManager.isLegacyUUIDFilename("codex-019e4b0c-9473-7a33-a4b9-749fd2c83a9e"))
    }

    func testCodexStaleWorkingDemotedToIdleForDisplay() {
        var s = Session(sessionId: "codex-1", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        s.source = "codex"
        s.status = .working

        // Silent for 10 minutes → display as idle.
        s.lastActivity = Date(timeIntervalSinceNow: -600)
        XCTAssertEqual(SessionManager.adjustCodexStaleWorking(s).status, .idle)

        // Active within the window → stays working.
        s.lastActivity = Date()
        XCTAssertEqual(SessionManager.adjustCodexStaleWorking(s).status, .working)

        // Non-codex sources are never demoted by this rule.
        s.source = "cc"
        s.lastActivity = Date(timeIntervalSinceNow: -600)
        XCTAssertEqual(SessionManager.adjustCodexStaleWorking(s).status, .working)
    }
}
