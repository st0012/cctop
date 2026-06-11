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
        XCTAssertEqual(counts.barSegments[0].kind, .permission)
        XCTAssertEqual(counts.barSegments[0].proportion, 0.5, accuracy: 0.001)
        XCTAssertEqual(counts.barSegments[1].kind, .attention)
        XCTAssertEqual(counts.barSegments[1].proportion, 0.5, accuracy: 0.001)
    }

    func testBarSegments_attentionOnlyUsesAttentionKind() {
        let counts = StatusCounts(permission: 0, attention: 2, working: 0, idle: 0)
        XCTAssertEqual(counts.barSegments.count, 1)
        XCTAssertEqual(counts.barSegments[0].kind, .attention)
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
        XCTAssertEqual(counts.barSegments[0].kind, .permission)
        XCTAssertEqual(counts.barSegments[1].kind, .attention)
        XCTAssertEqual(counts.barSegments[2].kind, .working)
        XCTAssertEqual(counts.barSegments[3].kind, .idle)
    }

    func testBarSegments_attentionFirstWhenNoPermission() {
        let counts = StatusCounts(permission: 0, attention: 1, working: 2, idle: 1)
        XCTAssertEqual(counts.barSegments.count, 3)
        XCTAssertEqual(counts.barSegments[0].kind, .attention)
        XCTAssertEqual(counts.barSegments[1].kind, .working)
        XCTAssertEqual(counts.barSegments[2].kind, .idle)
    }

    func testBarSegments_allAttention_singleSegment() {
        let counts = StatusCounts(permission: 0, attention: 5, working: 0, idle: 0)
        XCTAssertEqual(counts.barSegments.count, 1)
        XCTAssertEqual(counts.barSegments[0].proportion, 1.0, accuracy: 0.001)
        XCTAssertEqual(counts.barSegments[0].kind, .attention)
    }

    func testBarSegments_proportionsSumToOne() {
        let counts = StatusCounts(permission: 2, attention: 3, working: 10, idle: 5)
        let sum = counts.barSegments.map(\.proportion).reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    // MARK: - Bar segments with minimum width enforcement

    func testBarSegmentsForWidth_noClampingNeeded() {
        // 5 attention out of 10 = 50% — well above 4pt/22pt ≈ 18%
        let counts = StatusCounts(permission: 0, attention: 5, working: 5, idle: 0)
        let raw = counts.barSegments
        let clamped = counts.barSegments(forWidth: 22)
        XCTAssertEqual(raw.count, clamped.count)
        for i in 0..<raw.count {
            XCTAssertEqual(raw[i].proportion, clamped[i].proportion, accuracy: 0.001)
        }
    }

    func testBarSegmentsForWidth_clampsSmallActionSegment() {
        // 1 attention out of 10 = 10% of 22pt = 2.2pt, below 5pt minimum
        let counts = StatusCounts(permission: 0, attention: 1, working: 5, idle: 4)
        let segs = counts.barSegments(forWidth: 22)
        let attentionSeg = segs.first { $0.kind == .attention }!
        XCTAssertEqual(attentionSeg.proportion, 5.0 / 22.0, accuracy: 0.001)
    }

    func testBarSegmentsForWidth_stealsFromNonActionProportionally() {
        // 1 attention, 8 working, 1 idle = attention is 10% → clamped to 4/22 ≈ 18.2%
        let counts = StatusCounts(permission: 0, attention: 1, working: 8, idle: 1)
        let segs = counts.barSegments(forWidth: 22)
        let sum = segs.map(\.proportion).reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testBarSegmentsForWidth_proportionsSumToOne() {
        let counts = StatusCounts(permission: 1, attention: 1, working: 15, idle: 3)
        let segs = counts.barSegments(forWidth: 36)
        let sum = segs.map(\.proportion).reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testBarSegmentsForWidth_skipsEnforcementWhenActionExceeds80Percent() {
        // 9 permission, 1 working — action segments are 90%, skip clamping
        let counts = StatusCounts(permission: 9, attention: 0, working: 1, idle: 0)
        let raw = counts.barSegments
        let clamped = counts.barSegments(forWidth: 22)
        for i in 0..<raw.count {
            XCTAssertEqual(raw[i].proportion, clamped[i].proportion, accuracy: 0.001)
        }
    }

    func testBarSegmentsForWidth_emptyReturnsEmpty() {
        let counts = StatusCounts(permission: 0, attention: 0, working: 0, idle: 0)
        XCTAssertTrue(counts.barSegments(forWidth: 22).isEmpty)
    }

    func testBarSegmentsForWidth_zeroWidthReturnsRaw() {
        let counts = StatusCounts(permission: 1, attention: 0, working: 5, idle: 0)
        let raw = counts.barSegments
        let result = counts.barSegments(forWidth: 0)
        XCTAssertEqual(raw.count, result.count)
    }

    func testBarSegmentsForWidth_bothActionSegmentsClamped() {
        // 1 permission + 1 attention + 18 working = both action at 5% of 22pt = 1.1pt
        let counts = StatusCounts(permission: 1, attention: 1, working: 18, idle: 0)
        let segs = counts.barSegments(forWidth: 22)
        let permSeg = segs.first { $0.kind == .permission }!
        let attnSeg = segs.first { $0.kind == .attention }!
        XCTAssertEqual(permSeg.proportion, 5.0 / 22.0, accuracy: 0.001)
        XCTAssertEqual(attnSeg.proportion, 5.0 / 22.0, accuracy: 0.001)
        let sum = segs.map(\.proportion).reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testBarSegmentsForWidth_allActionNoNonAction() {
        // 5 permission + 5 attention = 100% action, no working/idle to shrink
        let counts = StatusCounts(permission: 5, attention: 5, working: 0, idle: 0)
        let segs = counts.barSegments(forWidth: 22)
        let sum = segs.map(\.proportion).reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testBarSegmentsForWidth_extremeRatio() {
        // 1 permission + 99 working at 100pt bar
        let counts = StatusCounts(permission: 1, attention: 0, working: 99, idle: 0)
        let segs = counts.barSegments(forWidth: 100)
        let permSeg = segs.first { $0.kind == .permission }!
        XCTAssertEqual(permSeg.proportion, 5.0 / 100.0, accuracy: 0.001)
        let sum = segs.map(\.proportion).reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testBarSegmentsForWidth_verySmallBarWidth() {
        // Bar narrower than minActionWidth (5pt) — should skip enforcement gracefully
        let counts = StatusCounts(permission: 1, attention: 0, working: 5, idle: 0)
        let segs = counts.barSegments(forWidth: 2)
        let sum = segs.map(\.proportion).reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testBarSegmentsForWidth_at80PercentBoundary() {
        // 4 permission + 1 working on 10pt bar: 4/5 = 80% action, clamped stays 80%
        // Should still enforce (guard is <= 0.8)
        let counts = StatusCounts(permission: 4, attention: 0, working: 1, idle: 0)
        let segs = counts.barSegments(forWidth: 10)
        let sum = segs.map(\.proportion).reduce(0, +)
        XCTAssertEqual(sum, 1.0, accuracy: 0.001)
    }

    func testBarSegmentsForWidth_sumNeverExceedsOne() {
        // Test across multiple bar widths
        for barWidth in [20.0, 22.0, 36.0, 44.0, 100.0] {
            let counts = StatusCounts(permission: 1, attention: 1, working: 7, idle: 1)
            let segs = counts.barSegments(forWidth: barWidth)
            let sum = segs.map(\.proportion).reduce(0, +)
            XCTAssertLessThanOrEqual(sum, 1.0 + 1e-9, "Sum exceeded 1.0 at \(barWidth)pt")
            XCTAssertGreaterThanOrEqual(sum, 1.0 - 1e-9, "Sum below 1.0 at \(barWidth)pt")
        }
    }

    // MARK: - Segment kind to rendered color

    /// Pins the kind-to-color resolution both renderers rely on. The four
    /// theme colors are distinct in every theme, so a transposed case in
    /// `StatusColors.color(for:)` fails here instead of shipping wrong
    /// menubar/notch colors.
    @MainActor
    func testStatusColorsResolveEachSegmentKind() {
        XCTAssertEqual(StatusColors.color(for: .permission), StatusColors.permission)
        XCTAssertEqual(StatusColors.color(for: .attention), StatusColors.attention)
        XCTAssertEqual(StatusColors.color(for: .working), StatusColors.working)
        XCTAssertEqual(StatusColors.color(for: .idle), StatusColors.idle)
        XCTAssertNotEqual(StatusColors.permission, StatusColors.attention)
    }
}
