import XCTest
@testable import CctopMenubar

final class DisplayStateWriterTests: XCTestCase {
    func testSnapshotPreservesCanonicalPanelAndNavigateOrder() {
        let now = Date()
        var permission = Session.mock(id: "a", project: "alpha", status: .waitingPermission)
        permission.lastActivity = now.addingTimeInterval(-30)
        var workingOld = Session.mock(id: "b", project: "bravo", status: .working)
        workingOld.lastActivity = now.addingTimeInterval(-300)
        var workingNew = Session.mock(id: "c", project: "charlie", status: .working)
        workingNew.lastActivity = now.addingTimeInterval(-10)
        var idle = Session.mock(id: "d", project: "delta", status: .idle)
        idle.lastActivity = now.addingTimeInterval(-60)
        let sessions = [workingOld, idle, permission, workingNew]

        let snapshot = DisplayStateWriter.snapshot(
            sessions: sessions,
            theme: .claude,
            appRunning: true,
            appIdentity: DisplayState.ProcessIdentity(pid: 123, startTime: 1_000),
            now: now
        )

        let expected = SessionDisplayPolicy.activeSessions(from: sessions, now: now)
        XCTAssertEqual(snapshot.sessions.map(\.id), expected.map(\.id))
        XCTAssertEqual(snapshot.sessions.map(\.id), ["b", "d", "a", "c"])
    }

    func testSnapshotExcludesSessionsTheAppDoesNotDisplay() {
        let now = Date()
        var dormant = Session.mock(id: "dormant", status: .working)
        dormant.lifecycle = .dormant
        var staleIdle = Session.mock(id: "stale", status: .idle)
        staleIdle.lastActivity = now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)
        let active = Session.mock(id: "active", status: .working)

        let snapshot = DisplayStateWriter.snapshot(
            sessions: [dormant, staleIdle, active],
            theme: .claude,
            appRunning: true,
            appIdentity: DisplayState.ProcessIdentity(pid: 123, startTime: 1_000),
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.id), ["active"])
    }

    func testProjectionContainsOnlyAppOwnedDisplayFields() throws {
        let now = Date()
        let session = Session.mock(
            id: "stable-display-id",
            project: "cctop",
            sessionName: "fix panel drift",
            status: .working,
            source: "codex"
        )
        let snapshot = DisplayStateWriter.snapshot(
            sessions: [session],
            theme: .claude,
            appRunning: true,
            appIdentity: DisplayState.ProcessIdentity(pid: 456, startTime: 1_234.5),
            now: now
        )

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(object.keys),
            ["version", "generated_at", "app_running", "app_pid", "app_start_time", "sessions"]
        )
        XCTAssertEqual(object["app_pid"] as? Int, 456)
        XCTAssertEqual(object["app_start_time"] as? Double, 1_234.5)
        let entry = try XCTUnwrap((object["sessions"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(entry.keys), ["id", "name", "status", "color"])
        XCTAssertEqual(entry["id"] as? String, "stable-display-id")
        XCTAssertEqual(entry["name"] as? String, "fix panel drift")
        XCTAssertEqual(entry["status"] as? String, "working")
        XCTAssertEqual(entry["color"] as? String, "#7EAA6E")
    }

    func testStoppedSnapshotPreservesRecentTargetsButDropsProcessIdentity() {
        let snapshot = DisplayStateWriter.snapshot(
            sessions: [Session.mock(id: "stable-display-id", status: .working)],
            theme: .claude,
            appRunning: false,
            appIdentity: DisplayState.ProcessIdentity(pid: 456, startTime: 1_234.5),
            now: Date()
        )

        XCTAssertFalse(snapshot.appRunning)
        XCTAssertNil(snapshot.appPID)
        XCTAssertNil(snapshot.appStartTime)
        XCTAssertEqual(snapshot.sessions.map(\.id), ["stable-display-id"])
    }

    func testHexColorsUseCctopThemeVariants() {
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .working, theme: .claude), "#7EAA6E")
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .waitingPermission, theme: .claude), "#DD5353")
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .waitingInput, theme: .gruvbox), "#FABD2F")
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .needsAttention, theme: .gruvbox), "#FABD2F")
    }
}
