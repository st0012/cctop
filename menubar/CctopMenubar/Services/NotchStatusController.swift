import AppKit
import SwiftUI

/// Manages the notch status panel lifecycle. Creates a small status indicator
/// next to the camera notch on built-in displays. No-op on non-notch Macs.
class NotchStatusController {
    private var panel: NotchStatusPanel?
    private var hostingView: NSHostingView<NotchStatusView>?

    /// Current status counts -- updated by AppDelegate's session observer.
    var permission = 0
    var attention = 0
    var working = 0
    var idle = 0

    init() {}

    /// Show the notch panel on the given screen. Idempotent — reuses existing panel.
    func showOnScreen(_ screen: NSScreen) {
        guard screen.hasPhysicalNotch else { return }

        let notchSize = screen.notchSize
        let pillWidth: CGFloat = 70
        let pillHeight: CGFloat = 26
        let xPos = screen.frame.midX - notchSize.width / 2 - pillWidth + 9
        let yPos = screen.frame.maxY - pillHeight
        let frame = NSRect(x: xPos, y: yPos, width: pillWidth, height: pillHeight)

        if let panel {
            panel.setFrame(frame, display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }

        let statusView = NotchStatusView(
            permission: permission, attention: attention,
            working: working, idle: idle
        )
        let hosting = NSHostingView(rootView: statusView)
        hosting.translatesAutoresizingMaskIntoConstraints = false

        let newPanel = NotchStatusPanel(
            contentRect: .zero, styleMask: [],
            backing: .buffered, defer: false
        )
        newPanel.contentView = hosting
        newPanel.setFrame(frame, display: true)
        newPanel.orderFrontRegardless()

        self.panel = newPanel
        self.hostingView = hosting
    }

    /// Update the status display.
    func update(
        permission: Int, attention: Int,
        working: Int, idle: Int
    ) {
        self.permission = permission
        self.attention = attention
        self.working = working
        self.idle = idle

        let statusView = NotchStatusView(
            permission: permission, attention: attention,
            working: working, idle: idle
        )
        hostingView?.rootView = statusView
    }

    /// Remove the notch panel.
    func tearDown() {
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }
}
