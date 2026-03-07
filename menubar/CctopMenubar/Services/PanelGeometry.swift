import Foundation

enum PanelGeometry {
    /// Calculate frame centered under the menubar icon.
    /// Used on panel open and mode transitions.
    static func frameUnderIcon(
        iconFrame: NSRect, panelSize: NSSize, gap: CGFloat = 4
    ) -> NSRect {
        NSRect(
            x: iconFrame.midX - panelSize.width / 2,
            y: iconFrame.minY - panelSize.height - gap,
            width: panelSize.width,
            height: panelSize.height
        )
    }

    /// Calculate frame resized in place — preserves center X and top Y.
    /// Used on session updates (content size changes).
    static func frameResizedInPlace(
        oldFrame: NSRect, newSize: NSSize
    ) -> NSRect {
        NSRect(
            x: oldFrame.midX - newSize.width / 2,
            y: oldFrame.maxY - newSize.height,
            width: newSize.width,
            height: newSize.height
        )
    }
}
