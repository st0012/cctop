import AppKit

enum MenubarIconRenderer {
    private static let narrowSize = NSSize(width: 18, height: 18)
    private static let wideSize = NSSize(width: 44, height: 18)
    private static let narrowBarHeight: CGFloat = 3
    private static let narrowBarY: CGFloat = 1
    private static let narrowBarInset: CGFloat = 2

    // Wide mode: bar sits to the right of the icon
    private static let wideIconWidth: CGFloat = 16
    private static let wideBarX: CGFloat = 20
    private static let wideBarWidth: CGFloat = 22
    private static let wideBarHeight: CGFloat = 5
    private static let wideBarY: CGFloat = 6.5  // vertically centered

    /// Renders the menubar icon with status bar.
    /// - Parameter wide: If true, renders icon + side bar (44px).
    ///   If false, renders icon with bar underneath (18px, for notch displays).
    static func render(
        permission: Int, attention: Int, working: Int, idle: Int,
        wide: Bool = false
    ) -> NSImage {
        guard let baseIcon = NSImage(named: "MenubarIcon") else {
            return NSImage()
        }

        let counts = StatusCounts(
            permission: permission, attention: attention,
            working: working, idle: idle
        )

        if counts.total == 0 {
            // swiftlint:disable:next force_cast
            let img = baseIcon.copy() as! NSImage
            img.isTemplate = true
            return img
        }

        let size = wide ? wideSize : narrowSize

        let image = NSImage(size: size, flipped: false) { _ in
            if wide {
                drawWideLayout(baseIcon: baseIcon, size: size, counts: counts)
            } else {
                drawNarrowLayout(baseIcon: baseIcon, size: size, counts: counts)
            }
            return true
        }

        image.isTemplate = false
        return image
    }

    private static func iconTintColor(for counts: StatusCounts) -> NSColor {
        counts.needsAction > 0 ? StatusColors.accent.nsColor : .labelColor
    }

    private static func drawNarrowLayout(
        baseIcon: NSImage, size: NSSize, counts: StatusCounts
    ) {
        let iconRect = NSRect(
            x: 0, y: narrowBarHeight + 2,
            width: size.width,
            height: size.height - narrowBarHeight - 2
        )
        baseIcon.draw(in: iconRect)
        iconTintColor(for: counts).set()
        iconRect.fill(using: .sourceAtop)

        let barWidth = size.width - narrowBarInset * 2
        let barRect = NSRect(
            x: narrowBarInset, y: narrowBarY,
            width: barWidth, height: narrowBarHeight
        )
        drawSegmentedBar(in: barRect, counts: counts)
    }

    private static func drawWideLayout(
        baseIcon: NSImage, size: NSSize, counts: StatusCounts
    ) {
        // Icon on the left, full height
        let iconRect = NSRect(
            x: 0, y: 1,
            width: wideIconWidth, height: wideIconWidth
        )
        baseIcon.draw(in: iconRect)
        iconTintColor(for: counts).set()
        iconRect.fill(using: .sourceAtop)

        // Status bar to the right of the icon
        let barRect = NSRect(
            x: wideBarX, y: wideBarY,
            width: wideBarWidth, height: wideBarHeight
        )
        drawSegmentedBar(in: barRect, counts: counts)
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

        var xPos = barRect.minX

        var segments: [(Int, NSColor)] = []
        if counts.needsAction > 0 {
            let color = counts.permission > 0
                ? StatusColors.permission.nsColor
                : StatusColors.attention.nsColor
            segments.append((counts.needsAction, color))
        }
        if counts.working > 0 {
            segments.append((counts.working, StatusColors.working.nsColor))
        }
        if counts.idle > 0 {
            segments.append((counts.idle, StatusColors.idle.nsColor))
        }

        for (count, color) in segments {
            let segWidth = barRect.width * CGFloat(count) / CGFloat(counts.total)
            color.setFill()
            NSRect(
                x: xPos, y: barRect.minY,
                width: segWidth, height: barRect.height
            ).fill()
            xPos += segWidth
        }

        NSGraphicsContext.current?.restoreGraphicsState()
    }
}
