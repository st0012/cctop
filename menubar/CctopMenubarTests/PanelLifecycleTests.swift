import XCTest
@testable import CctopMenubar

// MARK: - Lifecycle simulation

/// Simulates AppDelegate's panel position state management for lifecycle testing.
///
/// Models the interaction between savedPosition (UserDefaults), clickLocation
/// (transient per-toggle), and panelFrame across show/drag/dismiss/screenChange
/// operations. Each method mirrors a real AppDelegate code path.
///
/// **What this does NOT model** (potential gap for the real bug):
/// - Async timing between `.positionPanel` and `.showPanel` actions
/// - NSEvent.mouseLocation behavior on multi-monitor setups
/// - macOS notifications firing at unexpected times
/// - `resizePanel` interactions with `hasCustomPanelPosition`
private struct PanelLifecycle {
    var savedPositions: [String: (originX: CGFloat, topY: CGFloat)]
    var panelFrame: NSRect?
    var isVisible: Bool = false

    let screens: [ScreenLayout]
    let anchorRect: NSRect
    let panelSize: NSSize

    var hasCustomPosition: Bool { !savedPositions.isEmpty }

    init(
        savedPositions: [String: (originX: CGFloat, topY: CGFloat)] = [:],
        panelFrame: NSRect? = nil,
        isVisible: Bool = false,
        screens: [ScreenLayout],
        anchorRect: NSRect,
        panelSize: NSSize
    ) {
        self.savedPositions = savedPositions
        self.panelFrame = panelFrame
        self.isVisible = isVisible
        self.screens = screens
        self.anchorRect = anchorRect
        self.panelSize = panelSize
    }

    /// Find the screen key for a point.
    private func screenKey(for point: NSPoint) -> String? {
        guard let idx = PanelPositioning.screenIndex(containing: point, in: screens) else {
            return nil
        }
        return screens[idx].key
    }

    /// The screen key the panel is currently on (based on midpoint).
    private var panelScreenKey: String? {
        guard let frame = panelFrame else { return nil }
        return screenKey(for: NSPoint(x: frame.midX, y: frame.midY))
    }

    /// Simulate togglePanel() when hidden → show.
    /// Models: captureApps → positionPanel → showPanel → activateApp.
    /// See AppDelegate.togglePanel() + PanelCoordinator (.hidden, .menubarIconClicked).
    mutating func show(clickAt clickLocation: NSPoint) {
        precondition(!isVisible, "Panel must be hidden to show")

        let clickKey = screenKey(for: clickLocation)

        if let frame = PanelPositioning.resolveShowPosition(
            savedPositions: savedPositions,
            clickScreenKey: clickKey,
            clickLocation: clickLocation,
            anchorRect: anchorRect,
            panelSize: panelSize,
            screens: screens
        ) {
            panelFrame = frame
        }
        isVisible = true
        // clickLocation cleared after show (AppDelegate .showPanel async block)
    }

    /// Simulate header drag to a new position.
    /// Models: FloatingPanel.handleHeaderDrag → .panelDragEnded → saveCustomPanelPosition.
    mutating func drag(toOriginX originX: CGFloat, topY: CGFloat) {
        precondition(isVisible, "Panel must be visible to drag")
        panelFrame = NSRect(
            x: originX, y: topY - panelSize.height,
            width: panelSize.width, height: panelSize.height
        )
        // Save under the screen key the panel is now on
        if let key = panelScreenKey {
            savedPositions[key] = (originX: originX, topY: topY)
        }
    }

    /// Simulate togglePanel() when visible → dismiss.
    /// Models: PanelCoordinator (.normal, .menubarIconClicked) → .dismissPanel.
    mutating func dismiss() {
        precondition(isVisible, "Panel must be visible to dismiss")
        isVisible = false
        // clickLocation cleared in .dismissPanel action
    }

    /// Simulate handleScreenChange while panel is visible.
    /// Models: AppDelegate.handleScreenChange → positionPanel(clickLocation: nil) + save if custom.
    mutating func handleScreenChange() {
        guard isVisible else { return }

        let currentKey = panelScreenKey

        // positionPanel with clickLocation = nil (always cleared by this point)
        if let frame = PanelPositioning.resolveShowPosition(
            savedPositions: savedPositions,
            clickScreenKey: currentKey,
            clickLocation: nil,
            anchorRect: anchorRect,
            panelSize: panelSize,
            screens: screens
        ) {
            panelFrame = frame
        }

        // AppDelegate overwrites saved position for current screen with current frame
        if let key = currentKey, savedPositions[key] != nil, let frame = panelFrame {
            savedPositions[key] = (originX: frame.origin.x, topY: frame.maxY)
        }
    }

    /// Simulate handleScreenChange with a new screen layout.
    /// Models: monitors reconfigured (e.g., resolution change, monitor disconnected).
    mutating func handleScreenChange(newScreens: [ScreenLayout]) -> PanelLifecycle {
        var updated = PanelLifecycle(
            savedPositions: savedPositions,
            panelFrame: panelFrame,
            isVisible: isVisible,
            screens: newScreens,
            anchorRect: anchorRect,
            panelSize: panelSize
        )
        updated.handleScreenChange()
        return updated
    }

    /// Simulate resizePanel triggered by session count change.
    /// Models: AppDelegate.resizePanel with per-screen hasCustomPanelPosition check.
    mutating func resize(newHeight: CGFloat) {
        guard isVisible, let oldFrame = panelFrame else { return }
        let newSize = NSSize(width: panelSize.width, height: newHeight)
        let hasPositionOnCurrentScreen = panelScreenKey.map { savedPositions[$0] != nil } ?? false
        if hasPositionOnCurrentScreen {
            // Keep top-left corner stable
            panelFrame = NSRect(
                x: oldFrame.origin.x, y: oldFrame.maxY - newSize.height,
                width: newSize.width, height: newSize.height
            )
        } else {
            // Keep midX centered, top edge stable
            panelFrame = NSRect(
                x: oldFrame.midX - newSize.width / 2, y: oldFrame.maxY - newSize.height,
                width: newSize.width, height: newSize.height
            )
        }
    }

    /// Simulate double-click reset.
    /// Models: .resetPanelPosition → clearCustomPanelPosition for current screen only.
    mutating func resetPosition() {
        precondition(isVisible, "Panel must be visible to reset")

        // Clear only the current screen's saved position
        if let key = panelScreenKey {
            savedPositions.removeValue(forKey: key)
        }

        let panelIdx = panelFrame.flatMap { frame in
            PanelPositioning.screenIndex(
                containing: NSPoint(x: frame.midX, y: frame.midY), in: screens
            )
        }

        if let frame = PanelPositioning.resolveResetPosition(
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

    private func makeLifecycle() -> PanelLifecycle {
        PanelLifecycle(
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

        lc.dismiss()

        // Show on primary — custom position should survive
        lc.show(clickAt: clickOnPrimary)
        XCTAssertEqual(
            lc.panelFrame!.origin.x, 200, accuracy: 1,
            "Custom position should survive screen change on different screen"
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
        // Simulate stale data: savedPositions["primary"] has coordinates on secondary screen
        var lc = PanelLifecycle(
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
        var lc = PanelLifecycle(
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
}
