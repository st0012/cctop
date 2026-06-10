import AppKit
import SwiftUI

/// Manages the notch status panel lifecycle. Creates a small status indicator
/// next to the camera notch on built-in displays. No-op on non-notch Macs.
@MainActor
class NotchStatusController {
    private static let pillWidth: CGFloat = 70
    private static let pillHeight: CGFloat = 20
    /// How far the pill overlaps the notch edge, anchoring it visually.
    private static let notchOverlap: CGFloat = 9

    private var panel: NotchStatusPanel?
    private var hostingView: NSHostingView<NotchStatusView>?

    /// Provides the current theme identifier; injected so tests and previews
    /// don't have to go through the ThemeManager singleton.
    private let themeId: @MainActor () -> String

    /// Called when the notch pill is clicked.
    var onPillClicked: (() -> Void)?

    /// Last counts received, used when creating or updating the panel.
    private(set) var lastCounts = StatusCounts.zero

    init(themeId: @escaping @MainActor () -> String = { ThemeManager.shared.themeId }) {
        self.themeId = themeId
    }

    /// The pill's current frame in screen coordinates, if visible.
    var pillFrame: NSRect? {
        guard let panel, panel.isVisible else { return nil }
        return panel.frame
    }

    /// Show the notch panel on the given screen. Idempotent — reuses existing panel.
    func showOnScreen(_ screen: NSScreen, counts: StatusCounts) {
        guard screen.hasPhysicalNotch else { return }

        let notchSize = screen.notchSize
        let xPos = screen.frame.midX - notchSize.width / 2 - Self.pillWidth + Self.notchOverlap
        let yPos = screen.frame.maxY - Self.pillHeight
        let frame = NSRect(x: xPos, y: yPos, width: Self.pillWidth, height: Self.pillHeight)

        if let panel {
            if counts != lastCounts {
                hostingView?.rootView = NotchStatusView(counts: counts, themeId: themeId())
                lastCounts = counts
            }
            panel.setFrame(frame, display: true)
            if !panel.isVisible { panel.orderFrontRegardless() }
            return
        }

        let statusView = NotchStatusView(counts: counts, themeId: themeId())
        let hosting = NSHostingView(rootView: statusView)
        hosting.autoresizingMask = [.width, .height]

        let newPanel = NotchStatusPanel(
            contentRect: .zero, styleMask: [],
            backing: .buffered, defer: false
        )
        newPanel.onPillClick = { [weak self] in self?.onPillClicked?() }
        newPanel.contentView = hosting
        newPanel.setFrame(frame, display: true)
        newPanel.orderFrontRegardless()

        self.panel = newPanel
        self.hostingView = hosting
        lastCounts = counts
    }

    /// Update the status display. No-op if the panel hasn't been created yet.
    func update(counts: StatusCounts) {
        lastCounts = counts
        guard let hostingView else { return }
        hostingView.rootView = NotchStatusView(counts: counts, themeId: themeId())
    }

    /// Remove the notch panel. Hide first, then release views.
    func tearDown() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        hostingView = nil
    }

    /// Decide whether to show, keep, or tear down the notch pill.
    nonisolated static func resolveVisibility(
        hasNotch: Bool,
        hasBuiltinScreen: Bool,
        appIsActive: Bool,
        pillExists: Bool,
        statusItemOccluded: Bool
    ) -> NotchPillAction {
        guard hasNotch, hasBuiltinScreen else { return .tearDown }
        // While cctop is active, menu bar status-item visibility can be transient.
        // Keep an existing pill, but do not create one until cctop is inactive.
        if appIsActive { return pillExists ? .keep : .tearDown }
        return statusItemOccluded ? .show : .tearDown
    }
}

enum NotchPillAction: Equatable {
    case show
    case keep
    case tearDown
}
