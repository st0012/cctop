import AppKit

/// A borderless, non-activating panel for displaying status in the notch area.
/// Clicking the pill posts a notification that AppDelegate uses to toggle the main panel.
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
        isMovable = false
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func mouseDown(with event: NSEvent) {
        NotificationCenter.default.post(name: .notchPillClicked, object: nil)
    }
}

extension Notification.Name {
    static let notchPillClicked = Notification.Name("notchPillClicked")
}
