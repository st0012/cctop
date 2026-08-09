import XCTest
@testable import CctopMenubar

final class NavigateControllerTests: XCTestCase {
    private var sut: NavigateController!

    override func setUp() {
        super.setUp()
        sut = NavigateController()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertFalse(sut.isActive)
        XCTAssertTrue(sut.frozenSessionIdentities.isEmpty)
    }

    // MARK: - Activate

    func testActivateSetsIsActive() {
        sut.activate(sessions: [])
        XCTAssertTrue(sut.isActive)
    }

    func testActivateFreezesSessions() {
        let sessions = [
            SessionData.mock(id: "1", project: "alpha", status: .idle),
            SessionData.mock(id: "2", project: "beta", status: .working),
        ]
        sut.activate(sessions: sessions)
        XCTAssertEqual(sut.frozenSessionIdentities.count, 2)
    }

    func testActivatePreservesCanonicalSessionOrder() {
        let now = Date()
        let waiting = SessionData.mock(id: "1", project: "alpha", status: .waitingInput)
        var workingOld = SessionData.mock(id: "2", project: "beta", status: .working)
        workingOld.lastActivity = now.addingTimeInterval(-600)
        var workingNew = SessionData.mock(id: "3", project: "gamma", status: .working)
        workingNew.lastActivity = now
        let idle = SessionData.mock(id: "4", project: "delta", status: .idle)

        sut.activate(sessions: [waiting, workingOld, workingNew, idle])

        XCTAssertEqual(
            sut.frozenSessionIdentities,
            [waiting, workingOld, workingNew, idle].map { SessionIdentityPolicy.logicalIdentity(for: $0) }
        )
    }

    func testActivateWithEmptySessions() {
        sut.activate(sessions: [])
        XCTAssertTrue(sut.isActive)
        XCTAssertTrue(sut.frozenSessionIdentities.isEmpty)
    }

    // MARK: - Deactivate

    func testDeactivateClearsIsActive() {
        sut.activate(sessions: [.mock()])
        sut.deactivate()
        XCTAssertFalse(sut.isActive)
    }

    func testDeactivateClearsFrozenSessions() {
        sut.activate(sessions: [.mock(), .mock(id: "2")])
        sut.deactivate()
        XCTAssertTrue(sut.frozenSessionIdentities.isEmpty)
    }

    func testDeactivateCancelsTimeout() {
        let expectation = expectation(description: "timeout should not fire")
        expectation.isInverted = true

        sut.activate(sessions: [])
        sut.startTimeout(duration: 0.05) { expectation.fulfill() }
        sut.deactivate()

        waitForExpectations(timeout: 0.2)
    }

    func testDeactivateFromInactiveStateIsNoOp() {
        sut.deactivate()
        XCTAssertFalse(sut.isActive)
        XCTAssertTrue(sut.frozenSessionIdentities.isEmpty)
    }

    // MARK: - Frozen sessions are a snapshot

    func testFrozenSessionsAreSnapshot() {
        var sessions = [
            SessionData.mock(id: "1", project: "alpha", status: .working),
        ]
        sut.activate(sessions: sessions)

        // Mutating the original array shouldn't affect frozen sessions
        sessions.append(.mock(id: "2", project: "beta", status: .idle))
        XCTAssertEqual(sut.frozenSessionIdentities.count, 1)
    }

    func testFrozenSlotResolvesReplacementCurrentRecord() throws {
        let sharedID = "22222222-2222-4222-8222-222222222222"
        let first = SessionData.mock(
            id: "first", cctopSessionId: sharedID,
            status: .working, pid: 100, source: SessionData.opencodeSource
        )
        let replacement = SessionData.mock(
            id: "replacement", cctopSessionId: sharedID,
            status: .waitingInput, pid: 200, source: SessionData.opencodeSource
        )
        sut.activate(sessions: [first])

        let identity = try XCTUnwrap(sut.sessionIdentity(at: 0))
        let resolved = FocusTargetResolver.currentSession(
            for: identity,
            in: userSessionProjection(from: [replacement])
        )

        XCTAssertEqual(resolved?.pid, 200)
    }

    func testFrozenLegacySlotResolvesSameStableKeyAfterPermanentIDStamp() throws {
        var legacy = SessionData.mock(
            id: "legacy", status: .working, pid: 100, source: SessionData.opencodeSource
        )
        legacy.cctopSessionId = nil
        sut.activate(sessions: [legacy])

        var stamped = legacy
        stamped.cctopSessionId = "22222222-2222-4222-8222-222222222222"
        let identity = try XCTUnwrap(sut.sessionIdentity(at: 0))
        let resolved = FocusTargetResolver.currentSession(
            for: identity,
            in: userSessionProjection(from: [stamped])
        )

        XCTAssertEqual(resolved?.cctopSessionId, stamped.cctopSessionId)
        XCTAssertEqual(resolved?.pid, 100)
    }

    func testFrozenLegacySlotResolvesCurrentUserSessionAfterPermanentIDStamp() throws {
        var legacy = SessionData.mock(
            id: "legacy", status: .working, pid: 100, source: SessionData.opencodeSource
        )
        legacy.cctopSessionId = nil
        sut.activate(sessions: [legacy])

        var stamped = legacy
        stamped.cctopSessionId = "22222222-2222-4222-8222-222222222222"
        let identity = try XCTUnwrap(sut.sessionIdentity(at: 0))
        let current = userSession(display: stamped, records: [stamped])

        XCTAssertEqual(
            FocusTargetResolver.currentSession(for: identity, in: [current])?.cctopSessionId,
            stamped.cctopSessionId
        )

        var conflicting = stamped
        conflicting.cctopSessionId = "33333333-3333-4333-8333-333333333333"
        let conflictingUserSession = userSession(display: conflicting, records: [conflicting])
        XCTAssertNil(FocusTargetResolver.currentSession(
            for: identity,
            in: [current, conflictingUserSession]
        ))
    }

    func testMissingFrozenSlotDoesNotRetargetLaterSlot() throws {
        let first = SessionData.mock(
            id: "first", cctopSessionId: "11111111-1111-4111-8111-111111111111",
            status: .working, source: SessionData.codexSource
        )
        let second = SessionData.mock(
            id: "second", cctopSessionId: "22222222-2222-4222-8222-222222222222",
            status: .working, source: SessionData.codexSource
        )
        sut.activate(sessions: [first, second])

        let firstIdentity = try XCTUnwrap(sut.sessionIdentity(at: 0))
        let secondIdentity = try XCTUnwrap(sut.sessionIdentity(at: 1))

        let currentUserSessions = userSessionProjection(from: [second])
        XCTAssertNil(FocusTargetResolver.currentSession(for: firstIdentity, in: currentUserSessions))
        XCTAssertEqual(
            FocusTargetResolver.currentSession(for: secondIdentity, in: currentUserSessions)?.sessionId,
            "second"
        )
    }

    @MainActor
    func testPopupRowsPreserveFrozenSlotAndBindReplacementRecord() throws {
        let missing = SessionData.mock(
            id: "missing", cctopSessionId: "11111111-1111-4111-8111-111111111111",
            status: .working, source: SessionData.codexSource
        )
        let original = SessionData.mock(
            id: "original", cctopSessionId: "22222222-2222-4222-8222-222222222222",
            status: .working, pid: 100, source: SessionData.codexSource
        )
        let replacement = SessionData.mock(
            id: "replacement", cctopSessionId: original.cctopSessionId,
            status: .waitingInput, pid: 200, source: SessionData.codexSource
        )
        sut.activate(sessions: [missing, original])

        let view = PopupView(
            sessions: [replacement],
            userSessions: userSessionProjection(from: [replacement]),
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            navigate: sut
        )
        let row = try XCTUnwrap(view.activeSessionRows.first)

        XCTAssertEqual(view.activeSessionRows.count, 1)
        XCTAssertEqual(row.slot, 1)
        XCTAssertEqual(row.id, SessionIdentityPolicy.logicalIdentity(for: original))
        XCTAssertEqual(row.session, replacement)
    }

    @MainActor
    func testPopupKeyboardResolutionUsesRetainedLegacyRecordAfterDisplayTargetChanges() throws {
        var legacy = SessionData.mock(
            id: "legacy-observation", status: .working, pid: 100, source: SessionData.opencodeSource
        )
        legacy.cctopSessionId = nil
        let current = SessionData.mock(
            id: "current-observation",
            cctopSessionId: "22222222-2222-4222-8222-222222222222",
            status: .waitingInput,
            pid: 200,
            source: SessionData.opencodeSource
        )
        sut.activate(sessions: [legacy])

        let view = PopupView(
            sessions: [current],
            userSessions: [userSession(display: current, records: [legacy, current])],
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            navigate: sut
        )

        let row = try XCTUnwrap(view.activeSessionRows.first)
        let frozenIdentity = try XCTUnwrap(sut.sessionIdentity(at: 0))
        XCTAssertEqual(row.slot, 0)
        XCTAssertEqual(row.session, current)
        XCTAssertEqual(view.currentSession(for: frozenIdentity, in: .active), current)
    }

    func testInactiveControllerHasNoActiveSnapshot() {
        XCTAssertNil(sut.activeSessionIdentitySnapshot)
        XCTAssertNil(sut.sessionIdentity(at: 0))
    }

    // MARK: - Timeout

    func testTimeoutFiresWhenActive() {
        let expectation = expectation(description: "timeout fires")

        sut.activate(sessions: [])
        sut.startTimeout(duration: 0.05) { expectation.fulfill() }

        waitForExpectations(timeout: 1.0)
    }

    func testTimeoutDoesNotFireWhenDeactivatedBeforeExpiry() {
        let expectation = expectation(description: "timeout should not fire")
        expectation.isInverted = true

        sut.activate(sessions: [])
        sut.startTimeout(duration: 0.1) { expectation.fulfill() }
        sut.deactivate()

        waitForExpectations(timeout: 0.3)
    }

    func testTimeoutDoesNotFireIfManuallyDeactivated() {
        let expectation = expectation(description: "timeout should not fire")
        expectation.isInverted = true

        sut.activate(sessions: [])
        sut.startTimeout(duration: 0.05) {
            expectation.fulfill()
        }
        // Deactivate before timeout — the guard inside the work item checks isActive
        sut.isActive = false

        waitForExpectations(timeout: 0.2)
    }

    func testCancelTimeoutPreventsCallback() {
        let expectation = expectation(description: "timeout should not fire")
        expectation.isInverted = true

        sut.activate(sessions: [])
        sut.startTimeout(duration: 0.05) { expectation.fulfill() }
        sut.cancelTimeout()

        waitForExpectations(timeout: 0.2)
    }

    func testCancelTimeoutWhenNoneScheduledIsNoOp() {
        // Should not crash
        sut.cancelTimeout()
    }

    func testStartTimeoutReplacesExistingTimeout() {
        let first = expectation(description: "first timeout should not fire")
        first.isInverted = true
        let second = expectation(description: "second timeout fires")

        sut.activate(sessions: [])
        sut.startTimeout(duration: 0.05) { first.fulfill() }
        // Starting a new timeout cancels the previous one
        sut.startTimeout(duration: 0.05) { second.fulfill() }

        waitForExpectations(timeout: 1.0)
    }

    // MARK: - Activate → Deactivate cycle

    func testFullActivateDeactivateCycle() {
        let sessions = [
            SessionData.mock(id: "1", status: .working),
            SessionData.mock(id: "2", status: .idle),
        ]

        // Activate
        sut.activate(sessions: sessions)

        XCTAssertTrue(sut.isActive)
        XCTAssertEqual(sut.frozenSessionIdentities.count, 2)

        // Deactivate resets all state
        sut.deactivate()

        XCTAssertFalse(sut.isActive)
        XCTAssertTrue(sut.frozenSessionIdentities.isEmpty)
    }

    func testMultipleActivateDeactivateCycles() {
        for i in 0..<3 {
            let sessions = [SessionData.mock(id: "\(i)", status: .working)]
            sut.activate(sessions: sessions)
            XCTAssertTrue(sut.isActive)
            XCTAssertEqual(sut.frozenSessionIdentities.count, 1)

            sut.deactivate()
            XCTAssertFalse(sut.isActive)
            XCTAssertTrue(sut.frozenSessionIdentities.isEmpty)
        }
    }

    // MARK: - Canonical order in frozen sessions

    func testFrozenSessionsPreserveOrderAcrossActivityTimes() {
        var older = SessionData.mock(id: "1", project: "older", status: .working)
        older.lastActivity = Date().addingTimeInterval(-120)
        var newer = SessionData.mock(id: "2", project: "newer", status: .working)
        newer.lastActivity = Date()

        sut.activate(sessions: [older, newer])

        XCTAssertEqual(
            sut.frozenSessionIdentities,
            [older, newer].map { SessionIdentityPolicy.logicalIdentity(for: $0) }
        )
    }
}
