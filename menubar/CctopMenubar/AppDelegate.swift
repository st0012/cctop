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

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "CC"
            button.action = #selector(togglePanel)
            button.target = self
        }

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
        let screenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        panel.contentView?.layout()
        guard let fittingSize = panel.contentView?.fittingSize else { return }

        let width = max(fittingSize.width, 320)
        let height = min(fittingSize.height, 600)
        panel.setFrame(
            NSRect(x: screenRect.midX - width / 2, y: screenRect.minY - height - 4, width: width, height: height),
            display: true
        )
    }
}

private struct PanelContentView: View {
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        PopupView(sessions: sessionManager.sessions)
            .frame(width: 320)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
