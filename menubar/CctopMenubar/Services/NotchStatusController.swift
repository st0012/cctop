import AppKit
import SwiftUI

/// Manages the notch status panel lifecycle. Creates a small status indicator
/// next to the camera notch on built-in displays. No-op on non-notch Macs.
class NotchStatusController {
    private var panel: NotchStatusPanel?
    private var hostingView: NSHostingView<NotchStatusView>?

    /// Last counts passed to `update()`, used when creating the panel in `showOnScreen()`.
    private var lastCounts = StatusCounts(permission: 0, attention: 0, working: 0, idle: 0)

    init() {}

    /// Show the notch panel on the given screen. Idempotent — reuses existing panel.
    func showOnScreen(_ screen: NSScreen) {
        guard screen.hasPhysicalNotch else { return }

        let notchSize = screen.notchSize
        let pillWidth: CGFloat = 70
        let pillHeight: CGFloat = 26
        // Align pill to the left edge of the notch with a small overlap
        let xPos = screen.frame.midX - notchSize.width / 2 - pillWidth + 9
        let yPos = screen.frame.maxY - pillHeight
        let frame = NSRect(x: xPos, y: yPos, width: pillWidth, height: pillHeight)

        if let panel {
            panel.setFrame(frame, display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }

        let statusView = NotchStatusView(counts: lastCounts)
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
    func update(counts: StatusCounts) {
        lastCounts = counts
        hostingView?.rootView = NotchStatusView(counts: counts)
    }

    /// Remove the notch panel.
    func tearDown() {
        panel?.contentView = nil
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }
}
