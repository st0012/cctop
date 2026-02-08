import AppKit
import Combine
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var sessionManager: SessionManager!
    private var cancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        sessionManager = SessionManager()

        // Status bar icon
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "CC"
            button.action = #selector(togglePanel)
            button.target = self
        }

        // Floating panel with SwiftUI content
        let contentView = PanelContentView(sessionManager: sessionManager)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel = FloatingPanel(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView

        // Update status item title when sessions change
        cancellable = sessionManager.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                let count = sessions.filter { $0.status.needsAttention }.count
                self?.statusItem.button?.title = count > 0 ? "CC (\(count))" : "CC"
            }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func positionPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let buttonRect = button.convert(button.bounds, to: nil)
        let screenRect = buttonWindow.convertToScreen(buttonRect)

        // Size the panel to fit its content
        panel.contentView?.layout()
        if let fittingSize = panel.contentView?.fittingSize {
            let width = max(fittingSize.width, 320)
            let height = min(fittingSize.height, 600)
            let x = screenRect.midX - width / 2
            let y = screenRect.minY - height - 4
            panel.setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        }
    }
}

/// Wrapper view that observes SessionManager and passes sessions to PopupView.
private struct PanelContentView: View {
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        PopupView(sessions: sessionManager.sessions)
            .frame(width: 320)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
