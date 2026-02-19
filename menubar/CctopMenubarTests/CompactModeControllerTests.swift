import XCTest
@testable import CctopMenubar

final class CompactModeControllerTests: XCTestCase {
    private var sut: CompactModeController!

    override func setUp() {
        super.setUp()
        sut = CompactModeController()
        UserDefaults.standard.removeObject(forKey: "compactMode")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "compactMode")
        sut = nil
        super.tearDown()
    }

    // MARK: - Initial state

    func testInitialStateIsNotCompact() {
        XCTAssertFalse(sut.compactMode)
        XCTAssertFalse(sut.isExpanded)
        XCTAssertFalse(sut.isCompact)
    }

    // MARK: - Toggle

    func testToggleEnablesCompactMode() {
        sut.toggle()
        XCTAssertTrue(sut.compactMode)
        XCTAssertTrue(sut.isCompact)
    }

    func testToggleResetsExpanded() {
        sut.compactMode = true
        sut.isExpanded = true
        sut.toggle() // toggles OFF
        XCTAssertFalse(sut.compactMode)
        XCTAssertFalse(sut.isExpanded)
    }

    func testToggleOnWhileExpandedCollapsesFirst() {
        sut.isExpanded = true
        sut.toggle()
        XCTAssertTrue(sut.compactMode)
        XCTAssertFalse(sut.isExpanded)
        XCTAssertTrue(sut.isCompact)
    }

    // MARK: - Expand

    func testExpandWhenCompact() {
        sut.compactMode = true
        sut.expand()
        XCTAssertTrue(sut.isExpanded)
        XCTAssertFalse(sut.isCompact)
    }

    func testExpandWhenNotCompactIsNoOp() {
        sut.expand()
        XCTAssertFalse(sut.isExpanded)
    }

    func testExpandWhenAlreadyExpandedIsNoOp() {
        sut.compactMode = true
        sut.isExpanded = true
        sut.expand()
        XCTAssertTrue(sut.isExpanded)
    }

    // MARK: - Collapse

    func testCollapseWhenExpanded() {
        sut.compactMode = true
        sut.isExpanded = true
        sut.collapse()
        XCTAssertFalse(sut.isExpanded)
        XCTAssertTrue(sut.isCompact)
    }

    func testCollapseWhenNotExpandedIsNoOp() {
        sut.compactMode = true
        sut.collapse()
        XCTAssertFalse(sut.isExpanded)
    }

    func testCollapseWhenNotCompactIsNoOp() {
        sut.isExpanded = false
        sut.collapse()
        XCTAssertFalse(sut.isExpanded)
    }

    // MARK: - isCompact derived property

    func testIsCompactTrueOnlyWhenCompactAndNotExpanded() {
        XCTAssertFalse(sut.isCompact)
        sut.compactMode = true
        XCTAssertTrue(sut.isCompact)
        sut.isExpanded = true
        XCTAssertFalse(sut.isCompact)
    }

    // MARK: - Full cycle

    func testFullToggleExpandCollapseCycle() {
        sut.toggle()
        XCTAssertTrue(sut.isCompact)

        sut.expand()
        XCTAssertFalse(sut.isCompact)

        sut.collapse()
        XCTAssertTrue(sut.isCompact)

        sut.toggle()
        XCTAssertFalse(sut.isCompact)
        XCTAssertFalse(sut.compactMode)
    }

    // MARK: - HeaderView statusCounts

    func testStatusCountsPermissionSeparately() {
        let sessions: [Session] = [
            .mock(status: .waitingPermission),
            .mock(id: "2", status: .waitingInput),
            .mock(id: "3", status: .needsAttention),
            .mock(id: "4", status: .working),
            .mock(id: "5", status: .idle),
        ]
        let counts = HeaderView.statusCounts(for: sessions)
        XCTAssertEqual(counts.permission, 1)
        XCTAssertEqual(counts.attention, 2)
        XCTAssertEqual(counts.working, 1)
        XCTAssertEqual(counts.idle, 1)
    }

    func testStatusCountsCompactingAsWorking() {
        let sessions: [Session] = [
            .mock(status: .compacting),
            .mock(id: "2", status: .working),
        ]
        let counts = HeaderView.statusCounts(for: sessions)
        XCTAssertEqual(counts.working, 2)
    }

    func testStatusCountsEmptySessions() {
        let counts = HeaderView.statusCounts(for: [])
        XCTAssertEqual(counts.permission, 0)
        XCTAssertEqual(counts.attention, 0)
        XCTAssertEqual(counts.working, 0)
        XCTAssertEqual(counts.idle, 0)
    }

    func testStatusCountsAllPermission() {
        let sessions: [Session] = [
            .mock(status: .waitingPermission),
            .mock(id: "2", status: .waitingPermission),
            .mock(id: "3", status: .waitingPermission),
        ]
        let counts = HeaderView.statusCounts(for: sessions)
        XCTAssertEqual(counts.permission, 3)
        XCTAssertEqual(counts.attention, 0)
    }

    // MARK: - Regression: toggle while expanded disables compact mode entirely

    func testToggleWhileExpandedDisablesCompactMode() {
        let ctrl = CompactModeController()
        ctrl.compactMode = true
        ctrl.expand()
        XCTAssertTrue(ctrl.isExpanded)
        ctrl.toggle()
        XCTAssertFalse(ctrl.compactMode)
        XCTAssertFalse(ctrl.isExpanded)
        XCTAssertFalse(ctrl.isCompact)
    }
}
