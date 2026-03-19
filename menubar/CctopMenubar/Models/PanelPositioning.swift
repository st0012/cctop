import AppKit

/// Screen geometry for panel positioning, decoupled from NSScreen for testability.
struct ScreenLayout: Equatable {
    let frame: NSRect
    let visibleFrame: NSRect
    let key: String?

    init(frame: NSRect, visibleFrame: NSRect, key: String? = nil) {
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.key = key
    }

    init(_ screen: NSScreen) {
        self.frame = screen.frame
        self.visibleFrame = screen.visibleFrame
        self.key = screen.screenKey
    }
}

/// Pure positioning math for the floating panel.
enum PanelPositioning {
    static let margin: CGFloat = 4
    private static let menubarButtonWidth: CGFloat = 20
    private static let menubarButtonHeight: CGFloat = 22

    /// Find the index of the screen containing the given point.
    static func screenIndex(
        containing point: NSPoint, in screens: [ScreenLayout]
    ) -> Int? {
        screens.firstIndex { NSMouseInRect(point, $0.frame, false) }
    }

    /// Clamp a saved panel position to stay within screen bounds.
    static func clampToScreen(
        originX: CGFloat, topY: CGFloat,
        size: NSSize,
        screens: [ScreenLayout]
    ) -> (originX: CGFloat, topY: CGFloat) {
        let point = NSPoint(x: originX, y: topY)
        let panelRect = NSRect(x: originX, y: topY - size.height, width: size.width, height: size.height)
        let idx = screens.firstIndex { NSMouseInRect(point, $0.frame, false) }
                  ?? screens.firstIndex { $0.visibleFrame.intersects(panelRect) }
        guard let idx, idx < screens.count else { return (originX, topY) }
        let vf = screens[idx].visibleFrame
        let clampedX = max(vf.minX + margin, min(originX, vf.maxX - size.width - margin))
        let clampedTopY = max(vf.minY + size.height + margin, min(topY, vf.maxY - margin))
        return (clampedX, clampedTopY)
    }

    // swiftlint:disable:next function_parameter_count
    static func resolveShowPosition(
        savedPositions: [String: (originX: CGFloat, topY: CGFloat)],
        clickScreenKey: String?,
        clickLocation: NSPoint?,
        anchorRect: NSRect?,
        panelSize: NSSize,
        screens: [ScreenLayout]
    ) -> NSRect? {
        if let key = clickScreenKey, let saved = savedPositions[key] {
            // Find the target screen by key
            let targetScreen = screens.first { $0.key == key }
            let savedPoint = NSPoint(x: saved.originX, y: saved.topY)

            // Validate saved position is on the target screen (not stale from a different layout)
            if let target = targetScreen, target.frame.contains(savedPoint) {
                let clamped = clampToScreen(
                    originX: saved.originX, topY: saved.topY,
                    size: panelSize, screens: screens
                )
                return NSRect(
                    x: clamped.originX, y: clamped.topY - panelSize.height,
                    width: panelSize.width, height: panelSize.height
                )
            }
            // Saved position is stale (on wrong screen) — fall through to anchor
        }
        return resolveAnchorPosition(
            anchorRect: anchorRect,
            clickLocation: clickLocation,
            panelSize: panelSize,
            screens: screens
        )
    }

    /// Position panel relative to the anchor, accounting for cross-screen clicks.
    static func resolveAnchorPosition(
        anchorRect: NSRect?,
        clickLocation: NSPoint?,
        panelSize: NSSize,
        screens: [ScreenLayout]
    ) -> NSRect? {
        guard let buttonAnchor = anchorRect else { return nil }

        let anchor: NSRect
        let targetScreen: ScreenLayout?

        let anchorIdx = screenIndex(containing: buttonAnchor.origin, in: screens)
        let clickIdx = clickLocation.flatMap { screenIndex(containing: $0, in: screens) }

        if let cIdx = clickIdx, cIdx != anchorIdx, let loc = clickLocation {
            anchor = NSRect(
                x: loc.x - menubarButtonWidth / 2,
                y: screens[cIdx].visibleFrame.maxY - menubarButtonHeight,
                width: menubarButtonWidth,
                height: menubarButtonHeight
            )
            targetScreen = screens[cIdx]
        } else {
            anchor = buttonAnchor
            targetScreen = anchorIdx.map { screens[$0] }
        }

        var panelX = anchor.midX - panelSize.width / 2
        if let vf = (targetScreen ?? screens.first)?.visibleFrame {
            panelX = max(vf.minX + margin, min(panelX, vf.maxX - panelSize.width - margin))
        }

        return NSRect(
            x: panelX, y: anchor.minY - panelSize.height - margin,
            width: panelSize.width, height: panelSize.height
        )
    }

    /// Resolve where to position the panel on double-click reset.
    /// Same screen as anchor → snap to anchor. Different screen → top-center.
    static func resolveResetPosition(
        anchorRect: NSRect?,
        panelScreenIndex: Int?,
        panelSize: NSSize,
        screens: [ScreenLayout]
    ) -> NSRect? {
        let anchorIdx = anchorRect.flatMap { screenIndex(containing: $0.origin, in: screens) }

        // Center on panel's screen if it differs from the anchor screen
        if let pIdx = panelScreenIndex, pIdx < screens.count, anchorIdx != pIdx {
            let vf = screens[pIdx].visibleFrame
            let panelX = max(
                vf.minX + margin,
                min(vf.midX - panelSize.width / 2, vf.maxX - panelSize.width - margin)
            )
            return NSRect(
                x: panelX, y: vf.maxY - margin - panelSize.height,
                width: panelSize.width, height: panelSize.height
            )
        }

        // Same screen as anchor, or no valid panel screen → snap to anchor
        return resolveAnchorPosition(
            anchorRect: anchorRect,
            clickLocation: nil,
            panelSize: panelSize,
            screens: screens
        )
    }
}
