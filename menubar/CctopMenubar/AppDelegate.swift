import AppKit
import Combine
import KeyboardShortcuts
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
    private var compactController = CompactModeController()
    private var navKeyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var panelMode: PanelMode = .hidden
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
            refocus: refocusController,
            compactController: compactController
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
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in self?.togglePanel() }
        KeyboardShortcuts.onKeyUp(for: .refocus) { [weak self] in
            self?.handleEvent(.refocusShortcut)
        }
        refocusController.didConfirmSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.handleEvent(.refocusConfirmed) }
            .store(in: &cancellables)
        compactController.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.resizePanel(animate: true) } }
            .store(in: &cancellables)
        registerObservers()
    }

    @MainActor private func registerObservers() {
        let nc = NotificationCenter.default
        nc.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyAppearance() }
        nc.addObserver(
            forName: .layoutChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.resizePanel(animate: true) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  app != NSRunningApplication.current else { return }
            self?.lastExternalApp = app
        }
        nc.addObserver(
            forName: .panelHeaderClicked, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEvent(.headerClicked)
        }
        nc.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEvent(.appLostFocus)
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

    @MainActor @objc private func togglePanel() {
        handleEvent(.menubarIconClicked(appIsActive: NSApp.isActive))
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

    private func positionPanel(animate: Bool = false) {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let screenRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard let (width, height) = panelFittingSize() else { return }
        let newFrame = NSRect(x: screenRect.midX - width / 2, y: screenRect.minY - height - 4, width: width, height: height)
        setPanelFrame(newFrame, animate: animate)
    }

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

// MARK: - PanelCoordinator dispatch

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
    @MainActor @discardableResult
    func handleEvent(_ event: PanelEvent) -> Bool {
        let panelState = PanelState(
            mode: panelMode,
            compactPreference: compactController.compactMode
        )
        let result = PanelCoordinator.handle(event: event, state: panelState)
        panelMode = result.state.mode
        execute(result.actions)
        compactController.compactMode = result.state.compactPreference
        compactController.syncVisualState(panelMode)
        return result.eventConsumed
    }

    // swiftlint:disable:next cyclomatic_complexity
    @MainActor private func execute(_ actions: [PanelAction]) {
        for action in actions {
            switch action {
            case .showPanel:
                panel.makeKeyAndOrderFront(nil)
                // Re-position after SwiftUI layout settles
                DispatchQueue.main.async { [weak self] in
                    self?.positionPanel()
                }
            case .hidePanel:
                panel.orderOut(nil)
                previousApp = nil
            case .refocusPanel:
                panel.makeKeyAndOrderFront(nil)
            case .positionPanel:
                positionPanel()
            case .activateApp:
                NSApp.activate(ignoringOtherApps: true)
            case .deactivateApp:
                NSApp.deactivate()
            case .startNavKeyMonitor:
                startNavKeyMonitor()
            case .stopNavKeyMonitor:
                stopNavKeyMonitor()
            case .postNavAction(let navAction):
                postNavAction(navAction)
            case .activateExternalApp:
                lastExternalApp?.activate()
            case .restorePreviousApp:
                previousApp?.activate()
            case .captureApps:
                previousApp = NSWorkspace.shared.frontmostApplication
                if let prev = previousApp, prev != NSRunningApplication.current {
                    lastExternalApp = prev
                }
            case .startRefocusMode(let panelWasClosed):
                refocusController.activate(
                    sessions: sessionManager.sessions,
                    previousApp: NSWorkspace.shared.frontmostApplication,
                    panelWasClosed: panelWasClosed
                )
                refocusController.startTimeout { [weak self] in
                    self?.handleEvent(.refocusTimedOut)
                }
            case .endRefocusMode:
                refocusController.deactivate()
            case .startRefocusTimeout, .persistCompactMode:
                break // Handled elsewhere: timeout inside startRefocusMode, persistence via @AppStorage
            }
        }
    }

    @MainActor private func jumpToSession(index: Int) {
        guard index < refocusController.frozenSessions.count else { return }
        focusTerminal(session: refocusController.frozenSessions[index])
        handleEvent(.refocusConfirmed)
    }

    private func startNavKeyMonitor() {
        guard navKeyMonitor == nil else { return }
        navKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }

            // Refocus: digit keys jump to session
            if self.refocusController.isActive,
               let char = event.characters, let digit = Int(char), digit >= 1, digit <= 9 {
                DispatchQueue.main.async { self.jumpToSession(index: digit - 1) }
                return nil
            }

            // Cmd+M toggles compact mode (keyCode 46 = 'm')
            if event.modifierFlags.contains(.command) && event.keyCode == 46 {
                DispatchQueue.main.async { self.handleEvent(.cmdM) }
                return nil
            }

            // Escape key
            if event.keyCode == 53 {
                let consumed = self.handleEvent(.escape)
                return consumed ? nil : event
            }

            // Navigation keys
            if let navAction = navKeyMap[event.keyCode] {
                if self.refocusController.isActive { self.refocusController.cancelTimeout() }
                let consumed = self.handleEvent(.navKey(navAction))
                return consumed ? nil : event
            }

            // Refocus: any other key exits
            if self.refocusController.isActive {
                DispatchQueue.main.async { self.handleEvent(.unrecognizedKeyDuringRefocus) }
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
// MARK: - Hook binary installation

extension AppDelegate {
    /// Symlinks cctop-hook from the app bundle into ~/.cctop/bin/ so hooks can find it.
    func installHookBinaryIfNeeded() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        guard let bundledHook = Bundle.main.url(forAuxiliaryExecutable: "cctop-hook") else { return }
        let cctopBin = home.appendingPathComponent(".cctop/bin")
        let symlinkPath = cctopBin.appendingPathComponent("cctop-hook")
        if let dest = try? fm.destinationOfSymbolicLink(atPath: symlinkPath.path),
           URL(fileURLWithPath: dest) == bundledHook { return }
        do {
            try fm.createDirectory(at: cctopBin, withIntermediateDirectories: true)
            if (try? fm.attributesOfItem(atPath: symlinkPath.path)) != nil {
                try fm.removeItem(at: symlinkPath)
            }
            try fm.createSymbolicLink(at: symlinkPath, withDestinationURL: bundledHook)
        } catch {}
    }
}
