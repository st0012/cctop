import XCTest
@testable import CctopMenubar

// MARK: - In-memory store

/// Test stand-in for UserDefaultsPanelPositionStore.
private final class InMemoryPanelPositionStore: PanelPositionStoring {
    var positionsDict: [String: [String: CGFloat]] = [:]
}

// MARK: - Lifecycle driver

/// Drives the real PanelGeometryModel through AppDelegate-shaped lifecycle
/// sequences (show/drag/dismiss/screenChange/resize/reset).
///
/// Every geometry and persistence decision is a model call; this struct only
/// gathers inputs the way AppDelegate does (click/panel screen keys) and keeps
/// the frame/visibility bookkeeping AppDelegate keeps in the panel itself.
private struct PanelLifecycleDriver {
    let model: PanelGeometryModel
    var panelFrame: NSRect?
    var isVisible: Bool = false

    var screens: [ScreenLayout]
    let anchorRect: NSRect
    let panelSize: NSSize

    var savedPositions: [String: (originX: CGFloat, topY: CGFloat)] { model.savedPositions() }

    init(
        savedPositions: [String: (originX: CGFloat, topY: CGFloat)] = [:],
        panelFrame: NSRect? = nil,
        isVisible: Bool = false,
        screens: [ScreenLayout],
        anchorRect: NSRect,
        panelSize: NSSize,
        store: PanelPositionStoring = InMemoryPanelPositionStore()
    ) {
        self.model = PanelGeometryModel(store: store)
        for (key, position) in savedPositions {
            model.saveCustomPosition(originX: position.originX, topY: position.topY, forScreenKey: key)
        }
        self.panelFrame = panelFrame
        self.isVisible = isVisible
        self.screens = screens
        self.anchorRect = anchorRect
        self.panelSize = panelSize
    }

    /// Find the screen key for a point (mirrors AppDelegate.screenKey(at:)).
    private func screenKey(for point: NSPoint) -> String? {
        guard let idx = PanelPositioning.screenIndex(containing: point, in: screens) else {
            return nil
        }
        return screens[idx].key
    }

    /// The screen key the panel is currently on (mirrors AppDelegate.panelScreenKey()).
    private var panelScreenKey: String? {
        guard let frame = panelFrame else { return nil }
        return screenKey(for: NSPoint(x: frame.midX, y: frame.midY))
    }

    /// togglePanel() when hidden → show.
    /// Mirrors: captureApps → positionPanel → showPanel → activateApp.
    mutating func show(clickAt clickLocation: NSPoint) {
        precondition(!isVisible, "Panel must be hidden to show")

        if let frame = model.showFrame(
            clickScreenKey: screenKey(for: clickLocation),
            clickLocation: clickLocation,
            anchorRect: anchorRect,
            panelSize: panelSize,
            screens: screens
        ) {
            panelFrame = frame
        }
        isVisible = true
        // focusLocation cleared after show (AppDelegate .showPanel async block)
    }

    /// The OLD navigate shortcut bug (no focusLocation set).
    /// Before the fix, navigate shortcut didn't set focusLocation,
    /// so positionPanel() fell back to panelScreenKey().
    mutating func showViaNavigateWithoutMouseLocation() {
        precondition(!isVisible, "Panel must be hidden to show via navigate")

        if let frame = model.showFrame(
            clickScreenKey: panelScreenKey,
            clickLocation: nil,
            anchorRect: anchorRect,
            panelSize: panelSize,
            screens: screens
        ) {
            panelFrame = frame
        }
        isVisible = true
    }

    /// Header drag to a new position.
    /// Mirrors: FloatingPanel.handleHeaderDrag → AppDelegate.panelDidDrag.
    mutating func drag(toOriginX originX: CGFloat, topY: CGFloat) {
        precondition(isVisible, "Panel must be visible to drag")
        panelFrame = NSRect(
            x: originX, y: topY - panelSize.height,
            width: panelSize.width, height: panelSize.height
        )
        // Save under the screen key the panel is now on
        if let key = panelScreenKey {
            model.saveCustomPosition(originX: originX, topY: topY, forScreenKey: key)
        }
    }

    /// togglePanel() when visible → dismiss.
    /// Mirrors: PanelCoordinator (.normal, .menubarIconClicked) → .dismissPanel.
    mutating func dismiss() {
        precondition(isVisible, "Panel must be visible to dismiss")
        isVisible = false
        // focusLocation cleared in .dismissPanel action
    }

    /// Screen-parameter change while panel is visible.
    /// Mirrors: AppDelegate.handleScreenChange → positionPanel + resave if custom.
    mutating func handleScreenChange() {
        guard isVisible else { return }

        // Capture the key before repositioning (mirrors AppDelegate): the
        // resave must key off the screen the panel was on, not where it lands
        let key = panelScreenKey

        // positionPanel with focusLocation = nil (explicitly cleared at the
        // top of AppDelegate's screen-change work item)
        if let frame = model.showFrame(
            clickScreenKey: key,
            clickLocation: nil,
            anchorRect: anchorRect,
            panelSize: panelSize,
            screens: screens
        ) {
            panelFrame = frame
        }

        // Overwrite the saved position with the possibly clamped frame, if one exists
        if let frame = panelFrame {
            model.resaveAfterScreenChange(panelScreenKey: key, panelFrame: frame)
        }
    }

    /// Screen-parameter change with a new screen layout.
    /// Mirrors: monitors reconfigured (e.g., resolution change, monitor disconnected).
    mutating func handleScreenChange(newScreens: [ScreenLayout]) -> PanelLifecycleDriver {
        var updated = self // shares the reference-typed store
        updated.screens = newScreens
        updated.handleScreenChange()
        return updated
    }

    /// Content resize triggered by session count change.
    /// Mirrors: AppDelegate.resizePanel.
    mutating func resize(newHeight: CGFloat) {
        guard isVisible, let oldFrame = panelFrame else { return }
        let newSize = NSSize(width: panelSize.width, height: newHeight)
        panelFrame = model.resizedFrame(from: oldFrame, to: newSize, panelScreenKey: panelScreenKey)
    }

    /// Double-click reset.
    /// Mirrors: AppDelegate.panelDidRequestReset → resetPanelToCurrentScreen.
    mutating func resetPosition() {
        precondition(isVisible, "Panel must be visible to reset")

        // Clear only the current screen's saved position
        if let key = panelScreenKey {
            model.clearCustomPosition(forScreenKey: key)
        }

        let panelIdx = panelFrame.flatMap { frame in
            PanelPositioning.screenIndex(
                containing: NSPoint(x: frame.midX, y: frame.midY), in: screens
            )
        }

        // Models the no-pill case only: menubarIconRect defaults to nil and
        // falls back to anchorRect (the pill case is covered by unit tests)
        if let frame = model.resetFrame(
            anchorRect: anchorRect,
            panelScreenIndex: panelIdx,
            panelSize: panelSize,
            screens: screens
        ) {
            panelFrame = frame
        }
    }
}

// MARK: - Tests

final class PanelLifecycleTests: XCTestCase {
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
    let anchorOnPrimary = NSRect(x: 1870, y: 1058, width: 40, height: 22)

    // Click points on each screen (middle-ish, simulating menubar icon click)
    let clickOnPrimary = NSPoint(x: 1890, y: 1060)
    let clickOnSecondary = NSPoint(x: 2500, y: 1060)

    private func makeLifecycle() -> PanelLifecycleDriver {
        PanelLifecycleDriver(
            screens: screens,
            anchorRect: anchorOnPrimary,
            panelSize: panelSize
        )
    }

    // MARK: - Basic position persistence

    func testDragPositionRestoredOnSameScreen() {
        var lc = makeLifecycle()

        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.dismiss()

        lc.show(clickAt: clickOnPrimary)
        XCTAssertEqual(lc.panelFrame!.origin.x, 200, accuracy: 1)
        XCTAssertEqual(lc.panelFrame!.maxY, 700, accuracy: 1)
    }

    func testNoDragShowsAtAnchor() {
        var lc = makeLifecycle()

        lc.show(clickAt: clickOnPrimary)
        // Without a drag, should be near the anchor
        XCTAssertLessThan(lc.panelFrame!.maxX, primary.frame.maxX)
        XCTAssertTrue(lc.savedPositions.isEmpty)
    }

    // MARK: - Cross-screen: the user's reported bug

    func testDragOnScreenA_ShowOnScreenB_ShowOnScreenA_RestoresPosition() {
        var lc = makeLifecycle()

        // Step 1: Show on primary, drag to custom position
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.dismiss()

        // Step 2: Show on secondary
        lc.show(clickAt: clickOnSecondary)
        XCTAssertGreaterThanOrEqual(
            lc.panelFrame!.origin.x, secondary.frame.minX,
            "Panel should appear on secondary screen"
        )
        lc.dismiss()

        // Step 3: Show on primary again — custom position should be restored
        lc.show(clickAt: clickOnPrimary)
        XCTAssertEqual(
            lc.panelFrame!.origin.x, 200, accuracy: 1,
            "Custom position X should be restored on return to primary"
        )
        XCTAssertEqual(
            lc.panelFrame!.maxY, 700, accuracy: 1,
            "Custom position Y should be restored on return to primary"
        )
    }

    // MARK: - Screen change while on different screen

    /// The clamp-resave must key off the screen the panel was on BEFORE
    /// repositioning. With no custom position on secondary, the screen change
    /// snaps the panel back to the anchor on primary — but primary's
    /// user-dragged entry must not be overwritten with the anchor frame.
    func testScreenChangeWhileOnSecondaryPreservesPrimaryPosition() {
        var lc = makeLifecycle()

        // Drag on primary
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.dismiss()

        // Show on secondary
        lc.show(clickAt: clickOnSecondary)

        // Screen change fires while panel is on secondary
        lc.handleScreenChange()

        // No custom position on secondary → the panel snaps back to the anchor
        // on primary, but the resave keys off secondary and is a no-op
        XCTAssertLessThan(
            lc.panelFrame!.maxX, primary.frame.maxX,
            "Panel should snap back to the anchor screen"
        )
        XCTAssertEqual(
            lc.savedPositions["primary"]!.originX, 200, accuracy: 0.5,
            "Dragged primary position must survive the resave"
        )
        XCTAssertEqual(
            lc.savedPositions["primary"]!.topY, 700, accuracy: 0.5,
            "Dragged primary position must survive the resave"
        )
        XCTAssertNil(
            lc.savedPositions["secondary"],
            "The no-op resave must not invent an entry for secondary"
        )

        lc.dismiss()

        // Show on primary — the dragged position is restored
        lc.show(clickAt: clickOnPrimary)
        XCTAssertEqual(
            lc.panelFrame!.origin.x, 200, accuracy: 1,
            "Custom position must survive a screen change fired while on secondary"
        )
        XCTAssertEqual(
            lc.panelFrame!.maxY, 700, accuracy: 1,
            "Custom position must survive a screen change fired while on secondary"
        )
    }

    // MARK: - Screen layout change (monitor disconnected/reconfigured)

    func testScreenLayoutChangeRelocatesSavedPosition() {
        var lc = makeLifecycle()

        // Drag to position on primary
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)

        // Secondary monitor disconnected — only primary remains
        lc = lc.handleScreenChange(newScreens: [primary])

        // Saved position for primary should still be valid
        XCTAssertEqual(lc.savedPositions["primary"]!.originX, 200, accuracy: 1)
    }

    // MARK: - Resize while on different screen

    func testResizeOnSecondaryDoesNotCorruptSavedPosition() {
        var lc = makeLifecycle()

        // Drag on primary
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.dismiss()

        // Show on secondary
        lc.show(clickAt: clickOnSecondary)
        let secondaryOriginX = lc.panelFrame!.origin.x

        // Session update triggers resize
        lc.resize(newHeight: 500)

        // Panel stays on secondary (top-left stable because hasCustomPosition)
        XCTAssertEqual(
            lc.panelFrame!.origin.x, secondaryOriginX, accuracy: 1,
            "Resize should keep panel on secondary"
        )

        lc.dismiss()

        // Show on primary — original position should be intact
        lc.show(clickAt: clickOnPrimary)
        XCTAssertEqual(
            lc.panelFrame!.origin.x, 200, accuracy: 1,
            "Saved position should not be corrupted by resize on different screen"
        )
    }

    // MARK: - Multiple round-trips

    func testPositionSurvivesMultipleCrossScreenTrips() {
        var lc = makeLifecycle()

        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.dismiss()

        for _ in 1...3 {
            lc.show(clickAt: clickOnSecondary)
            lc.dismiss()

            lc.show(clickAt: clickOnPrimary)
            XCTAssertEqual(lc.panelFrame!.origin.x, 200, accuracy: 1)
            lc.dismiss()
        }
    }

    // MARK: - Double-click reset

    func testResetClearsPositionAcrossScreens() {
        var lc = makeLifecycle()

        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.resetPosition()
        XCTAssertNil(lc.savedPositions["primary"], "Reset should clear current screen's position")
        lc.dismiss()

        // Next show should use anchor position, not custom
        lc.show(clickAt: clickOnPrimary)
        XCTAssertNotEqual(
            lc.panelFrame!.origin.x, 200,
            "After reset, should use anchor not custom position"
        )
    }

    // MARK: - Double-click reset on a different screen

    func testResetOnSecondarySnapsUnderMirroredIcon() {
        var lc = makeLifecycle()

        // Show on primary, drag the panel onto the secondary screen
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 2200, topY: 700)

        lc.resetPosition()

        XCTAssertNil(lc.savedPositions["secondary"], "Reset clears the panel screen's entry")
        // Panel stays on secondary, under the icon's mirrored position
        // (same offset from the right edge), not centered on the screen
        let mirroredMidX = secondary.frame.maxX - (primary.frame.maxX - anchorOnPrimary.midX)
        let expectedX = min(
            mirroredMidX - panelSize.width / 2,
            secondary.visibleFrame.maxX - panelSize.width - PanelPositioning.margin
        )
        XCTAssertEqual(lc.panelFrame!.origin.x, expectedX, accuracy: 1)
        XCTAssertEqual(
            lc.panelFrame!.maxY, anchorOnPrimary.minY - PanelPositioning.margin, accuracy: 1
        )
    }

    // MARK: - Per-screen positions are independent

    func testDragOnSecondaryPreservesPrimaryPosition() {
        var lc = makeLifecycle()

        // Drag on primary
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.dismiss()

        // Drag on secondary — saves under "secondary" key, preserves "primary"
        lc.show(clickAt: clickOnSecondary)
        lc.drag(toOriginX: 2200, topY: 700)
        lc.dismiss()

        // Show on primary — primary's saved position (200, 700) should be restored
        lc.show(clickAt: clickOnPrimary)
        XCTAssertEqual(
            lc.panelFrame!.origin.x, 200, accuracy: 1,
            "Primary position should be preserved after drag on secondary"
        )
        XCTAssertEqual(
            lc.panelFrame!.maxY, 700, accuracy: 1,
            "Primary position Y should be preserved after drag on secondary"
        )
    }

    func testPerScreenPositionsAreIndependent() {
        var lc = makeLifecycle()

        // Drag on primary to (200, 700)
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.dismiss()

        // Drag on secondary to (2200, 700)
        lc.show(clickAt: clickOnSecondary)
        lc.drag(toOriginX: 2200, topY: 700)
        lc.dismiss()

        // Show on primary → should restore (200, 700)
        lc.show(clickAt: clickOnPrimary)
        XCTAssertEqual(lc.panelFrame!.origin.x, 200, accuracy: 1)
        XCTAssertEqual(lc.panelFrame!.maxY, 700, accuracy: 1)
        lc.dismiss()

        // Show on secondary → should restore (2200, 700)
        lc.show(clickAt: clickOnSecondary)
        XCTAssertEqual(lc.panelFrame!.origin.x, 2200, accuracy: 1)
        XCTAssertEqual(lc.panelFrame!.maxY, 700, accuracy: 1)
    }

    // MARK: - Clear position only affects current screen

    func testClearPositionOnlyAffectsCurrentScreen() {
        var lc = makeLifecycle()

        // Drag on both screens
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.dismiss()

        lc.show(clickAt: clickOnSecondary)
        lc.drag(toOriginX: 2200, topY: 700)
        lc.dismiss()

        // Reset on primary
        lc.show(clickAt: clickOnPrimary)
        lc.resetPosition()
        lc.dismiss()

        // Show on secondary → still has its position
        lc.show(clickAt: clickOnSecondary)
        XCTAssertEqual(
            lc.panelFrame!.origin.x, 2200, accuracy: 1,
            "Secondary position should survive reset on primary"
        )
        lc.dismiss()

        // Show on primary → should use anchor (position was cleared)
        lc.show(clickAt: clickOnPrimary)
        XCTAssertNotEqual(
            lc.panelFrame!.origin.x, 200,
            "Primary should use anchor after reset"
        )
    }

    // MARK: - Stale saved position on wrong screen

    func testStalePositionOnWrongScreenIsIgnored() {
        // Stale data: savedPositions["primary"] has coordinates on secondary screen
        var lc = PanelLifecycleDriver(
            savedPositions: ["primary": (originX: 2500, topY: 800)],
            screens: screens,
            anchorRect: anchorOnPrimary,
            panelSize: panelSize
        )

        // Show on primary — stale position should be ignored, panel should use anchor
        lc.show(clickAt: clickOnPrimary)
        XCTAssertLessThan(
            lc.panelFrame!.origin.x, primary.frame.maxX,
            "Panel should appear on primary screen, not at stale position on secondary"
        )
        XCTAssertGreaterThanOrEqual(
            lc.panelFrame!.origin.x, primary.frame.minX,
            "Panel should appear on primary screen"
        )
    }

    // MARK: - Screen change while visible on same screen

    func testScreenChangeOnSameScreenClampsPosition() {
        // Use a single-screen setup so the position can only clamp within it
        let screen = ScreenLayout(
            frame: NSRect(x: 0, y: 0, width: 1920, height: 1080),
            visibleFrame: NSRect(x: 0, y: 0, width: 1920, height: 1055),
            key: "primary"
        )
        var lc = PanelLifecycleDriver(
            screens: [screen],
            anchorRect: anchorOnPrimary,
            panelSize: panelSize
        )

        // Drag so origin is within smaller screen but panel right edge overflows
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 1200, topY: 700)

        // Screen shrinks — panel (x=1500, w=320) overflows new right edge
        let smaller = ScreenLayout(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
            key: "primary"
        )
        lc = lc.handleScreenChange(newScreens: [smaller])

        // Saved position should be clamped to new screen bounds
        let margin = PanelPositioning.margin
        XCTAssertLessThanOrEqual(
            lc.savedPositions["primary"]!.originX,
            smaller.visibleFrame.maxX - panelSize.width - margin,
            "Saved position should be clamped to smaller screen"
        )
    }

    // MARK: - Header click routing and drag persistence (reset resurrection bug)

    /// macOS chains clickCount (1, 2, 3, …) for stationary clicks within the
    /// double-click interval. A chained click after a double-click reset must
    /// re-trigger the (idempotent) reset, NOT fall into the drag loop where
    /// the reset animation's frame movement reads as a user drag.
    func testChainedHeaderClicksKeepResetting() {
        XCTAssertEqual(FloatingPanel.headerClickAction(forClickCount: 1), .drag)
        XCTAssertEqual(FloatingPanel.headerClickAction(forClickCount: 2), .resetPosition)
        XCTAssertEqual(
            FloatingPanel.headerClickAction(forClickCount: 3), .resetPosition,
            "A chained third click must not enter the drag loop"
        )
        XCTAssertEqual(FloatingPanel.headerClickAction(forClickCount: 4), .resetPosition)
    }

    /// The panel frame can move under a stationary click (reset/resize runs
    /// setFrame(animate: true)). Persisting that movement as a drag would
    /// resurrect the saved position the reset just cleared.
    func testAnimationMovementAloneDoesNotPersistAsDrag() {
        XCTAssertFalse(
            FloatingPanel.shouldPersistDrag(sawDragEvents: false, originMoved: true),
            "Frame moved by animation, not the user — must not save"
        )
        XCTAssertTrue(FloatingPanel.shouldPersistDrag(sawDragEvents: true, originMoved: true))
        XCTAssertFalse(FloatingPanel.shouldPersistDrag(sawDragEvents: true, originMoved: false))
        XCTAssertFalse(FloatingPanel.shouldPersistDrag(sawDragEvents: false, originMoved: false))
    }

    // MARK: - Navigate shortcut opens on mouse screen (regression for #69)

    func testNavigateShortcutOpensOnMouseScreen() {
        var lc = makeLifecycle()

        // First show on primary so panel has a "last screen"
        lc.show(clickAt: clickOnPrimary)
        lc.dismiss()

        // Navigate shortcut with mouse on secondary → should open on secondary
        // (After fix: navigate sets focusLocation = mouseLocation, same as show)
        lc.show(clickAt: clickOnSecondary)
        XCTAssertGreaterThanOrEqual(
            lc.panelFrame!.origin.x, secondary.frame.minX,
            "Navigate shortcut should open panel on the screen where the mouse is"
        )
    }

    func testNavigateShortcutWithoutMouseLocationOpensOnLastScreen() {
        var lc = makeLifecycle()

        // Show on primary so panel has a "last screen"
        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)
        lc.dismiss()

        // OLD bug: navigate without mouse location falls back to panel's last screen
        lc.showViaNavigateWithoutMouseLocation()
        XCTAssertEqual(
            lc.panelFrame!.origin.x, 200, accuracy: 1,
            "Without mouse location, falls back to panel's last screen position"
        )
        // This is the broken behavior — panel opens on primary even if user is on secondary
    }

    // MARK: - Resize x custom position interaction (real resizedFrame branch)

    func testResizeWithCustomPositionKeepsTopLeftStable() {
        var lc = makeLifecycle()

        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 200, topY: 700)

        lc.resize(newHeight: 550)

        XCTAssertEqual(
            lc.panelFrame!.origin.x, 200, accuracy: 0.5,
            "With a custom position, resize must keep the left edge stable"
        )
        XCTAssertEqual(
            lc.panelFrame!.maxY, 700, accuracy: 0.5,
            "With a custom position, resize must keep the top edge stable"
        )
        XCTAssertEqual(lc.panelFrame!.height, 550, accuracy: 0.5)
    }

    func testResizeWithoutCustomPositionKeepsMidXCentered() {
        var lc = makeLifecycle()

        lc.show(clickAt: clickOnPrimary)
        let before = lc.panelFrame!

        lc.resize(newHeight: 550)

        XCTAssertEqual(
            lc.panelFrame!.midX, before.midX, accuracy: 0.5,
            "Without a custom position, resize must keep midX centered"
        )
        XCTAssertEqual(
            lc.panelFrame!.maxY, before.maxY, accuracy: 0.5,
            "Without a custom position, resize must keep the top edge stable"
        )
        XCTAssertEqual(lc.panelFrame!.height, 550, accuracy: 0.5)
    }

    // MARK: - Screen change clamp-resave (what actually lands in the store)

    func testScreenChangeResaveWritesClampedPositionToStore() {
        let store = InMemoryPanelPositionStore()
        var lc = PanelLifecycleDriver(
            screens: [primary],
            anchorRect: anchorOnPrimary,
            panelSize: panelSize,
            store: store
        )

        lc.show(clickAt: clickOnPrimary)
        lc.drag(toOriginX: 1200, topY: 700)

        // Screen shrinks — panel (x=1200, w=320) overflows the new right edge
        let smaller = ScreenLayout(
            frame: NSRect(x: 0, y: 0, width: 1440, height: 900),
            visibleFrame: NSRect(x: 0, y: 0, width: 1440, height: 875),
            key: "primary"
        )
        lc = lc.handleScreenChange(newScreens: [smaller])

        let expectedX = smaller.visibleFrame.maxX - panelSize.width - PanelPositioning.margin
        XCTAssertEqual(
            store.positionsDict,
            ["primary": ["originX": expectedX, "topY": 700]],
            "Screen change must resave the clamped position in the persisted format"
        )
    }

    func testScreenChangeDoesNotCreatePositionForScreenWithoutOne() {
        let store = InMemoryPanelPositionStore()
        var lc = PanelLifecycleDriver(
            screens: screens,
            anchorRect: anchorOnPrimary,
            panelSize: panelSize,
            store: store
        )

        // No custom position anywhere; panel shown on secondary
        lc.show(clickAt: clickOnSecondary)
        lc.handleScreenChange()

        XCTAssertEqual(
            store.positionsDict, [:],
            "Resave must not invent a position for a screen that never had one"
        )
    }
}
