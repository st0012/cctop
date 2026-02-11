import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var sessionManager: SessionManager!
    private var updateChecker: UpdateChecker!
    private var cancellable: AnyCancellable?
    @AppStorage("appearanceMode") var appearanceMode: String = "system"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notificationsEnabled": true])
        installHookBinaryIfNeeded()

        UNUserNotificationCenter.current().delegate = self

        sessionManager = SessionManager()
        updateChecker = UpdateChecker()

        setupStatusItem()

        let contentView = PanelContentView(sessionManager: sessionManager, updateChecker: updateChecker)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        panel = FloatingPanel(
            contentRect: .zero,
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView

        applyAppearance()

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.togglePanel()
        }

        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }

        NotificationCenter.default.addObserver(forName: .settingsToggled, object: nil, queue: .main) { [weak self] _ in
            self?.positionPanel(animate: true)
        }

        cancellable = sessionManager.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                let count = sessions.filter { $0.status.needsAttention }.count
                self?.statusItem.button?.title = count > 0 ? "\(count)" : ""
                let a11yLabel = count > 0
                    ? "cctop, \(count) session\(count == 1 ? "" : "s") need attention"
                    : "cctop, \(sessions.count) session\(sessions.count == 1 ? "" : "s")"
                self?.statusItem.button?.setAccessibilityLabel(a11yLabel)
                if self?.panel.isVisible == true {
                    // Defer positioning so SwiftUI can finish its layout pass
                    // before we read fittingSize
                    DispatchQueue.main.async { [weak self] in
                        self?.positionPanel(animate: true)
                    }
                }
            }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "cctop")
            image?.isTemplate = true
            button.image = image
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    @objc private func togglePanel() {
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
            // Re-position after SwiftUI layout settles (fittingSize may
            // include hidden views on the first pass)
            DispatchQueue.main.async { [weak self] in
                self?.positionPanel()
            }
        }
    }

    private func applyAppearance() {
        let mode = AppearanceMode(rawValue: appearanceMode) ?? .system
        switch mode {
        case .system:
            panel?.appearance = nil
        case .light:
            panel?.appearance = NSAppearance(named: .aqua)
        case .dark:
            panel?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.content.userInfo["sessionId"] as? String
        DispatchQueue.main.async { [weak self] in
            if let session = self?.sessionManager.sessions.first(where: { $0.sessionId == sessionId }) {
                focusTerminal(session: session)
            }
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// Symlinks cctop-hook from the app bundle into ~/.local/bin/ so Claude Code hooks can find it.
    /// Skips if cctop-hook is already reachable (e.g. via Homebrew or cargo install).
    private func installHookBinaryIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        // Check if cctop-hook is already installed somewhere run-hook.sh checks
        let existingPaths = [
            home.appendingPathComponent(".cargo/bin/cctop-hook"),
            home.appendingPathComponent(".local/bin/cctop-hook"),
            URL(fileURLWithPath: "/opt/homebrew/bin/cctop-hook"),
            URL(fileURLWithPath: "/usr/local/bin/cctop-hook")
        ]

        for path in existingPaths {
            // If a real file (not broken symlink) exists, nothing to do
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path.path, isDirectory: &isDir), !isDir.boolValue {
                return
            }
        }

        // cctop-hook not found — symlink from the app bundle to ~/.local/bin/
        guard let bundledHook = Bundle.main.url(forAuxiliaryExecutable: "cctop-hook") else { return }

        let localBin = home.appendingPathComponent(".local/bin")
        let symlinkPath = localBin.appendingPathComponent("cctop-hook")

        do {
            try fm.createDirectory(at: localBin, withIntermediateDirectories: true)
            // Remove stale symlink if it exists (e.g. app was reinstalled to different path)
            if (try? fm.attributesOfItem(atPath: symlinkPath.path)) != nil {
                try fm.removeItem(at: symlinkPath)
            }
            try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: bundledHook)
        } catch {
            // Non-fatal — hook can still be installed manually
        }
    }

    private func positionPanel(animate: Bool = false) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let screenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        panel.contentView?.layout()
        guard let fittingSize = panel.contentView?.fittingSize else { return }

        let width = max(fittingSize.width, 320)
        let height = min(fittingSize.height, 600)
        let newFrame = NSRect(x: screenRect.midX - width / 2, y: screenRect.minY - height - 4, width: width, height: height)

        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(newFrame, display: true)
            }
        } else {
            panel.setFrame(newFrame, display: true)
        }
    }
}

private struct PanelContentView: View {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var updateChecker: UpdateChecker
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PopupView(sessions: sessionManager.sessions, resetSession: sessionManager.resetSession, updateAvailable: updateChecker.updateAvailable)
            .frame(width: 320)
            .background {
                if colorScheme == .light {
                    Color(red: 250 / 255, green: 248 / 255, blue: 245 / 255) // #faf8f5
                } else {
                    Color(red: 28 / 255, green: 25 / 255, blue: 22 / 255) // #1c1916
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
