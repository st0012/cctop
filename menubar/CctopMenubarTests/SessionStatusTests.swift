import XCTest
@testable import CctopMenubar

final class SessionStatusTests: XCTestCase {
    func testKnownStatusDecoding() throws {
        let json = "\"working\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .working)
    }

    func testUnknownStatusFallsBackToNeedsAttention() throws {
        let json = "\"some_future_status\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .needsAttention)
    }

    func testSnakeCaseDecoding() throws {
        let json = "\"waiting_permission\""
        let status = try JSONDecoder().decode(SessionStatus.self, from: Data(json.utf8))
        XCTAssertEqual(status, .waitingPermission)
    }

    func testNeedsAttentionFlag() {
        XCTAssertTrue(SessionStatus.waitingPermission.needsAttention)
        XCTAssertTrue(SessionStatus.waitingInput.needsAttention)
        XCTAssertTrue(SessionStatus.needsAttention.needsAttention)
        XCTAssertFalse(SessionStatus.working.needsAttention)
        XCTAssertFalse(SessionStatus.idle.needsAttention)
    }

    func testSortOrder() {
        XCTAssertLessThan(SessionStatus.waitingPermission.sortOrder, SessionStatus.working.sortOrder)
        XCTAssertLessThan(SessionStatus.working.sortOrder, SessionStatus.idle.sortOrder)
    }
}
