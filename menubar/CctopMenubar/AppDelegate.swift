import AppKit
import Combine
import KeyboardShortcuts
import os.log
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var sessionManager: SessionManager!
    private var updateChecker: UpdateChecker!
    private var pluginManager: PluginManager!
    private var cancellable: AnyCancellable?
    @AppStorage("appearanceMode") var appearanceMode: String = "system"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notificationsEnabled": true])
        installHookBinaryIfNeeded()

        UNUserNotificationCenter.current().delegate = self

        sessionManager = SessionManager()
        updateChecker = UpdateChecker()
        pluginManager = PluginManager()

        setupStatusItem()

        let contentView = PanelContentView(sessionManager: sessionManager, updateChecker: updateChecker, pluginManager: pluginManager)
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 10
        hostingView.layer?.masksToBounds = true
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
            self?.resizePanel(animate: true)
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
                    DispatchQueue.main.async { [weak self] in
                        self?.resizePanel(animate: true)
                    }
                }
            }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(named: "MenubarIcon")
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
        let pidStr = response.notification.request.content.userInfo["sessionPID"] as? String
        DispatchQueue.main.async { [weak self] in
            if let session = self?.sessionManager.sessions.first(where: { $0.id == pidStr }) {
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

    /// Symlinks cctop-hook from the app bundle into ~/.cctop/bin/ so Claude Code hooks can find it.
    /// run-hook.sh prefers ~/.cctop/bin/cctop-hook, then falls back to app bundle paths.
    /// Re-creates the symlink on every launch so it stays current after upgrades.
    private func installHookBinaryIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        guard let bundledHook = Bundle.main.url(forAuxiliaryExecutable: "cctop-hook") else { return }

        let cctopBin = home.appendingPathComponent(".cctop/bin")
        let symlinkPath = cctopBin.appendingPathComponent("cctop-hook")

        // Skip if existing symlink already points to the current bundle
        if let dest = try? fm.destinationOfSymbolicLink(atPath: symlinkPath.path),
           URL(fileURLWithPath: dest) == bundledHook {
            return
        }

        do {
            try fm.createDirectory(at: cctopBin, withIntermediateDirectories: true)
            // Remove stale/dangling symlink or file before creating new one
            if (try? fm.attributesOfItem(atPath: symlinkPath.path)) != nil {
                try fm.removeItem(at: symlinkPath)
            }
            try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: bundledHook)
        } catch {
            // Non-fatal — hook can still be found via app bundle paths
        }
    }

    private func positionPanel(animate: Bool = false) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let screenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let (width, height) = panelFittingSize() else { return }

        let newFrame = NSRect(x: screenRect.midX - width / 2, y: screenRect.minY - height - 4, width: width, height: height)
        setPanelFrame(newFrame, animate: animate)
    }

    /// Resize the panel in place (keeps current x position, grows/shrinks from the top edge).
    private func resizePanel(animate: Bool = false) {
        guard let (width, height) = panelFittingSize() else { return }

        let oldFrame = panel.frame
        let newFrame = NSRect(x: oldFrame.midX - width / 2, y: oldFrame.maxY - height, width: width, height: height)
        setPanelFrame(newFrame, animate: animate)
    }

    private func panelFittingSize() -> (width: CGFloat, height: CGFloat)? {
        panel.contentView?.layout()
        guard let fittingSize = panel.contentView?.fittingSize else { return nil }
        return (max(fittingSize.width, 320), min(fittingSize.height, 600))
    }

    private func setPanelFrame(_ frame: NSRect, animate: Bool) {
        if animate {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

private struct PanelContentView: View {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var updateChecker: UpdateChecker
    @ObservedObject var pluginManager: PluginManager
    var body: some View {
        PopupView(
            sessions: sessionManager.sessions,
            updateAvailable: updateChecker.updateAvailable,
            pluginManager: pluginManager
        )
        .frame(width: 320)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
