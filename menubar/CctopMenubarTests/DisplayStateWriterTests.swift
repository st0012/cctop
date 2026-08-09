import XCTest
@testable import CctopMenubar

final class DisplayStateWriterTests: XCTestCase {
    func testDisplayStateDecodingPreservesOwnerAndSessionIdentity() throws {
        let requestedID = "11111111-2222-4333-8444-555555555555"
        let data = Data(
            """
            {
              "version": 2,
              "generated_at": "2026-07-30T00:00:00.000Z",
              "app_running": true,
              "app_pid": 456,
              "app_start_time": 1234.5,
              "sessions": [
                {
                  "cctop_session_id": "\(requestedID)", "name": "one",
                  "status": "working", "color": "#111111"
                }
              ]
            }
            """.utf8
        )

        let decoder = JSONDecoder()
        let state = try decoder.decode(DisplayState.self, from: data)

        XCTAssertEqual(state.version, 2)
        XCTAssertEqual(state.appPID, 456)
        XCTAssertEqual(state.appStartTime, 1_234.5)
        XCTAssertEqual(state.sessions.first?.cctopSessionId, requestedID)
    }

    func testSnapshotPreservesCanonicalPanelAndNavigateOrder() {
        let now = Date()
        var permission = SessionData.mock(id: "a", project: "alpha", status: .waitingPermission)
        permission.lastActivity = now.addingTimeInterval(-30)
        var workingOld = SessionData.mock(id: "b", project: "bravo", status: .working)
        workingOld.lastActivity = now.addingTimeInterval(-300)
        var workingNew = SessionData.mock(id: "c", project: "charlie", status: .working)
        workingNew.lastActivity = now.addingTimeInterval(-10)
        var idle = SessionData.mock(id: "d", project: "delta", status: .idle)
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
        XCTAssertEqual(snapshot.sessions.count, expected.count)
        XCTAssertEqual(
            snapshot.sessions.map(\.cctopSessionId),
            expected.map { $0.cctopSessionId ?? "" }
        )
        XCTAssertEqual(snapshot.sessions.map(\.name), ["alpha", "bravo", "charlie", "delta"])
    }

    func testSnapshotExcludesSessionsTheAppDoesNotDisplay() {
        let now = Date()
        var dormant = SessionData.mock(id: "dormant", status: .working)
        dormant.lifecycle = .dormant
        var staleIdle = SessionData.mock(id: "stale", status: .idle)
        staleIdle.lastActivity = now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)
        let active = SessionData.mock(id: "active", status: .working)

        let snapshot = DisplayStateWriter.snapshot(
            sessions: [dormant, staleIdle, active],
            theme: .claude,
            appRunning: true,
            appIdentity: DisplayState.ProcessIdentity(pid: 123, startTime: 1_000),
            now: now
        )

        XCTAssertEqual(snapshot.sessions.map(\.cctopSessionId), [active.cctopSessionId ?? ""])
    }

    func testProjectionContainsOnlyAppOwnedDisplayFields() throws {
        let now = Date()
        let session = SessionData.mock(
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
        XCTAssertEqual(Set(entry.keys), ["cctop_session_id", "name", "status", "color"])
        XCTAssertEqual(entry["cctop_session_id"] as? String, session.cctopSessionId)
        XCTAssertTrue(CctopSessionID.isValid(entry["cctop_session_id"] as? String))
        XCTAssertEqual(entry["name"] as? String, "fix panel drift")
        XCTAssertEqual(entry["status"] as? String, "working")
        XCTAssertEqual(entry["color"] as? String, "#7EAA6E")
    }

    func testStoppedSnapshotPreservesRecentTargetsButDropsProcessIdentity() {
        let session = SessionData.mock(id: "stable-display-id", status: .working)
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
        XCTAssertEqual(snapshot.sessions.map(\.cctopSessionId), [session.cctopSessionId ?? ""])
    }

    func testSnapshotKeepsOneOrderedEntryPerVisibleFocusTarget() {
        let now = Date()
        let cctopSessionID = "11111111-2222-4333-8444-555555555555"
        var original = SessionData.mock(
            id: "conv-1", cctopSessionId: cctopSessionID, harnessSessionId: "conv-1", project: "first",
            status: .working, pid: 111, pidStartTime: 1_000
        )
        original.lastActivity = now.addingTimeInterval(-10)
        var resumedElsewhere = SessionData.mock(
            id: "conv-1", cctopSessionId: cctopSessionID, harnessSessionId: "conv-1", project: "second",
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

        XCTAssertEqual(snapshot.sessions.map(\.cctopSessionId), [cctopSessionID, cctopSessionID])
        XCTAssertEqual(snapshot.sessions.map(\.name), ["first", "second"])
    }

    func testMissingLegacyIdentityLeavesAnEmptySlotWithoutShiftingLaterRows() {
        var legacy = SessionData.mock(id: "legacy", project: "first", status: .working)
        legacy.cctopSessionId = nil
        let current = SessionData.mock(id: "current", project: "second", status: .working)

        let snapshot = DisplayStateWriter.snapshot(
            sessions: [legacy, current],
            theme: .claude,
            appRunning: true,
            appIdentity: nil,
            now: Date()
        )

        XCTAssertEqual(snapshot.sessions.count, 2)
        XCTAssertEqual(snapshot.sessions.map(\.cctopSessionId), ["", current.cctopSessionId ?? ""])
        XCTAssertEqual(snapshot.sessions.map(\.name), ["first", "second"])
    }

    func testHexColorsUseCctopThemeVariants() {
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .working, theme: .claude), "#7EAA6E")
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .waitingPermission, theme: .claude), "#DD5353")
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .waitingInput, theme: .gruvbox), "#FABD2F")
        XCTAssertEqual(DisplayStateWriter.hexColor(for: .needsAttention, theme: .gruvbox), "#FABD2F")
    }
}
