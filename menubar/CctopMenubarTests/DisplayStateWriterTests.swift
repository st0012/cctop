import XCTest
@testable import CctopMenubar

final class DisplayStateWriterTests: XCTestCase {
    func testDiagnosticSnapshotReadsCurrentOwnerAndRequestedIdentityCount() {
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
                {"cctop_session_id": "\(requestedID)"},
                {"cctop_session_id": "22222222-3333-4444-8555-666666666666"},
                {"cctop_session_id": "\(requestedID)"}
              ]
            }
            """.utf8
        )

        let snapshot = DisplayStateWriter.diagnosticSnapshot(
            from: data,
            forCctopSessionID: requestedID,
            currentProcessIdentity: DisplayState.ProcessIdentity(pid: 456, startTime: 1_234.5)
        )

        XCTAssertEqual(snapshot.readStatus, .available)
        XCTAssertEqual(snapshot.version, 2)
        XCTAssertEqual(snapshot.generatedAt, "2026-07-30T00:00:00.000Z")
        XCTAssertEqual(snapshot.sessionCount, 3)
        XCTAssertEqual(snapshot.requestedIDMatchCount, 2)
        XCTAssertEqual(snapshot.ownerMatchesCurrentProcess, true)
    }

    func testDiagnosticSnapshotIdentifiesForeignOwner() {
        let data = Data(
            """
            {
              "version": 2,
              "generated_at": "2026-07-30T00:00:00.000Z",
              "app_running": true,
              "app_pid": 999,
              "app_start_time": 2000,
              "sessions": []
            }
            """.utf8
        )

        let snapshot = DisplayStateWriter.diagnosticSnapshot(
            from: data,
            forCctopSessionID: "11111111-2222-4333-8444-555555555555",
            currentProcessIdentity: DisplayState.ProcessIdentity(pid: 456, startTime: 1_234.5)
        )

        XCTAssertEqual(snapshot.readStatus, .available)
        XCTAssertEqual(snapshot.ownerMatchesCurrentProcess, false)
    }

    func testDiagnosticSnapshotReportsMissingAndMalformedState() {
        let requestedID = "11111111-2222-4333-8444-555555555555"

        let missing = DisplayStateWriter.diagnosticSnapshot(
            from: nil,
            forCctopSessionID: requestedID,
            currentProcessIdentity: nil
        )
        let malformed = DisplayStateWriter.diagnosticSnapshot(
            from: Data("{}".utf8),
            forCctopSessionID: requestedID,
            currentProcessIdentity: nil
        )
        let injectedTimestamp = DisplayStateWriter.diagnosticSnapshot(
            from: Data(
                """
                {
                  "version": 2,
                  "generated_at": "not-a-timestamp\\nprivate_field=injected",
                  "app_running": true,
                  "app_pid": 456,
                  "app_start_time": 1234.5,
                  "sessions": []
                }
                """.utf8
            ),
            forCctopSessionID: requestedID,
            currentProcessIdentity: nil
        )

        XCTAssertEqual(missing.readStatus, .missing)
        XCTAssertEqual(malformed.readStatus, .malformed)
        XCTAssertEqual(injectedTimestamp.readStatus, .malformed)
        XCTAssertNil(injectedTimestamp.generatedAt)
    }

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
        XCTAssertEqual(snapshot.sessions.count, expected.count)
        XCTAssertEqual(
            snapshot.sessions.map(\.cctopSessionId),
            expected.map { $0.cctopSessionId ?? "" }
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

        XCTAssertEqual(snapshot.sessions.map(\.cctopSessionId), [active.cctopSessionId ?? ""])
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
        XCTAssertEqual(Set(entry.keys), ["cctop_session_id", "name", "status", "color"])
        XCTAssertEqual(entry["cctop_session_id"] as? String, session.cctopSessionId)
        XCTAssertTrue(Session.isValidCctopSessionId(entry["cctop_session_id"] as? String))
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
        XCTAssertEqual(snapshot.sessions.map(\.cctopSessionId), [session.cctopSessionId ?? ""])
    }

    func testSnapshotKeepsOneOrderedEntryPerVisibleFocusTarget() {
        let now = Date()
        let cctopSessionID = "11111111-2222-4333-8444-555555555555"
        var original = Session.mock(
            id: "conv-1", cctopSessionId: cctopSessionID, harnessSessionId: "conv-1", project: "first",
            status: .working, pid: 111, pidStartTime: 1_000
        )
        original.lastActivity = now.addingTimeInterval(-10)
        var resumedElsewhere = Session.mock(
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
        var legacy = Session.mock(id: "legacy", project: "first", status: .working)
        legacy.cctopSessionId = nil
        let current = Session.mock(id: "current", project: "second", status: .working)

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
