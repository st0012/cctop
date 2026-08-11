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
        sut.activate(userSessions: [])
        XCTAssertTrue(sut.isActive)
    }

    func testActivateFreezesSessions() {
        let sessions = [
            SessionData.mock(id: "1", project: "alpha", status: .idle),
            SessionData.mock(id: "2", project: "beta", status: .working),
        ]
        let userSessions = sessions.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }
        sut.activate(userSessions: userSessions)
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

        let userSessions = [waiting, workingOld, workingNew, idle].map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }
        sut.activate(userSessions: userSessions)

        XCTAssertEqual(
            sut.frozenSessionIdentities,
            userSessions.map(\.identity)
        )
    }

    func testActivateWithEmptySessions() {
        sut.activate(userSessions: [])
        XCTAssertTrue(sut.isActive)
        XCTAssertTrue(sut.frozenSessionIdentities.isEmpty)
    }

    // MARK: - Deactivate

    func testDeactivateClearsIsActive() {
        let data = SessionData.mock()
        sut.activate(userSessions: [userSession(
            identity: SessionIdentityPolicy.logicalIdentity(for: data),
            display: data,
            records: [data]
        )])
        sut.deactivate()
        XCTAssertFalse(sut.isActive)
    }

    func testDeactivateClearsFrozenSessions() {
        let data = [SessionData.mock(), SessionData.mock(id: "2")]
        sut.activate(userSessions: data.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        })
        sut.deactivate()
        XCTAssertTrue(sut.frozenSessionIdentities.isEmpty)
    }

    func testDeactivateCancelsTimeout() {
        let expectation = expectation(description: "timeout should not fire")
        expectation.isInverted = true

        sut.activate(userSessions: [])
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
        sut.activate(userSessions: sessions.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        })

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
        let permanentIdentity = SessionIdentityPolicy.LogicalIdentity.permanent(
            try XCTUnwrap(UUID(uuidString: sharedID))
        )
        sut.activate(userSessions: [userSession(
            identity: permanentIdentity,
            display: first,
            records: [first]
        )])

        let identity = try XCTUnwrap(sut.sessionIdentity(at: 0))
        let resolved = FocusTargetResolver.currentUserSession(
            for: identity,
            in: [userSession(identity: permanentIdentity, display: replacement, records: [replacement])]
        )

        XCTAssertEqual(resolved?.focusTarget.pid, 200)
    }

    func testFrozenLegacySlotResolvesSameStableKeyAfterPermanentIDStamp() throws {
        var legacy = SessionData.mock(
            id: "legacy", status: .working, pid: 100, source: SessionData.opencodeSource
        )
        legacy.cctopSessionId = nil
        let legacyIdentity = SessionIdentityPolicy.LogicalIdentity.legacy(
            SessionIdentityPolicy.stableKey(for: legacy)
        )
        sut.activate(userSessions: [userSession(identity: legacyIdentity, display: legacy, records: [legacy])])

        var stamped = legacy
        stamped.cctopSessionId = "22222222-2222-4222-8222-222222222222"
        let stampedIdentity = SessionIdentityPolicy.LogicalIdentity.permanent(
            try XCTUnwrap(UUID(uuidString: try XCTUnwrap(stamped.cctopSessionId)))
        )
        let identity = try XCTUnwrap(sut.sessionIdentity(at: 0))
        let resolved = FocusTargetResolver.currentUserSession(
            for: identity,
            in: [userSession(identity: stampedIdentity, display: stamped, records: [legacy, stamped])]
        )

        XCTAssertEqual(resolved?.identity, stampedIdentity)
        XCTAssertEqual(resolved?.focusTarget.cctopSessionId, stamped.cctopSessionId)
        XCTAssertEqual(resolved?.focusTarget.pid, 100)
    }

    func testFrozenLegacySlotResolvesCurrentUserSessionAfterPermanentIDStamp() throws {
        var legacy = SessionData.mock(
            id: "legacy", status: .working, pid: 100, source: SessionData.opencodeSource
        )
        legacy.cctopSessionId = nil
        let legacyIdentity = SessionIdentityPolicy.LogicalIdentity.legacy(
            SessionIdentityPolicy.stableKey(for: legacy)
        )
        sut.activate(userSessions: [userSession(identity: legacyIdentity, display: legacy, records: [legacy])])

        var stamped = legacy
        stamped.cctopSessionId = "22222222-2222-4222-8222-222222222222"
        let stampedIdentity = SessionIdentityPolicy.LogicalIdentity.permanent(
            try XCTUnwrap(UUID(uuidString: try XCTUnwrap(stamped.cctopSessionId)))
        )
        let identity = try XCTUnwrap(sut.sessionIdentity(at: 0))
        let current = userSession(
            identity: stampedIdentity,
            display: stamped,
            records: [legacy, stamped]
        )

        XCTAssertEqual(
            FocusTargetResolver.currentUserSession(for: identity, in: [current])?.focusTarget.cctopSessionId,
            stamped.cctopSessionId
        )

        var conflicting = stamped
        conflicting.cctopSessionId = "33333333-3333-4333-8333-333333333333"
        let conflictingUserSession = userSession(
            identity: .permanent(try XCTUnwrap(UUID(uuidString: try XCTUnwrap(conflicting.cctopSessionId)))),
            display: conflicting,
            records: [conflicting]
        )
        XCTAssertNil(FocusTargetResolver.currentUserSession(
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
        let firstIdentity = SessionIdentityPolicy.logicalIdentity(for: first)
        let secondIdentity = SessionIdentityPolicy.logicalIdentity(for: second)
        sut.activate(userSessions: [
            userSession(identity: firstIdentity, display: first, records: [first]),
            userSession(identity: secondIdentity, display: second, records: [second]),
        ])

        XCTAssertEqual(try XCTUnwrap(sut.sessionIdentity(at: 0)), firstIdentity)
        XCTAssertEqual(try XCTUnwrap(sut.sessionIdentity(at: 1)), secondIdentity)

        let currentUserSessions = [userSession(identity: secondIdentity, display: second, records: [second])]
        XCTAssertNil(FocusTargetResolver.currentUserSession(for: firstIdentity, in: currentUserSessions))
        XCTAssertEqual(
            FocusTargetResolver.currentUserSession(for: secondIdentity, in: currentUserSessions)?.focusTarget.sessionId,
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
        let missingIdentity = SessionIdentityPolicy.logicalIdentity(for: missing)
        let originalIdentity = SessionIdentityPolicy.logicalIdentity(for: original)
        sut.activate(userSessions: [
            userSession(identity: missingIdentity, display: missing, records: [missing]),
            userSession(identity: originalIdentity, display: original, records: [original]),
        ])

        let view = PopupView(
            userSessions: [userSession(
                identity: originalIdentity,
                display: replacement,
                records: [replacement]
            )],
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            navigate: sut
        )
        let row = try XCTUnwrap(view.activeSessionRows.first)

        XCTAssertEqual(view.activeSessionRows.count, 1)
        XCTAssertEqual(row.slot, 1)
        XCTAssertEqual(row.id, originalIdentity)
        XCTAssertEqual(row.session, replacement)
    }

    @MainActor
    func testPopupDirectRowUsesExactUserSessionDisplayRecord() throws {
        let sharedID = "22222222-2222-4222-8222-222222222222"
        let stale = SessionData.mock(
            id: "stale", cctopSessionId: sharedID,
            status: .working, pid: 100, source: SessionData.opencodeSource
        )
        let current = SessionData.mock(
            id: "current", cctopSessionId: sharedID,
            status: .working, pid: 200, source: SessionData.opencodeSource
        )
        let view = PopupView(
            userSessions: [userSession(
                identity: SessionIdentityPolicy.logicalIdentity(for: current),
                display: current,
                records: [stale, current]
            )],
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager()
        )

        XCTAssertEqual(try XCTUnwrap(view.activeSessionRows.first).session, current)
    }

    @MainActor
    func testPopupFrozenLegacyRowResolvesCurrentTargetAndHideIdentityAfterStamping() throws {
        var legacy = SessionData.mock(
            id: "legacy-record", status: .working, pid: 100, source: SessionData.opencodeSource
        )
        legacy.cctopSessionId = nil
        let current = SessionData.mock(
            id: "current-record",
            cctopSessionId: "22222222-2222-4222-8222-222222222222",
            status: .waitingInput,
            pid: 200,
            source: SessionData.opencodeSource
        )
        let legacyIdentity = SessionIdentityPolicy.LogicalIdentity.legacy(
            SessionIdentityPolicy.stableKey(for: legacy)
        )
        let currentIdentity = SessionIdentityPolicy.logicalIdentity(for: current)
        sut.activate(userSessions: [userSession(identity: legacyIdentity, display: legacy, records: [legacy])])

        let view = PopupView(
            userSessions: [userSession(identity: currentIdentity, display: current, records: [legacy, current])],
            updater: DisabledUpdater(),
            pluginManager: inertPluginManager(),
            navigate: sut
        )

        let row = try XCTUnwrap(view.activeSessionRows.first)
        let frozenIdentity = try XCTUnwrap(sut.sessionIdentity(at: 0))
        XCTAssertEqual(row.slot, 0)
        XCTAssertEqual(row.id, legacyIdentity)
        XCTAssertEqual(row.userSession.identity, currentIdentity)
        XCTAssertEqual(row.session, current)
        XCTAssertEqual(view.currentUserSession(for: frozenIdentity, in: .active)?.focusTarget, current)
    }

    func testInactiveControllerHasNoActiveSnapshot() {
        XCTAssertNil(sut.activeSessionIdentitySnapshot)
        XCTAssertNil(sut.sessionIdentity(at: 0))
    }

    // MARK: - Timeout

    func testTimeoutFiresWhenActive() {
        let expectation = expectation(description: "timeout fires")

        sut.activate(userSessions: [])
        sut.startTimeout(duration: 0.05) { expectation.fulfill() }

        waitForExpectations(timeout: 1.0)
    }

    func testTimeoutDoesNotFireWhenDeactivatedBeforeExpiry() {
        let expectation = expectation(description: "timeout should not fire")
        expectation.isInverted = true

        sut.activate(userSessions: [])
        sut.startTimeout(duration: 0.1) { expectation.fulfill() }
        sut.deactivate()

        waitForExpectations(timeout: 0.3)
    }

    func testTimeoutDoesNotFireIfManuallyDeactivated() {
        let expectation = expectation(description: "timeout should not fire")
        expectation.isInverted = true

        sut.activate(userSessions: [])
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

        sut.activate(userSessions: [])
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

        sut.activate(userSessions: [])
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
        sut.activate(userSessions: sessions.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        })

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
            sut.activate(userSessions: sessions.map {
                userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
            })
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

        let userSessions = [older, newer].map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }
        sut.activate(userSessions: userSessions)

        XCTAssertEqual(
            sut.frozenSessionIdentities,
            userSessions.map(\.identity)
        )
    }
}
