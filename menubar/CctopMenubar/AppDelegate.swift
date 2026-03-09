// swiftlint:disable file_length
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
    private var notchController = NotchStatusController()
    private var navKeyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var panelMode: PanelMode = .hidden
    private var screenChangeWork: DispatchWorkItem?
    private var notchVisibilityWork: DispatchWorkItem?
    private var suppressResize = false
    private var lastRenderedCounts: StatusCounts?
    private var hasNotch = false
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
        hasNotch = NSScreen.builtin?.hasPhysicalNotch == true

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
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in self?.togglePanel() }
        KeyboardShortcuts.onKeyUp(for: .refocus) { [weak self] in
            self?.handleEvent(.refocusShortcut)
        }
        refocusController.didConfirmSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.handleEvent(.refocusConfirmed) }
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
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleEvent(.appLostFocus)
        }
        nc.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleScreenChange()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.updateNotchVisibility()
        }
        nc.addObserver(
            forName: .notchPillClicked, object: nil, queue: .main
        ) { [weak self] _ in
            self?.togglePanel()
        }
    }

    @MainActor private func observeSessionUpdates() {
        sessionManager.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] sessions in
                guard let self else { return }
                let counts = StatusCounts(sessions: sessions)

                if counts != self.lastRenderedCounts {
                    self.refreshStatusDisplay(counts: counts)
                }

                if self.panel.isVisible == true {
                    DispatchQueue.main.async { [weak self] in
                        self?.resizePanel(animate: true)
                    }
                }
            }
            .store(in: &cancellables)
    }

    @MainActor private func refreshStatusDisplay(counts: StatusCounts) {
        lastRenderedCounts = counts
        statusItem.button?.image = MenubarIconRenderer.render(counts: counts)
        notchController.update(counts: counts)
        updateNotchVisibility()
        statusItem.button?.setAccessibilityLabel(counts.accessibilityLabel)
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

    /// Whether the status item is hidden behind the notch.
    private var isStatusItemOccluded: Bool {
        guard let screen = NSScreen.builtin, screen.hasPhysicalNotch else { return false }
        guard let window = statusItem.button?.window, window.frame.width > 0 else { return true }

        // macOS may keep the window but stop rendering it when space is tight
        if !window.occlusionState.contains(.visible) { return true }

        let visibleMinX = screen.frame.maxX - (screen.auxiliaryTopRightArea?.width ?? 0)
        return window.frame.minX < visibleMinX
    }

    /// Show notch panel when the menubar icon is hidden behind the notch.
    @MainActor private func updateNotchVisibility(immediate: Bool = false) {
        notchVisibilityWork?.cancel()
        guard hasNotch else {
            notchController.tearDown(); return
        }
        let counts = lastRenderedCounts ?? .zero
        let show: () -> Void = { [weak self] in
            guard let self, self.hasNotch, let screen = NSScreen.builtin,
                  self.isStatusItemOccluded else {
                self?.notchController.tearDown(); return
            }
            self.notchController.showOnScreen(screen, counts: counts)
        }
        guard !immediate else { show(); return }
        let work = DispatchWorkItem(block: show)
        notchVisibilityWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
    }

    private func applyAppearance() {
        switch AppearanceMode(rawValue: appearanceMode) ?? .system {
        case .system: panel?.appearance = nil
        case .light: panel?.appearance = NSAppearance(named: .aqua)
        case .dark: panel?.appearance = NSAppearance(named: .darkAqua)
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
        guard let (width, height) = panelFittingSize() else { return }

        // Use the notch pill position when the menubar icon is hidden behind the notch
        let anchorRect: NSRect
        if let pillFrame = notchController.pillFrame {
            anchorRect = pillFrame
        } else if let button = statusItem.button, let buttonWindow = button.window {
            anchorRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        } else {
            return
        }

        var panelX = anchorRect.midX - width / 2
        // Clamp to the screen that contains the anchor (pill or menubar icon)
        let anchorScreen = NSScreen.screens.first { $0.frame.contains(anchorRect.origin) }
        if let visibleFrame = (anchorScreen ?? NSScreen.main)?.visibleFrame {
            panelX = max(visibleFrame.minX + 4, min(panelX, visibleFrame.maxX - width - 4))
        }

        let newFrame = NSRect(
            x: panelX, y: anchorRect.minY - height - 4,
            width: width, height: height
        )
        setPanelFrame(newFrame, animate: animate)
    }

    @MainActor private func handleScreenChange() {
        screenChangeWork?.cancel()
        suppressResize = true
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.suppressResize = false
            self.hasNotch = NSScreen.builtin?.hasPhysicalNotch == true
            self.refreshStatusDisplay(counts: StatusCounts(sessions: self.sessionManager.sessions))
            guard self.panel.isVisible else { return }
            self.positionPanel(animate: false)
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func resizePanel(animate: Bool = false) {
        guard !suppressResize else { return }
        guard let (width, height) = panelFittingSize() else { return }
        let oldFrame = panel.frame
        let newFrame = NSRect(x: oldFrame.midX - width / 2, y: oldFrame.maxY - height, width: width, height: height)
        setPanelFrame(newFrame, animate: animate)
    }

    private func panelFittingSize() -> (width: CGFloat, height: CGFloat)? {
        panel.contentView?.layout()
        guard let size = panel.contentView?.fittingSize else { return nil }
        return (max(size.width, 320), min(size.height, 600))
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
        let panelState = PanelState(mode: panelMode)
        let result = PanelCoordinator.handle(event: event, state: panelState)
        panelMode = result.state.mode
        execute(result.actions)
        return result.eventConsumed
    }

    @MainActor private func execute(_ actions: [PanelAction]) {
        for action in actions {
            switch action {
            case .showPanel:
                notchVisibilityWork?.cancel()
                panel.makeKeyAndOrderFront(nil)
                // Re-position after SwiftUI layout settles
                DispatchQueue.main.async { [weak self] in
                    self?.positionPanel()
                }
            case .dismissPanel:
                panel.orderOut(nil)
                previousApp = nil
                stopNavKeyMonitor()
                updateNotchVisibility(immediate: true)
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
