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

    func testResetOnDifferentScreenSnapsUnderMirroredIcon() {
        let result = PanelPositioning.resolveResetPosition(
            anchorRect: anchorOnPrimary,
            panelScreenIndex: 1,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result!.origin.x, secondary.frame.minX)
        // The menu bar is mirrored on every display, so the icon keeps its
        // offset from the right edge — the panel snaps under that, not center
        let mirroredMidX = secondary.frame.maxX - (primary.frame.maxX - anchorOnPrimary.midX)
        let expectedX = min(
            mirroredMidX - panelSize.width / 2,
            secondary.visibleFrame.maxX - panelSize.width - margin
        )
        XCTAssertEqual(result!.origin.x, expectedX, accuracy: 1)
        XCTAssertEqual(result!.maxY, anchorOnPrimary.minY - margin, accuracy: 1)
        XCTAssertNotEqual(
            result!.midX, secondary.visibleFrame.midX,
            "Reset must snap under the mirrored icon, not center on the screen"
        )
    }

    func testResetOnDifferentScreenMirrorsIconRectNotPillAnchor() {
        // Notch pill anchor near the middle of the primary screen; the real
        // menubar icon at the right edge is what's visible on other displays
        let pillAnchor = NSRect(x: 980, y: 1056, width: 160, height: 24)
        let result = PanelPositioning.resolveResetPosition(
            anchorRect: pillAnchor,
            menubarIconRect: anchorOnPrimary,
            panelScreenIndex: 1,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        let mirroredMidX = secondary.frame.maxX - (primary.frame.maxX - anchorOnPrimary.midX)
        let expectedX = min(
            mirroredMidX - panelSize.width / 2,
            secondary.visibleFrame.maxX - panelSize.width - margin
        )
        XCTAssertEqual(
            result!.origin.x, expectedX, accuracy: 1,
            "Cross-screen reset must mirror the icon, not the pill"
        )
    }

    func testResetOnDifferentScreenMirrorsIconOffsetUnclamped() {
        // Icon far enough from the right edge that the clamp doesn't engage,
        // asserting the mirror arithmetic itself
        let innerIcon = NSRect(x: 1600, y: 1058, width: 40, height: 22)
        let result = PanelPositioning.resolveResetPosition(
            anchorRect: innerIcon,
            panelScreenIndex: 1,
            panelSize: panelSize, screens: screens
        )
        XCTAssertNotNil(result)
        let mirroredMidX = secondary.frame.maxX - (primary.frame.maxX - innerIcon.midX)
        XCTAssertEqual(result!.origin.x, mirroredMidX - panelSize.width / 2, accuracy: 1)
        XCTAssertEqual(result!.maxY, innerIcon.minY - margin, accuracy: 1)
    }

    func testResetMirrorKeepsPanelBelowTallerMenubar() {
        // Destination screen has a taller menu bar (e.g. notched display);
        // the mirrored anchor must track the visible-area top, not frame top
        let notched = ScreenLayout(
            frame: NSRect(x: 1920, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 1920, y: 0, width: 1920, height: 1042),
            key: "notched"
        )
        let result = PanelPositioning.resolveResetPosition(
            anchorRect: anchorOnPrimary,
            panelScreenIndex: 1,
            panelSize: panelSize, screens: [primary, notched]
        )
        XCTAssertNotNil(result)
        XCTAssertLessThanOrEqual(
            result!.maxY, notched.visibleFrame.maxY,
            "Panel must stay below the destination screen's menu bar"
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

    // MARK: - Persisted panelPositions format (UserDefaults compatibility)

    /// The UserDefaults-backed store must read positions persisted by previous
    /// app versions and write back the identical raw format.
    func testUserDefaultsStoreReadsAndWritesEstablishedFormat() throws {
        let suiteName = "PanelPositioningTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            UserDefaults.standard.removeSuite(named: suiteName)
            defaults.removePersistentDomain(forName: suiteName)
        }

        // Seed pre-existing data exactly as older app versions persisted it.
        let preExisting: [String: [String: CGFloat]] = [
            "primary": ["originX": 200, "topY": 700]
        ]
        defaults.set(preExisting, forKey: "panelPositions")

        let store = UserDefaultsPanelPositionStore(defaults: defaults)
        XCTAssertEqual(store.positionsDict, preExisting, "Store must read positions written by older versions")

        let model = PanelGeometryModel(store: store)
        XCTAssertEqual(model.savedPositions()["primary"]?.originX, 200)
        XCTAssertEqual(model.savedPositions()["primary"]?.topY, 700)
        XCTAssertTrue(model.hasCustomPosition(forScreenKey: "primary"))
        XCTAssertFalse(model.hasCustomPosition(forScreenKey: "secondary"))

        model.saveCustomPosition(originX: 2200.5, topY: 901.25, forScreenKey: "secondary")
        XCTAssertEqual(
            defaults.dictionary(forKey: "panelPositions") as? [String: [String: CGFloat]],
            [
                "primary": ["originX": 200, "topY": 700],
                "secondary": ["originX": 2200.5, "topY": 901.25]
            ],
            "Saving must write the identical raw UserDefaults format"
        )

        model.clearCustomPosition(forScreenKey: "primary")
        XCTAssertEqual(
            defaults.dictionary(forKey: "panelPositions") as? [String: [String: CGFloat]],
            ["secondary": ["originX": 2200.5, "topY": 901.25]],
            "Clearing must remove only the given screen's entry, preserving the format"
        )
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
