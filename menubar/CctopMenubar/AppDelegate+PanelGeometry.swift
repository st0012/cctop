import AppKit

// MARK: - Panel geometry and per-screen position
extension AppDelegate {
    private enum PanelPositionKeys {
        // MIGRATION(v0.12.0→v0.13.0): Remove legacyOriginX, legacyTopY, migrateLegacyPanelPosition
        static let legacyOriginX = "panelCustomX"
        static let legacyTopY = "panelCustomTopY"
    }

    /// The screen key for the screen the panel is currently on.
    @MainActor func panelScreenKey() -> String? {
        PanelPositioning.screenKey(forPanelFrame: panel.frame, in: screenLayouts)
    }

    /// The screen key for the screen containing a point.
    func screenKey(at point: NSPoint) -> String? {
        PanelPositioning.screenKey(containing: point, in: screenLayouts)
    }

    /// Migrate legacy single-position UserDefaults to per-screen dictionary.
    func migrateLegacyPanelPosition() {
        let ud = UserDefaults.standard
        guard let originX = ud.object(forKey: PanelPositionKeys.legacyOriginX) as? Double else { return }
        let topY = ud.double(forKey: PanelPositionKeys.legacyTopY)
        panelGeometry.saveLegacyPosition(
            originX: CGFloat(originX), topY: CGFloat(topY),
            screens: screenLayouts,
            fallbackScreenKey: NSScreen.main?.screenKey
        )
        ud.removeObject(forKey: PanelPositionKeys.legacyOriginX)
        ud.removeObject(forKey: PanelPositionKeys.legacyTopY)
    }

    private var screenLayouts: [ScreenLayout] {
        NSScreen.screens.map { ScreenLayout($0) }
    }

    @MainActor func positionPanel(animate: Bool = false) {
        guard let size = panelFittingSize() else { return }
        let clickKey = focusLocation.flatMap { screenKey(at: $0) }
            ?? panelScreenKey()
        if let frame = panelGeometry.showFrame(
            clickScreenKey: clickKey,
            clickLocation: focusLocation,
            anchorRect: anchorRect(),
            panelSize: size,
            screens: screenLayouts
        ) {
            setPanelFrame(frame, animate: animate)
        }
    }

    /// The screen-space rect of the anchor (notch pill or menubar icon).
    @MainActor private func anchorRect() -> NSRect? {
        notchController.pillFrame ?? menubarIconRect()
    }

    /// The screen-space rect of the menubar icon, even when the notch pill
    /// is the anchor (the pill only exists on the built-in screen).
    @MainActor private func menubarIconRect() -> NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Reset panel position on double-click. If the panel is on the same screen
    /// as the anchor (menubar icon / notch pill), snap to anchor. Otherwise, snap
    /// under the menubar icon's mirrored position on the panel's current screen
    /// so it doesn't jump across screens.
    @MainActor private func resetPanelToCurrentScreen(animate: Bool = false) {
        guard let size = panelFittingSize() else { return }
        let layouts = screenLayouts
        let panelIdx = PanelPositioning.screenIndex(forPanelFrame: panel.frame, in: layouts)
        if let frame = PanelPositioning.resolveResetPosition(
            anchorRect: anchorRect(),
            menubarIconRect: menubarIconRect(),
            panelScreenIndex: panelIdx,
            panelSize: size,
            screens: layouts
        ) {
            setPanelFrame(frame, animate: animate)
        }
    }

    @MainActor func handleScreenChange() {
        screenChangeWork?.cancel()
        suppressResize = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.suppressResize = false
            self.hasNotch = NSScreen.builtin?.hasPhysicalNotch == true
            self.refreshStatusDisplay(counts: StatusCounts(userSessions: self.sessionManager.userSessions))
            guard self.panel.isVisible else { return }
            // A click location captured before the debounce must not drive
            // screen-change repositioning; clearing it keeps the key below
            // and positionPanel's internal key identical.
            self.focusLocation = nil
            self.positionPanel(animate: false)
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @MainActor func resizePanel(animate: Bool = false) {
        guard !suppressResize else { return }
        guard let size = panelFittingSize() else { return }
        let newFrame = panelGeometry.resizedFrame(
            from: panel.frame, to: size, panelScreenKey: panelScreenKey()
        )
        setPanelFrame(newFrame, animate: animate)
    }

    private func panelFittingSize() -> NSSize? {
        panel.contentView?.layout()
        guard let size = panel.contentView?.fittingSize else { return nil }
        return NSSize(width: max(size.width, 320), height: min(size.height, 600))
    }

    private func setPanelFrame(_ frame: NSRect, animate: Bool) {
        guard !panel.frame.isNearlyEqual(to: frame) else { return }
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

private extension NSRect {
    func isNearlyEqual(to other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) < 0.5 &&
            abs(origin.y - other.origin.y) < 0.5 &&
            abs(size.width - other.size.width) < 0.5 &&
            abs(size.height - other.size.height) < 0.5
    }
}

// MARK: - FloatingPanelDelegate
extension AppDelegate: FloatingPanelDelegate {
    @MainActor func panelDidDrag(originX: CGFloat, topY: CGFloat) {
        panelGeometry.saveUserDraggedPosition(
            originX: originX,
            topY: topY,
            panelSize: panel.frame.size,
            screens: screenLayouts
        )
    }

    @MainActor func panelDidRequestReset() {
        panelGeometry.clearUserPosition(forPanelFrame: panel.frame, screens: screenLayouts)
        resetPanelToCurrentScreen(animate: true)
    }
}
