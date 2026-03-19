import XCTest
@testable import CctopMenubar

final class PanelPositioningTests: XCTestCase {
    // Two-screen setup: primary (left), secondary (right)
    let primary = ScreenLayout(
        frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
        visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1055),
        key: "primary"
    )
    let secondary = ScreenLayout(
        frame: NSRect(x: 1920, y: 0, width: 1920, height: 1080),
        visibleFrame: NSRect(x: 1920, y: 0, width: 1920, height: 1055),
        key: "secondary"
    )

    var screens: [ScreenLayout] { [primary, secondary] }

    let panelSize = NSSize(width: 320, height: 400)
    let margin = PanelPositioning.margin

    // Anchor (menubar icon) near the right side of the primary screen
    let anchorOnPrimary = NSRect(x: 1870, y: 1058, width: 40, height: 22)

    // MARK: - screenIndex

    func testScreenIndexOnPrimary() {
        let idx = PanelPositioning.screenIndex(
            containing: NSPoint(x: 500, y: 500), in: screens
        )
        XCTAssertEqual(idx, 0)
    }

    func testScreenIndexOnSecondary() {
        let idx = PanelPositioning.screenIndex(
            containing: NSPoint(x: 2500, y: 500), in: screens
        )
        XCTAssertEqual(idx, 1)
    }

    func testScreenIndexOutsideAllScreens() {
        let idx = PanelPositioning.screenIndex(
            containing: NSPoint(x: -100, y: 500), in: screens
        )
        XCTAssertNil(idx)
    }

    // MARK: - clampToScreen

    func testClampKeepsPositionInsideScreen() {
        let result = PanelPositioning.clampToScreen(
            originX: 100, topY: 800,
            size: panelSize, screens: screens
        )
        XCTAssertEqual(result.originX, 100)
        XCTAssertEqual(result.topY, 800)
    }

    func testClampPullsBackFromRightEdge() {
        let result = PanelPositioning.clampToScreen(
            originX: 1700, topY: 800,
            size: panelSize, screens: screens
        )
        XCTAssertEqual(result.originX, 1920 - panelSize.width - margin)
    }

    func testClampPullsBackFromLeftEdge() {
        let result = PanelPositioning.clampToScreen(
            originX: -10, topY: 800,
            size: panelSize, screens: screens
        )
        XCTAssertEqual(result.originX, margin)
    }

    func testClampPullsBackFromTopEdge() {
        let result = PanelPositioning.clampToScreen(
            originX: 100, topY: 1200,
            size: panelSize, screens: screens
        )
        XCTAssertEqual(result.topY, primary.visibleFrame.maxY - margin)
    }

    func testClampOnSecondaryScreen() {
        let result = PanelPositioning.clampToScreen(
            originX: 3600, topY: 800,
            size: panelSize, screens: screens
        )
        XCTAssertEqual(result.originX, secondary.frame.maxX - panelSize.width - margin)
    }

    // MARK: - PR #62: resolveShowPosition — click on different screen than saved

    func testSavedPositionOnClickScreenUsesSaved() {
        let result = PanelPositioning.resolveShowPosition(
            savedPositions: ["primary": (originX: 100, topY: 800)],
            clickScreenKey: "primary",
            clickLocation: NSPoint(x: 500, y: 500),
            anchorRect: anchorOnPrimary,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.origin.x, 100, accuracy: 1)
    }

    func testSavedPositionOnDifferentScreenIgnoresSaved() {
        // Saved on primary, but click screen is secondary (no entry for secondary)
        let result = PanelPositioning.resolveShowPosition(
            savedPositions: ["primary": (originX: 100, topY: 800)],
            clickScreenKey: "secondary",
            clickLocation: NSPoint(x: 2500, y: 500),
            anchorRect: anchorOnPrimary,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        // Panel must be on secondary screen (falls back to anchor)
        XCTAssertGreaterThanOrEqual(result!.origin.x, secondary.frame.minX)
        XCTAssertLessThan(result!.maxX, secondary.frame.maxX)
    }

    func testNoClickLocationUsesSavedDirectly() {
        // No clickLocation (e.g., handleScreenChange path) → use saved via key
        let result = PanelPositioning.resolveShowPosition(
            savedPositions: ["primary": (originX: 100, topY: 800)],
            clickScreenKey: "primary",
            clickLocation: nil,
            anchorRect: anchorOnPrimary,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.origin.x, 100, accuracy: 1)
    }

    func testSavedPositionOnWrongScreenFallsBackToAnchor() {
        // Saved position for "primary" key has coordinates that are on secondary screen (stale data)
        let result = PanelPositioning.resolveShowPosition(
            savedPositions: ["primary": (originX: 2500, topY: 800)],
            clickScreenKey: "primary",
            clickLocation: NSPoint(x: 500, y: 500),
            anchorRect: anchorOnPrimary,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        // Should fall back to anchor on primary, NOT use stale position on secondary
        XCTAssertLessThan(
            result!.origin.x, primary.frame.maxX,
            "Panel should be on primary screen, not at stale position on secondary"
        )
        XCTAssertGreaterThanOrEqual(
            result!.origin.x, primary.frame.minX,
            "Panel should be on primary screen"
        )
    }

    func testNoSavedPositionFallsBackToAnchor() {
        let result = PanelPositioning.resolveShowPosition(
            savedPositions: [:],
            clickScreenKey: "primary",
            clickLocation: NSPoint(x: 1890, y: 1060),
            anchorRect: anchorOnPrimary,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        XCTAssertLessThan(result!.maxX, primary.frame.maxX)
    }

    // MARK: - PR #62: resolveAnchorPosition — cross-screen anchor synthesis

    func testAnchorOnSameScreenAsClick() {
        let result = PanelPositioning.resolveAnchorPosition(
            anchorRect: anchorOnPrimary,
            clickLocation: NSPoint(x: 1890, y: 1060),
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.maxY, anchorOnPrimary.minY - margin, accuracy: 1)
    }

    func testAnchorOnDifferentScreenSynthesizesAnchor() {
        let clickX: CGFloat = 2500
        let result = PanelPositioning.resolveAnchorPosition(
            anchorRect: anchorOnPrimary,
            clickLocation: NSPoint(x: clickX, y: 500),
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        // Must be on secondary screen
        XCTAssertGreaterThanOrEqual(result!.origin.x, secondary.frame.minX)
        // Centered around the click X
        XCTAssertEqual(result!.midX, clickX, accuracy: panelSize.width / 2)
        // Near the top of the secondary screen's visible area
        let synthAnchorBottom = secondary.visibleFrame.maxY - 22
        XCTAssertEqual(result!.maxY, synthAnchorBottom - margin, accuracy: 1)
    }

    func testNoClickLocationUsesRealAnchor() {
        let result = PanelPositioning.resolveAnchorPosition(
            anchorRect: anchorOnPrimary,
            clickLocation: nil,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.maxY, anchorOnPrimary.minY - margin, accuracy: 1)
    }

    func testNoAnchorReturnsNil() {
        let result = PanelPositioning.resolveAnchorPosition(
            anchorRect: nil,
            clickLocation: NSPoint(x: 500, y: 500),
            panelSize: panelSize, screens: screens
        )
        XCTAssertNil(result)
    }

    // MARK: - PR #60: resolveResetPosition — same vs different screen

    func testResetOnSameScreenSnapsToAnchor() {
        let result = PanelPositioning.resolveResetPosition(
            anchorRect: anchorOnPrimary,
            panelScreenIndex: 0,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.maxY, anchorOnPrimary.minY - margin, accuracy: 1)
        XCTAssertLessThan(result!.maxX, primary.frame.maxX)
    }

    func testResetOnDifferentScreenCentersOnPanelScreen() {
        let result = PanelPositioning.resolveResetPosition(
            anchorRect: anchorOnPrimary,
            panelScreenIndex: 1,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result!.origin.x, secondary.frame.minX)
        XCTAssertEqual(result!.midX, secondary.visibleFrame.midX, accuracy: 1)
        XCTAssertEqual(
            result!.maxY,
            secondary.visibleFrame.maxY - margin,
            accuracy: 1
        )
    }

    func testResetWithNoAnchorFallsBack() {
        let result = PanelPositioning.resolveResetPosition(
            anchorRect: nil,
            panelScreenIndex: 0,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
    }

    // MARK: - Edge cases

    func testSingleScreen() {
        let result = PanelPositioning.resolveAnchorPosition(
            anchorRect: anchorOnPrimary,
            clickLocation: NSPoint(x: 500, y: 500),
            panelSize: panelSize, screens: [primary]
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.maxY, anchorOnPrimary.minY - margin, accuracy: 1)
    }

    func testPanelClampedWhenAnchorNearEdge() {
        let edgeAnchor = NSRect(x: 1900, y: 1058, width: 20, height: 22)
        let result = PanelPositioning.resolveAnchorPosition(
            anchorRect: edgeAnchor,
            clickLocation: NSPoint(x: 1910, y: 1060),
            panelSize: panelSize, screens: [primary]
        )
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(result!.maxX, primary.visibleFrame.maxX - margin)
    }
}
