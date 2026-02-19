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

    // MARK: - isCompact derived property

    func testIsCompactTrueOnlyWhenCompactAndNotExpanded() {
        XCTAssertFalse(sut.isCompact)
        sut.compactMode = true
        XCTAssertTrue(sut.isCompact)
        sut.isExpanded = true
        XCTAssertFalse(sut.isCompact)
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

    // MARK: - syncVisualState

    func testSyncVisualStateHidden() {
        sut.isExpanded = true
        sut.syncVisualState(.hidden)
        XCTAssertFalse(sut.isExpanded)
    }

    func testSyncVisualStateNormal() {
        sut.isExpanded = true
        sut.syncVisualState(.normal)
        XCTAssertFalse(sut.isExpanded)
    }

    func testSyncVisualStateCompactCollapsed() {
        sut.compactMode = true
        sut.syncVisualState(.compactCollapsed)
        XCTAssertFalse(sut.isExpanded)
        XCTAssertTrue(sut.isCompact)
    }

    func testSyncVisualStateCompactExpanded() {
        sut.compactMode = true
        sut.syncVisualState(.compactExpanded)
        XCTAssertTrue(sut.isExpanded)
        XCTAssertFalse(sut.isCompact)
    }

    func testSyncVisualStateRefocusWasCompact() {
        sut.compactMode = true
        let origin = RefocusOrigin(panelWasClosed: false, wasCompact: true)
        sut.syncVisualState(.refocus(origin: origin))
        XCTAssertTrue(sut.isExpanded)
    }

    func testSyncVisualStateRefocusWasNotCompact() {
        sut.isExpanded = true
        let origin = RefocusOrigin(panelWasClosed: false, wasCompact: false)
        sut.syncVisualState(.refocus(origin: origin))
        XCTAssertFalse(sut.isExpanded)
    }

    func testSyncVisualStateDoesNotTouchCompactMode() {
        sut.compactMode = true
        sut.syncVisualState(.hidden)
        XCTAssertTrue(sut.compactMode, "syncVisualState should not change compactMode")
    }
}
