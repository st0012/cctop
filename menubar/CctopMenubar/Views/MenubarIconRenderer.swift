import AppKit

/// Renders the menubar item as the same hairline status bar used throughout cctop.
/// With no sessions it becomes a monochrome template bar.
@MainActor
enum MenubarIconRenderer {
    private static let size = NSSize(width: 36, height: 18)
    private static let barRect = NSRect(x: 0, y: 6, width: 36, height: 6)

    static func render(counts: StatusCounts) -> NSImage {
        let image = NSImage(size: size, flipped: false) { _ in
            if counts.total == 0 {
                NSColor.labelColor.setFill()
                NSBezierPath(
                    roundedRect: barRect,
                    xRadius: barRect.height / 2,
                    yRadius: barRect.height / 2
                ).fill()
            } else {
                // AppKit makes the status item's effective appearance current here,
                // so one live image follows menu-bar light/dark changes immediately.
                drawSegmentedBar(
                    in: barRect,
                    counts: counts,
                    appearance: NSAppearance.current
                )
            }
            return true
        }

        image.isTemplate = counts.total == 0
        return image
    }

    private static func drawSegmentedBar(
        in barRect: NSRect, counts: StatusCounts, appearance: NSAppearance
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
            StatusColors.color(for: seg.kind, appearance: appearance).setFill()
            NSRect(
                x: xPos, y: barRect.minY,
                width: segWidth, height: barRect.height
            ).fill()
            xPos += segWidth
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
