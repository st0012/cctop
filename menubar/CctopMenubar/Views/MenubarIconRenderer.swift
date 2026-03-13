import AppKit

/// Renders the menubar icon: grid icon on the left + proportional status bar on the right.
/// Returns a template image when no sessions are active.
@MainActor
enum MenubarIconRenderer {
    private static let size = NSSize(width: 44, height: 18)
    private static let iconWidth: CGFloat = 16
    private static let barX: CGFloat = 20
    private static let barWidth: CGFloat = 22
    private static let barHeight: CGFloat = 4
    private static let barY: CGFloat = 7  // vertically centered: (18 - 4) / 2

    static func render(counts: StatusCounts) -> NSImage {
        guard let baseIcon = NSImage(named: "MenubarIcon") else {
            return NSImage()
        }

        if counts.total == 0 {
            guard let img = baseIcon.copy() as? NSImage else { return NSImage() }
            img.isTemplate = true
            return img
        }

        let image = NSImage(size: size, flipped: false) { _ in
            // Icon on the left, full height
            let iconRect = NSRect(x: 0, y: 1, width: iconWidth, height: iconWidth)
            baseIcon.draw(in: iconRect)
            iconTintColor(for: counts).set()
            iconRect.fill(using: .sourceAtop)

            // Status bar to the right of the icon
            let barRect = NSRect(x: barX, y: barY, width: barWidth, height: barHeight)
            drawSegmentedBar(in: barRect, counts: counts)
            return true
        }

        image.isTemplate = false
        return image
    }

    private static func iconTintColor(for counts: StatusCounts) -> NSColor {
        counts.needsAction > 0 ? StatusColors.accent.nsColor : .labelColor
    }

    private static func drawSegmentedBar(
        in barRect: NSRect, counts: StatusCounts
    ) {
        let path = NSBezierPath(
            roundedRect: barRect,
            xRadius: barRect.height / 2,
            yRadius: barRect.height / 2
        )
        NSGraphicsContext.current?.saveGraphicsState()
        path.addClip()

        let segments = counts.barSegments(forWidth: Double(barRect.width))
        var xPos = barRect.minX
        for (index, seg) in segments.enumerated() {
            // Last segment fills to the right edge to avoid float rounding gaps
            let segWidth = index == segments.count - 1
                ? max(0, barRect.maxX - xPos)
                : barRect.width * seg.proportion
            seg.color.nsColor.setFill()
            NSRect(
                x: xPos, y: barRect.minY,
                width: segWidth, height: barRect.height
            ).fill()
            xPos += segWidth
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
