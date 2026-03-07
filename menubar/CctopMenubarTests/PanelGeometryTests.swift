import XCTest
@testable import CctopMenubar

final class PanelGeometryTests: XCTestCase {

    // MARK: - frameUnderIcon

    func testFrameUnderIconCentersHorizontally() {
        let iconFrame = NSRect(x: 900, y: 800, width: 40, height: 22)
        let result = PanelGeometry.frameUnderIcon(
            iconFrame: iconFrame, panelSize: NSSize(width: 100, height: 300))

        // Panel midX should equal icon midX (920)
        XCTAssertEqual(result.midX, iconFrame.midX, accuracy: 0.1)
    }

    func testFrameUnderIconPositionsBelowIcon() {
        let iconFrame = NSRect(x: 900, y: 800, width: 40, height: 22)
        let result = PanelGeometry.frameUnderIcon(
            iconFrame: iconFrame, panelSize: NSSize(width: 100, height: 300))

        // Panel top (maxY) should be just below icon bottom (minY) minus gap
        XCTAssertEqual(result.maxY, iconFrame.minY - 4, accuracy: 0.1)
    }

    func testFrameUnderIconUsesExactPanelSize() {
        let iconFrame = NSRect(x: 900, y: 800, width: 40, height: 22)
        let size = NSSize(width: 80, height: 16)
        let result = PanelGeometry.frameUnderIcon(
            iconFrame: iconFrame, panelSize: size)

        XCTAssertEqual(result.width, 80, accuracy: 0.1)
        XCTAssertEqual(result.height, 16, accuracy: 0.1)
    }

    // MARK: - frameResizedInPlace

    func testResizeInPlacePreservesCenterX() {
        let oldFrame = NSRect(x: 100, y: 500, width: 320, height: 400)
        let result = PanelGeometry.frameResizedInPlace(
            oldFrame: oldFrame, newSize: NSSize(width: 80, height: 16))

        // Center X should be preserved (100 + 320/2 = 260)
        XCTAssertEqual(result.midX, oldFrame.midX, accuracy: 0.1)
    }

    func testResizeInPlacePreservesTopEdge() {
        let oldFrame = NSRect(x: 100, y: 500, width: 320, height: 400)
        let result = PanelGeometry.frameResizedInPlace(
            oldFrame: oldFrame, newSize: NSSize(width: 80, height: 16))

        // Top edge (maxY) should be preserved (500 + 400 = 900)
        XCTAssertEqual(result.maxY, oldFrame.maxY, accuracy: 0.1)
    }

    func testResizeInPlaceDoesNotFollowIcon() {
        // Simulate: panel is at one position, icon is elsewhere.
        // resizeInPlace should NOT care about the icon position.
        let oldFrame = NSRect(x: 100, y: 500, width: 320, height: 400)
        let result = PanelGeometry.frameResizedInPlace(
            oldFrame: oldFrame, newSize: NSSize(width: 320, height: 350))

        // midX and maxY must stay the same — panel doesn't jump to icon
        XCTAssertEqual(result.midX, oldFrame.midX, accuracy: 0.1)
        XCTAssertEqual(result.maxY, oldFrame.maxY, accuracy: 0.1)
        XCTAssertEqual(result.width, 320, accuracy: 0.1)
        XCTAssertEqual(result.height, 350, accuracy: 0.1)
    }

    func testResizeInPlaceWidthChangeStaysCentered() {
        // Shrink from 320 to 80 — panel should stay centered at the same midX
        let oldFrame = NSRect(x: 100, y: 500, width: 320, height: 400)
        let result = PanelGeometry.frameResizedInPlace(
            oldFrame: oldFrame, newSize: NSSize(width: 80, height: 400))

        XCTAssertEqual(result.midX, oldFrame.midX, accuracy: 0.1)
        XCTAssertEqual(result.width, 80, accuracy: 0.1)
        // x should shift right to keep center: 260 - 40 = 220
        XCTAssertEqual(result.origin.x, 220, accuracy: 0.1)
    }

    // MARK: - The two functions produce different results

    func testResizeVsPositionProduceDifferentFrames() {
        // Panel is NOT centered under icon
        let iconFrame = NSRect(x: 900, y: 800, width: 40, height: 22)
        let oldFrame = NSRect(x: 100, y: 500, width: 320, height: 400)
        let size = NSSize(width: 320, height: 400)

        let positioned = PanelGeometry.frameUnderIcon(
            iconFrame: iconFrame, panelSize: size)
        let resized = PanelGeometry.frameResizedInPlace(
            oldFrame: oldFrame, newSize: size)

        // They should produce different positions
        XCTAssertNotEqual(positioned.origin.x, resized.origin.x)
        XCTAssertNotEqual(positioned.origin.y, resized.origin.y)
    }
}
