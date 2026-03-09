import AppKit

/// A borderless, non-activating panel for displaying status in the notch area.
/// Always ignores mouse events -- purely a read-only status display.
class NotchStatusPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask: NSWindow.StyleMask,
        backing: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: backing,
            defer: flag
        )
        level = .statusBar
        collectionBehavior = [
            .fullScreenAuxiliary, .stationary,
            .canJoinAllSpaces, .ignoresCycle
        ]
        ignoresMouseEvents = true
        isMovable = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
