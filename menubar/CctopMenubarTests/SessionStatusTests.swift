import XCTest
@testable import CctopMenubar

final class SessionStatusTests: XCTestCase {
    func testKnownStatusDecoding() throws {
        let json = "\"working\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .working)
    }

    func testUnknownStatusFallsBackToNeedsAttention() throws {
        let json = "\"waiting_future\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .needsAttention)
    }

    func testUnknownNonWaitingStatusFallsBackToWorking() throws {
        let json = "\"some_future_status\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .working)
    }

    func testSnakeCaseDecoding() throws {
        let json = "\"waiting_permission\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .waitingPermission)
    }

    func testCompactingDecoding() throws {
        let json = "\"compacting\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .compacting)
    }

    func testCompactingNotNeedsAttention() {
        XCTAssertFalse(SessionStatus.compacting.needsAttention)
    }

    func testNeedsAttentionFlag() {
        XCTAssertTrue(SessionStatus.waitingPermission.needsAttention)
        XCTAssertTrue(SessionStatus.waitingInput.needsAttention)
        XCTAssertTrue(SessionStatus.needsAttention.needsAttention)
        XCTAssertFalse(SessionStatus.working.needsAttention)
        XCTAssertFalse(SessionStatus.idle.needsAttention)
        XCTAssertFalse(SessionStatus.compacting.needsAttention)
    }

    func testSortOrder() {
        XCTAssertLessThan(SessionStatus.waitingPermission.sortOrder, SessionStatus.working.sortOrder)
        XCTAssertLessThan(SessionStatus.working.sortOrder, SessionStatus.compacting.sortOrder)
        XCTAssertLessThan(SessionStatus.compacting.sortOrder, SessionStatus.idle.sortOrder)
    }
}
