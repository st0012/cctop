import XCTest
@testable import CctopMenubar

final class FloatingPanelMouseEventTests: XCTestCase {
    func testPrimesKeyWindowForInactiveBodyMouseDown() {
        XCTAssertTrue(
            FloatingPanel.shouldPrimeKeyWindowBeforeMouseDown(
                isKeyWindow: false,
                isHeaderClick: false
            )
        )
    }

    func testDoesNotPrimeKeyWindowForAlreadyKeyPanel() {
        XCTAssertFalse(
            FloatingPanel.shouldPrimeKeyWindowBeforeMouseDown(
                isKeyWindow: true,
                isHeaderClick: false
            )
        )
    }

    func testDoesNotPrimeKeyWindowForHeaderMouseDown() {
        XCTAssertFalse(
            FloatingPanel.shouldPrimeKeyWindowBeforeMouseDown(
                isKeyWindow: false,
                isHeaderClick: true
            )
        )
    }
}
