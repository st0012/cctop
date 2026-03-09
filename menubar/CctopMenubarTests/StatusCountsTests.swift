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

    // MARK: - Equatable

    func testEquatable_sameValues() {
        let lhs = StatusCounts(permission: 1, attention: 2, working: 3, idle: 4)
        let rhs = StatusCounts(permission: 1, attention: 2, working: 3, idle: 4)
        XCTAssertEqual(lhs, rhs)
    }

    func testEquatable_differentValues() {
        let lhs = StatusCounts(permission: 1, attention: 2, working: 3, idle: 4)
        let rhs = StatusCounts(permission: 1, attention: 2, working: 3, idle: 5)
        XCTAssertNotEqual(lhs, rhs)
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
            "cctop, 1 needs permission, 2 need attention, 3 working, 4 idle"
        )
    }

    func testAccessibilityLabel_workingOnly() {
        let counts = StatusCounts(permission: 0, attention: 0, working: 5, idle: 0)
        XCTAssertEqual(counts.accessibilityLabel, "cctop, 5 working")
    }

    func testAccessibilityLabel_permissionAndIdle() {
        let counts = StatusCounts(permission: 1, attention: 0, working: 0, idle: 2)
        XCTAssertEqual(counts.accessibilityLabel, "cctop, 1 needs permission, 2 idle")
    }

    func testAccessibilityLabel_pluralPermissionAndAttention() {
        let counts = StatusCounts(permission: 3, attention: 1, working: 0, idle: 0)
        XCTAssertEqual(
            counts.accessibilityLabel,
            "cctop, 3 need permission, 1 needs attention"
        )
    }

    // MARK: - Bar segments

    func testBarSegments_empty() {
        let counts = StatusCounts(permission: 0, attention: 0, working: 0, idle: 0)
        XCTAssertTrue(counts.barSegments.isEmpty)
    }

    func testBarSegments_permissionAndAttentionSeparate() {
        let counts = StatusCounts(permission: 1, attention: 1, working: 0, idle: 0)
        XCTAssertEqual(counts.barSegments.count, 2)
        XCTAssertEqual(counts.barSegments[0].color, StatusColors.permission)
        XCTAssertEqual(counts.barSegments[0].proportion, 0.5, accuracy: 0.001)
        XCTAssertEqual(counts.barSegments[1].color, StatusColors.attention)
        XCTAssertEqual(counts.barSegments[1].proportion, 0.5, accuracy: 0.001)
    }

    func testBarSegments_attentionOnlyUsesAttentionColor() {
        let counts = StatusCounts(permission: 0, attention: 2, working: 0, idle: 0)
        XCTAssertEqual(counts.barSegments.count, 1)
        XCTAssertEqual(counts.barSegments[0].color, StatusColors.attention)
        XCTAssertEqual(counts.barSegments[0].proportion, 1.0, accuracy: 0.001)
    }

    func testBarSegments_proportions() {
        let counts = StatusCounts(permission: 0, attention: 0, working: 3, idle: 1)
        XCTAssertEqual(counts.barSegments.count, 2)
        XCTAssertEqual(counts.barSegments[0].proportion, 0.75, accuracy: 0.001)
        XCTAssertEqual(counts.barSegments[1].proportion, 0.25, accuracy: 0.001)
    }

    func testBarSegments_order_permissionAttentionWorkingIdle() {
        let counts = StatusCounts(permission: 1, attention: 1, working: 1, idle: 1)
        XCTAssertEqual(counts.barSegments.count, 4)
        XCTAssertEqual(counts.barSegments[0].color, StatusColors.permission)
        XCTAssertEqual(counts.barSegments[1].color, StatusColors.attention)
        XCTAssertEqual(counts.barSegments[2].color, StatusColors.working)
        XCTAssertEqual(counts.barSegments[3].color, StatusColors.idle)
    }

    func testBarSegments_attentionFirstWhenNoPermission() {
        let counts = StatusCounts(permission: 0, attention: 1, working: 2, idle: 1)
        XCTAssertEqual(counts.barSegments.count, 3)
        XCTAssertEqual(counts.barSegments[0].color, StatusColors.attention)
        XCTAssertEqual(counts.barSegments[1].color, StatusColors.working)
        XCTAssertEqual(counts.barSegments[2].color, StatusColors.idle)
    }

    func testBarSegments_allAttention_singleSegment() {
        let counts = StatusCounts(permission: 0, attention: 5, working: 0, idle: 0)
        XCTAssertEqual(counts.barSegments.count, 1)
        XCTAssertEqual(counts.barSegments[0].proportion, 1.0, accuracy: 0.001)
        XCTAssertEqual(counts.barSegments[0].color, StatusColors.attention)
    }

    func testBarSegments_proportionsSumToOne() {
        let counts = StatusCounts(permission: 2, attention: 3, working: 10, idle: 5)
        let sum = counts.barSegments.map(\.proportion).reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }
}
