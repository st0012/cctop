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
        let sessions = [permission, workingOld, workingNew, idle]

        let snapshot = DisplayStateWriter.snapshot(
            sessions: sessions,
            theme: .claude,
            appRunning: true,
            appIdentity: DisplayState.ProcessIdentity(pid: 123, startTime: 1_000),
            now: now
        )

        let expected = SessionDisplayPolicy.activeSessions(from: sessions, now: now)
        XCTAssertEqual(
            snapshot.sessions.map(\.id),
            expected.map { SessionIdentityPolicy.actionID(for: $0) }
        )
        XCTAssertEqual(snapshot.sessions.map(\.name), ["alpha", "bravo", "charlie", "delta"])
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

        XCTAssertEqual(snapshot.sessions.map(\.id), [SessionIdentityPolicy.actionID(for: active)])
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
        XCTAssertEqual(entry["id"] as? String, SessionIdentityPolicy.actionID(for: session))
        // Published ids are opaque tokens: no pid, session id, or source shape leaks through.
        XCTAssertNotNil(
            (entry["id"] as? String)?.range(of: "^s-[0-9a-f]{32}$", options: .regularExpression)
        )
        XCTAssertEqual(entry["name"] as? String, "fix panel drift")
        XCTAssertEqual(entry["status"] as? String, "working")
        XCTAssertEqual(entry["color"] as? String, "#7EAA6E")
    }

    func testStoppedSnapshotPreservesRecentTargetsButDropsProcessIdentity() {
        let session = Session.mock(id: "stable-display-id", status: .working)
        let snapshot = DisplayStateWriter.snapshot(
            sessions: [session],
            theme: .claude,
            appRunning: false,
            appIdentity: DisplayState.ProcessIdentity(pid: 456, startTime: 1_234.5),
            now: Date()
        )

        XCTAssertFalse(snapshot.appRunning)
        XCTAssertNil(snapshot.appPID)
        XCTAssertNil(snapshot.appStartTime)
        XCTAssertEqual(snapshot.sessions.map(\.id), [SessionIdentityPolicy.actionID(for: session)])
    }

    func testSnapshotKeepsOneOrderedEntryPerVisibleFocusTarget() {
        let now = Date()
        var original = Session.mock(
            id: "conv-1", harnessSessionId: "conv-1", project: "first",
            status: .working, pid: 111, pidStartTime: 1_000
        )
        original.lastActivity = now.addingTimeInterval(-10)
        var resumedElsewhere = Session.mock(
            id: "conv-1", harnessSessionId: "conv-1", project: "second",
            status: .working, pid: 999, pidStartTime: 2_000
        )
        resumedElsewhere.lastActivity = now.addingTimeInterval(-20)
        let canonical = [original, resumedElsewhere]

        let snapshot = DisplayStateWriter.snapshot(
            sessions: canonical,
            theme: .claude,
            appRunning: true,
            appIdentity: DisplayState.ProcessIdentity(pid: 123, startTime: 1_000),
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.id), canonical.map { SessionIdentityPolicy.actionID(for: $0) })
        XCTAssertEqual(Set(snapshot.sessions.map(\.id)).count, 2)
        XCTAssertEqual(snapshot.sessions.map(\.name), ["first", "second"])
    }

    func testHexColorsUseCctopThemeVariants() {
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .working, theme: .claude), "#7EAA6E")
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .waitingPermission, theme: .claude), "#DD5353")
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .waitingInput, theme: .gruvbox), "#FABD2F")
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .needsAttention, theme: .gruvbox), "#FABD2F")
    }
}
