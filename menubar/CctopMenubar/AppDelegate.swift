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
    private var updater: UpdaterBase!
    private var pluginManager: PluginManager!
    private var historyManager: HistoryManager!
    private var refocusController = RefocusController()
    private var navKeyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var cancellables: Set<AnyCancellable> = []
    @AppStorage("appearanceMode") var appearanceMode: String = "system"

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notificationsEnabled": true])
        installHookBinaryIfNeeded()

        UNUserNotificationCenter.current().delegate = self

        historyManager = HistoryManager()
        sessionManager = SessionManager(historyManager: historyManager)
        updater = makeUpdater()
        pluginManager = PluginManager()

        setupStatusItem()

        let contentView = PanelContentView(
            sessionManager: sessionManager,
            historyManager: historyManager,
            updater: updater,
            pluginManager: pluginManager,
            refocus: refocusController
        )
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
        registerShortcuts()
        observeSessionUpdates()
    }

    @MainActor private func registerShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.togglePanel()
        }
        KeyboardShortcuts.onKeyUp(for: .refocus) { [weak self] in
            self?.startRefocus()
        }
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.applyAppearance()
        }
        NotificationCenter.default.addObserver(
            forName: .layoutChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.resizePanel(animate: true)
        }
        refocusController.didConfirmSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.endRefocus(restoreFocus: false) }
            .store(in: &cancellables)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self, self.refocusController.isActive else { return }
            self.endRefocus(restoreFocus: false)
        }
    }

    @MainActor private func observeSessionUpdates() {
        sessionManager.$sessions
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
            .store(in: &cancellables)
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
        if refocusController.isActive {
            endRefocus(restoreFocus: true)
            return
        }
        if panel.isVisible {
            panel.orderOut(nil)
            stopNavKeyMonitor()
            if Self.shouldRestoreFocus(appIsActive: NSApp.isActive) {
                previousApp?.activate()
            }
            previousApp = nil
        } else {
            previousApp = NSWorkspace.shared.frontmostApplication
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            startNavKeyMonitor()
            postNavAction(.reset)
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

    /// Whether to restore focus to the previously-active app when closing the panel.
    /// When the user switches away while the panel is open, cctop is no longer active —
    /// restoring would yank focus from wherever the user switched to.
    static func shouldRestoreFocus(appIsActive: Bool) -> Bool {
        appIsActive
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

// MARK: - Keyboard navigation

private let navKeyMap: [UInt16: PanelNavAction] = [
    125: .down,         // down arrow
    126: .up,           // up arrow
    36: .confirm,       // return
    53: .escape,        // escape
    48: .toggleTab,     // tab
    123: .previousTab,  // left arrow
    124: .nextTab       // right arrow
]

extension AppDelegate {
    @MainActor func startRefocus() {
        guard !refocusController.isActive else { return }

        let panelWasClosed = !panel.isVisible

        if panelWasClosed {
            positionPanel()
            panel.makeKeyAndOrderFront(nil)
            DispatchQueue.main.async { [weak self] in
                self?.positionPanel()
            }
        }

        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
        startNavKeyMonitor()

        refocusController.activate(
            sessions: sessionManager.sessions,
            previousApp: NSWorkspace.shared.frontmostApplication,
            panelWasClosed: panelWasClosed
        )

        refocusController.startTimeout { [weak self] in
            self?.endRefocus(restoreFocus: true)
        }
    }

    func endRefocus(restoreFocus: Bool) {
        let state = refocusController.deactivate()

        if state.panelWasClosed {
            panel.orderOut(nil)
            stopNavKeyMonitor()
        }
        if restoreFocus {
            state.previousApp?.activate()
        }
        NSApp.deactivate()
    }

    @MainActor private func jumpToSession(index: Int) {
        let frozen = refocusController.frozenSessions
        guard index < frozen.count else { return }
        focusTerminal(session: frozen[index])
        endRefocus(restoreFocus: false)
    }

    private func startNavKeyMonitor() {
        guard navKeyMonitor == nil else { return }
        navKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }

            let isJump = self.refocusController.isActive

            // Refocus: escape exits refocus
            if isJump && event.keyCode == 53 {
                DispatchQueue.main.async { self.endRefocus(restoreFocus: true) }
                return nil
            }

            // Refocus: digit keys jump to session
            if isJump, let char = event.characters, let digit = Int(char), digit >= 1, digit <= 9 {
                DispatchQueue.main.async { self.jumpToSession(index: digit - 1) }
                return nil
            }

            // Navigation keys shared by both modes
            if let action = navKeyMap[event.keyCode] {
                if isJump { self.refocusController.cancelTimeout() }
                self.postNavAction(action)
                return nil
            }

            // Refocus: any other key exits
            if isJump {
                DispatchQueue.main.async { self.endRefocus(restoreFocus: true) }
                return nil
            }

            return event
        }
    }

    private func stopNavKeyMonitor() {
        if let monitor = navKeyMonitor {
            NSEvent.removeMonitor(monitor)
            navKeyMonitor = nil
        }
    }

    private func postNavAction(_ action: PanelNavAction) {
        refocusController.navActionSubject.send(action)
    }
}

private struct PanelContentView: View {
    @ObservedObject var sessionManager: SessionManager
    @ObservedObject var historyManager: HistoryManager
    @ObservedObject var updater: UpdaterBase
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject var refocus: RefocusController
    var body: some View {
        PopupView(
            sessions: sessionManager.sessions,
            recentProjects: historyManager.recentProjects,
            updater: updater,
            pluginManager: pluginManager,
            refocus: refocus
        )
        .frame(width: 320)
        .background(Color.panelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
