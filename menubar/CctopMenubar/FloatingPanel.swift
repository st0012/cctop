import AppKit

@MainActor protocol FloatingPanelDelegate: AnyObject {
    func panelDidDrag(originX: CGFloat, topY: CGFloat)
    func panelDidRequestReset()
}

class FloatingPanel: NSPanel {
    weak var panelDelegate: FloatingPanelDelegate?
    /// Height of the header drag zone (matches HeaderView padding + content).
    private let headerDragHeight: CGFloat = 44

    enum HeaderClickAction: Equatable {
        case resetPosition
        case drag
    }

    /// macOS chains clickCount (1, 2, 3, …) for stationary clicks within the
    /// double-click interval, so a click right after a double-click reset
    /// arrives as count 3. Routing it into the drag loop would let the reset
    /// animation's frame movement read as a user drag; re-triggering the
    /// idempotent reset is always the intended outcome for counts ≥ 2.
    static func headerClickAction(forClickCount count: Int) -> HeaderClickAction {
        count >= 2 ? .resetPosition : .drag
    }

    /// The frame can move under a stationary click — reset and resize run
    /// setFrame(animate: true) — and persisting that movement as a drag
    /// would resurrect the saved position a reset just cleared. Only a real
    /// mouse drag may persist.
    static func shouldPersistDrag(sawDragEvents: Bool, originMoved: Bool) -> Bool {
        sawDragEvents && originMoved
    }

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
            switch Self.headerClickAction(forClickCount: event.clickCount) {
            case .resetPosition:
                panelDelegate?.panelDidRequestReset()
            case .drag:
                handleHeaderDrag()
            }
            return
        }
        super.sendEvent(event)
    }

    private func handleHeaderDrag() {
        let startLocation = NSEvent.mouseLocation
        let startOrigin = frame.origin
        var sawDragEvents = false

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
            sawDragEvents = true

            let current = NSEvent.mouseLocation
            setFrameOrigin(NSPoint(
                x: startOrigin.x + current.x - startLocation.x,
                y: startOrigin.y + current.y - startLocation.y
            ))
        }

        if Self.shouldPersistDrag(
            sawDragEvents: sawDragEvents,
            originMoved: frame.origin != startOrigin
        ) {
            panelDelegate?.panelDidDrag(originX: frame.origin.x, topY: frame.maxY)
        }
    }

    private func isInHeaderArea(_ event: NSEvent) -> Bool {
        event.locationInWindow.y >= frame.height - headerDragHeight
    }
}
