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

/// Persistence seam for per-screen custom panel positions.
///
/// The stored shape is the established `panelPositions` UserDefaults format:
/// `[screenKey: ["originX": x, "topY": y]]`.
protocol PanelPositionStoring: AnyObject {
    var positionsDict: [String: [String: CGFloat]] { get set }
}

/// Persists panel positions in UserDefaults under the existing
/// "panelPositions" key, with the exact encoding existing installs have on disk.
final class UserDefaultsPanelPositionStore: PanelPositionStoring {
    static let positionsKey = "panelPositions"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var positionsDict: [String: [String: CGFloat]] {
        get {
            defaults.dictionary(forKey: Self.positionsKey) as? [String: [String: CGFloat]] ?? [:]
        }
        set {
            defaults.set(newValue, forKey: Self.positionsKey)
        }
    }
}

/// Owns the panel's per-screen position persistence and geometry decisions,
/// so AppDelegate only gathers inputs (screens, frames, sizes) and applies frames.
struct PanelGeometryModel {
    let store: PanelPositionStoring

    // MARK: - Position persistence

    /// All saved custom positions, keyed by screen key.
    func savedPositions() -> [String: (originX: CGFloat, topY: CGFloat)] {
        store.positionsDict.compactMapValues { entry in
            guard let originX = entry["originX"], let topY = entry["topY"] else { return nil }
            return (originX: originX, topY: topY)
        }
    }

    /// Save a custom position for a screen.
    func saveCustomPosition(originX: CGFloat, topY: CGFloat, forScreenKey key: String) {
        var dict = store.positionsDict
        dict[key] = ["originX": originX, "topY": topY]
        store.positionsDict = dict
    }

    /// Remove the custom position for a screen.
    func clearCustomPosition(forScreenKey key: String) {
        var dict = store.positionsDict
        dict.removeValue(forKey: key)
        store.positionsDict = dict
    }

    /// Whether a custom position is saved for a screen.
    func hasCustomPosition(forScreenKey key: String) -> Bool {
        savedPositions()[key] != nil
    }

    // MARK: - Geometry decisions

    /// Resolve the frame for showing the panel, preferring the click screen's
    /// saved custom position and falling back to the anchor.
    func showFrame(
        clickScreenKey: String?,
        clickLocation: NSPoint?,
        anchorRect: NSRect?,
        panelSize: NSSize,
        screens: [ScreenLayout]
    ) -> NSRect? {
        PanelPositioning.resolveShowPosition(
            savedPositions: savedPositions(),
            clickScreenKey: clickScreenKey,
            clickLocation: clickLocation,
            anchorRect: anchorRect,
            panelSize: panelSize,
            screens: screens
        )
    }

    /// Resolve the frame after a content resize. If the panel's screen has a
    /// custom saved position, keep the top-left corner stable; otherwise keep
    /// midX centered with the top edge stable.
    func resizedFrame(from oldFrame: NSRect, to size: NSSize, panelScreenKey: String?) -> NSRect {
        let hasPositionOnCurrentScreen = panelScreenKey.map { savedPositions()[$0] != nil } ?? false
        if hasPositionOnCurrentScreen {
            // Keep top-left corner stable
            return NSRect(
                x: oldFrame.origin.x, y: oldFrame.maxY - size.height,
                width: size.width, height: size.height
            )
        }
        // Keep midX centered, top edge stable
        return NSRect(
            x: oldFrame.midX - size.width / 2, y: oldFrame.maxY - size.height,
            width: size.width, height: size.height
        )
    }

    /// Resolve where the panel lands on double-click reset.
    func resetFrame(
        anchorRect: NSRect?,
        menubarIconRect: NSRect? = nil,
        panelScreenIndex: Int?,
        panelSize: NSSize,
        screens: [ScreenLayout]
    ) -> NSRect? {
        PanelPositioning.resolveResetPosition(
            anchorRect: anchorRect,
            menubarIconRect: menubarIconRect,
            panelScreenIndex: panelScreenIndex,
            panelSize: panelSize,
            screens: screens
        )
    }

    /// After a screen-parameter change, overwrite the saved position for the
    /// panel's screen with the panel's current (possibly clamped) frame — but
    /// only if a custom position already exists for that screen key. The key
    /// must be captured before repositioning: if the change snapped the panel
    /// to another screen, resaving under the landing screen's key would
    /// overwrite that screen's user-dragged position with the new frame.
    func resaveAfterScreenChange(panelScreenKey: String?, panelFrame: NSRect) {
        guard let key = panelScreenKey, savedPositions()[key] != nil else { return }
        saveCustomPosition(originX: panelFrame.origin.x, topY: panelFrame.maxY, forScreenKey: key)
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
    /// Same screen as anchor → snap to anchor. Different screen → snap under
    /// the menubar icon's mirrored position on the panel's screen: the menu
    /// bar is mirrored on every display, so the icon keeps its offset from
    /// the screen's right edge. `menubarIconRect` is the icon even when the
    /// anchor is the notch pill (the pill only exists on the built-in screen).
    static func resolveResetPosition(
        anchorRect: NSRect?,
        menubarIconRect: NSRect? = nil,
        panelScreenIndex: Int?,
        panelSize: NSSize,
        screens: [ScreenLayout]
    ) -> NSRect? {
        let anchorIdx = anchorRect.flatMap { screenIndex(containing: $0.origin, in: screens) }

        // Panel on a different screen than the anchor → stay on the panel's screen
        if let pIdx = panelScreenIndex, pIdx < screens.count, anchorIdx != pIdx {
            let icon = menubarIconRect ?? anchorRect
            if let icon, let iconIdx = screenIndex(containing: icon.origin, in: screens) {
                let iconScreen = screens[iconIdx]
                let panelScreen = screens[pIdx]
                // Mirror against the visible-area top, not the frame top:
                // menu bar heights differ across displays (notched vs not),
                // and the panel must stay flush under the destination's bar
                let mirrored = NSRect(
                    x: panelScreen.frame.maxX - (iconScreen.frame.maxX - icon.minX),
                    y: panelScreen.visibleFrame.maxY + (icon.minY - iconScreen.visibleFrame.maxY),
                    width: icon.width,
                    height: icon.height
                )
                if panelScreen.frame.contains(mirrored.origin) {
                    return resolveAnchorPosition(
                        anchorRect: mirrored,
                        clickLocation: nil,
                        panelSize: panelSize,
                        screens: screens
                    )
                }
            }
            // No mirrorable icon, or the mirrored position falls outside the
            // panel's screen (much narrower display) → top-center fallback
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
