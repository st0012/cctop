import XCTest
@testable import CctopMenubar

final class StatusCountsTests: XCTestCase {
    func testTotal() {
        let counts = StatusCounts(permission: 1, attention: 2, working: 3, idle: 4)
        XCTAssertEqual(counts.total, 10)
    }

    func testNeedsAction() {
        let counts = StatusCounts(permission: 2, attention: 3, working: 0, idle: 0)
        XCTAssertEqual(counts.needsAction, 5)
    }

    func testNeedsActionZero() {
        let counts = StatusCounts(permission: 0, attention: 0, working: 5, idle: 2)
        XCTAssertEqual(counts.needsAction, 0)
    }

    // MARK: - Accessibility label

    func testAccessibilityLabel_noSessions() {
        let counts = StatusCounts(permission: 0, attention: 0, working: 0, idle: 0)
        XCTAssertEqual(counts.accessibilityLabel, "cctop, no sessions")
    }

    func testAccessibilityLabel_allCategories() {
        let counts = StatusCounts(permission: 1, attention: 2, working: 3, idle: 4)
        XCTAssertEqual(
            counts.accessibilityLabel,
            "cctop, 1 need permission, 2 need attention, 3 working, 4 idle"
        )
    }

    func testAccessibilityLabel_workingOnly() {
        let counts = StatusCounts(permission: 0, attention: 0, working: 5, idle: 0)
        XCTAssertEqual(counts.accessibilityLabel, "cctop, 5 working")
    }

    func testAccessibilityLabel_permissionAndIdle() {
        let counts = StatusCounts(permission: 1, attention: 0, working: 0, idle: 2)
        XCTAssertEqual(counts.accessibilityLabel, "cctop, 1 need permission, 2 idle")
    }
}
