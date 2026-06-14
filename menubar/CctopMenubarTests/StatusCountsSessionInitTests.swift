import XCTest
@testable import CctopMenubar

final class StatusCountsSessionInitTests: XCTestCase {
    func testEmptyArray_returnsZero() {
        let counts = StatusCounts(sessions: [])
        XCTAssertEqual(counts.total, 0)
    }

    func testIdle_countsAsIdle() {
        let sessions = [Session.mock(status: .idle)]
        let counts = StatusCounts(sessions: sessions)
        XCTAssertEqual(counts.idle, 1)
        XCTAssertEqual(counts.working, 0)
    }

    func testFreshActiveIdle_countsAsIdle() {
        let now = Date()
        var session = Session.mock(status: .idle)
        session.lifecycle = .active
        session.lastActivity = now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval + 60)

        let counts = StatusCounts(sessions: [session], now: now)

        XCTAssertEqual(counts.idle, 1)
        XCTAssertEqual(counts.total, 1)
    }

    func testStaleActiveIdle_isExcludedFromCounts() {
        let now = Date()
        var session = Session.mock(status: .idle)
        session.lifecycle = .active
        session.lastActivity = now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)

        let counts = StatusCounts(sessions: [session], now: now)

        XCTAssertEqual(counts.idle, 0)
        XCTAssertEqual(counts.total, 0)
    }

    func testDormantSession_isExcludedFromCounts() {
        var session = Session.mock(status: .waitingPermission)
        session.lifecycle = .dormant

        let counts = StatusCounts(sessions: [session])

        XCTAssertEqual(counts.permission, 0)
        XCTAssertEqual(counts.total, 0)
    }

    func testWorking_countsAsWorking() {
        let sessions = [Session.mock(status: .working)]
        let counts = StatusCounts(sessions: sessions)
        XCTAssertEqual(counts.working, 1)
    }

    func testCompacting_countsAsWorking() {
        let sessions = [Session.mock(status: .compacting)]
        let counts = StatusCounts(sessions: sessions)
        XCTAssertEqual(counts.working, 1)
    }

    func testWaitingPermission_countsAsPermission() {
        let sessions = [Session.mock(status: .waitingPermission)]
        let counts = StatusCounts(sessions: sessions)
        XCTAssertEqual(counts.permission, 1)
    }

    func testWaitingInput_countsAsAttention() {
        let sessions = [Session.mock(status: .waitingInput)]
        let counts = StatusCounts(sessions: sessions)
        XCTAssertEqual(counts.attention, 1)
    }

    func testNeedsAttention_countsAsAttention() {
        let sessions = [Session.mock(status: .needsAttention)]
        let counts = StatusCounts(sessions: sessions)
        XCTAssertEqual(counts.attention, 1)
    }

    func testMixedStatuses_aggregatesCorrectly() {
        let sessions = [
            Session.mock(id: "1", status: .idle),
            Session.mock(id: "2", status: .idle),
            Session.mock(id: "3", status: .working),
            Session.mock(id: "4", status: .compacting),
            Session.mock(id: "5", status: .waitingPermission),
            Session.mock(id: "6", status: .waitingInput),
            Session.mock(id: "7", status: .needsAttention),
        ]
        let counts = StatusCounts(sessions: sessions)
        XCTAssertEqual(counts.idle, 2)
        XCTAssertEqual(counts.working, 2)  // working + compacting
        XCTAssertEqual(counts.permission, 1)
        XCTAssertEqual(counts.attention, 2)  // waitingInput + needsAttention
        XCTAssertEqual(counts.total, 7)
        XCTAssertEqual(counts.needsAction, 3)  // permission + attention
    }
}
