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
        XCTAssertTrue(sut.frozenSessions.isEmpty)
    }

    // MARK: - Activate

    func testActivateSetsIsActive() {
        sut.activate(sessions: [])
        XCTAssertTrue(sut.isActive)
    }

    func testActivateFreezesSessions() {
        let sessions = [
            Session.mock(id: "1", project: "alpha", status: .idle),
            Session.mock(id: "2", project: "beta", status: .working),
        ]
        sut.activate(sessions: sessions)
        XCTAssertEqual(sut.frozenSessions.count, 2)
    }

    func testActivatePreservesCanonicalSessionOrder() {
        let now = Date()
        let waiting = Session.mock(id: "1", project: "alpha", status: .waitingInput)
        var workingOld = Session.mock(id: "2", project: "beta", status: .working)
        workingOld.lastActivity = now.addingTimeInterval(-600)
        var workingNew = Session.mock(id: "3", project: "gamma", status: .working)
        workingNew.lastActivity = now
        let idle = Session.mock(id: "4", project: "delta", status: .idle)

        sut.activate(sessions: [waiting, workingOld, workingNew, idle])

        XCTAssertEqual(sut.frozenSessions.map(\.projectName), ["alpha", "beta", "gamma", "delta"])
    }

    func testActivateWithEmptySessions() {
        sut.activate(sessions: [])
        XCTAssertTrue(sut.isActive)
        XCTAssertTrue(sut.frozenSessions.isEmpty)
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
        XCTAssertTrue(sut.frozenSessions.isEmpty)
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
        XCTAssertTrue(sut.frozenSessions.isEmpty)
    }

    // MARK: - Frozen sessions are a snapshot

    func testFrozenSessionsAreSnapshot() {
        var sessions = [
            Session.mock(id: "1", project: "alpha", status: .working),
        ]
        sut.activate(sessions: sessions)

        // Mutating the original array shouldn't affect frozen sessions
        sessions.append(.mock(id: "2", project: "beta", status: .idle))
        XCTAssertEqual(sut.frozenSessions.count, 1)
    }

    func testRemovingHiddenSessionPreservesFrozenSurvivorOrder() {
        let hiddenSessionID = "22222222-2222-4222-8222-222222222222"
        let first = Session.mock(
            id: "first", cctopSessionId: "11111111-1111-4111-8111-111111111111",
            status: .waitingInput, source: Session.codexSource
        )
        let hidden = Session.mock(
            id: "hidden", cctopSessionId: hiddenSessionID,
            status: .working, source: Session.codexSource
        )
        let secondHiddenObservation = Session.mock(
            id: "hidden-again", cctopSessionId: hiddenSessionID,
            status: .idle, source: Session.codexSource
        )
        let last = Session.mock(
            id: "last", cctopSessionId: "33333333-3333-4333-8333-333333333333",
            status: .idle, source: Session.codexSource
        )
        sut.activate(sessions: [first, hidden, secondHiddenObservation, last])

        sut.removeSession(withCctopSessionID: hiddenSessionID)

        XCTAssertEqual(sut.frozenSessions.map(\.sessionId), ["first", "last"])
    }

    func testRemovingLastHiddenSessionPreservesActiveEmptySnapshot() {
        let hiddenSessionID = "22222222-2222-4222-8222-222222222222"
        let hidden = Session.mock(
            id: "hidden", cctopSessionId: hiddenSessionID,
            status: .working, source: Session.codexSource
        )
        sut.activate(sessions: [hidden])

        sut.removeSession(withCctopSessionID: hiddenSessionID)

        XCTAssertEqual(sut.activeSessionSnapshot, [])
        XCTAssertTrue(sut.isActive)
    }

    func testInactiveControllerHasNoActiveSnapshot() {
        XCTAssertNil(sut.activeSessionSnapshot)
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
            Session.mock(id: "1", status: .working),
            Session.mock(id: "2", status: .idle),
        ]

        // Activate
        sut.activate(sessions: sessions)

        XCTAssertTrue(sut.isActive)
        XCTAssertEqual(sut.frozenSessions.count, 2)

        // Deactivate resets all state
        sut.deactivate()

        XCTAssertFalse(sut.isActive)
        XCTAssertTrue(sut.frozenSessions.isEmpty)
    }

    func testMultipleActivateDeactivateCycles() {
        for i in 0..<3 {
            let sessions = [Session.mock(id: "\(i)", status: .working)]
            sut.activate(sessions: sessions)
            XCTAssertTrue(sut.isActive)
            XCTAssertEqual(sut.frozenSessions.count, 1)

            sut.deactivate()
            XCTAssertFalse(sut.isActive)
            XCTAssertTrue(sut.frozenSessions.isEmpty)
        }
    }

    // MARK: - Canonical order in frozen sessions

    func testFrozenSessionsPreserveOrderAcrossActivityTimes() {
        var older = Session.mock(id: "1", project: "older", status: .working)
        older.lastActivity = Date().addingTimeInterval(-120)
        var newer = Session.mock(id: "2", project: "newer", status: .working)
        newer.lastActivity = Date()

        sut.activate(sessions: [older, newer])

        XCTAssertEqual(sut.frozenSessions[0].projectName, "older")
        XCTAssertEqual(sut.frozenSessions[1].projectName, "newer")
    }
}
