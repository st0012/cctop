import AppKit

@MainActor protocol FloatingPanelDelegate: AnyObject {
    func panelDidDrag(originX: CGFloat, topY: CGFloat)
    func panelDidRequestReset()
}

class FloatingPanel: NSPanel {
    weak var panelDelegate: FloatingPanelDelegate?
    /// Height of the header drag zone (matches HeaderView padding + content).
    private let headerDragHeight: CGFloat = 44

    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: backing,
            defer: flag
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func orderFront(_ sender: Any?) {
        super.orderFront(sender)
        enableCursorRects()
        if let contentView { invalidateCursorRects(for: contentView) }
    }

    // MARK: - Header drag via tight event-tracking loop

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown && isInHeaderArea(event) {
            if event.clickCount == 2 {
                panelDelegate?.panelDidRequestReset()
                return
            }
            handleHeaderDrag()
            return
        }
        super.sendEvent(event)
    }

    private func handleHeaderDrag() {
        let startLocation = NSEvent.mouseLocation
        let startOrigin = frame.origin

        // Tight event-tracking loop — runs in eventTracking mode,
        // preventing SwiftUI layout passes from interleaving.
        while true {
            guard let event = nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { continue }

            if event.type == .leftMouseUp { break }

            let current = NSEvent.mouseLocation
            setFrameOrigin(NSPoint(
                x: startOrigin.x + current.x - startLocation.x,
                y: startOrigin.y + current.y - startLocation.y
            ))
        }

        if frame.origin != startOrigin {
            panelDelegate?.panelDidDrag(originX: frame.origin.x, topY: frame.maxY)
        }
    }

    private func isInHeaderArea(_ event: NSEvent) -> Bool {
        event.locationInWindow.y >= frame.height - headerDragHeight
    }
}
