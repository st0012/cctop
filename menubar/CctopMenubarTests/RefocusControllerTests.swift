import XCTest
@testable import CctopMenubar

final class RefocusControllerTests: XCTestCase {
    private var sut: RefocusController!

    override func setUp() {
        super.setUp()
        sut = RefocusController()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialState() {
        XCTAssertFalse(sut.isActive)
        XCTAssertTrue(sut.frozenSessions.isEmpty)
        XCTAssertNil(sut.previousApp)
        XCTAssertFalse(sut.panelWasClosedBeforeRefocus)
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

    func testActivateSortsSessions() {
        var idle = Session.mock(id: "1", project: "alpha", status: .idle)
        idle.lastActivity = Date().addingTimeInterval(-60)
        let working = Session.mock(id: "2", project: "beta", status: .working)

        sut.activate(sessions: [idle, working])

        // Working sessions sort before idle
        XCTAssertEqual(sut.frozenSessions[0].projectName, "beta")
        XCTAssertEqual(sut.frozenSessions[1].projectName, "alpha")
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

    // MARK: - Panel state tracking

    func testPanelWasClosedBeforeRefocusDefaultsFalse() {
        XCTAssertFalse(sut.panelWasClosedBeforeRefocus)
    }

    func testPanelWasClosedBeforeRefocusTracksState() {
        sut.activate(sessions: [], previousApp: nil, panelWasClosed: true)
        XCTAssertTrue(sut.panelWasClosedBeforeRefocus)
    }

    // MARK: - Activate → Deactivate cycle

    func testFullActivateDeactivateCycle() {
        let sessions = [
            Session.mock(id: "1", status: .working),
            Session.mock(id: "2", status: .idle),
        ]

        // Activate
        sut.activate(sessions: sessions, previousApp: nil, panelWasClosed: true)

        XCTAssertTrue(sut.isActive)
        XCTAssertEqual(sut.frozenSessions.count, 2)
        XCTAssertTrue(sut.panelWasClosedBeforeRefocus)

        // Deactivate resets all state
        let state = sut.deactivate()

        XCTAssertFalse(sut.isActive)
        XCTAssertTrue(sut.frozenSessions.isEmpty)
        XCTAssertFalse(sut.panelWasClosedBeforeRefocus)
        XCTAssertNil(sut.previousApp)
        // Returned state preserves pre-deactivation values
        XCTAssertTrue(state.panelWasClosed)
        XCTAssertNil(state.previousApp)
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

    // MARK: - Sort order in frozen sessions

    func testFrozenSessionsSortAttentionBeforeWorking() {
        var idle = Session.mock(id: "1", status: .idle)
        idle.lastActivity = Date().addingTimeInterval(-60)
        let attention = Session.mock(id: "2", status: .waitingPermission)
        let working = Session.mock(id: "3", status: .working)

        sut.activate(sessions: [idle, attention, working])

        XCTAssertEqual(sut.frozenSessions[0].status, .waitingPermission)
        XCTAssertEqual(sut.frozenSessions[1].status, .working)
        XCTAssertEqual(sut.frozenSessions[2].status, .idle)
    }

    func testFrozenSessionsSortByRecencyWithinSameStatus() {
        var older = Session.mock(id: "1", project: "older", status: .working)
        older.lastActivity = Date().addingTimeInterval(-120)
        var newer = Session.mock(id: "2", project: "newer", status: .working)
        newer.lastActivity = Date()

        sut.activate(sessions: [older, newer])

        XCTAssertEqual(sut.frozenSessions[0].projectName, "newer")
        XCTAssertEqual(sut.frozenSessions[1].projectName, "older")
    }
}
