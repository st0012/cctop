// swiftlint:disable file_length
import AppKit
import Combine
import KeyboardShortcuts
import SwiftUI
import UserNotifications

// swiftlint:disable:next type_body_length
class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var panel: FloatingPanel!
    private var sessionManager: SessionManager!
    private var updater: UpdaterBase!
    private var pluginManager: PluginManager!
    private var historyManager: HistoryManager!
    private var navigateController = NavigateController()
    private var notchController: NotchStatusController!
    private var navKeyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var lastExternalApp: NSRunningApplication?
    private var panelMode: PanelMode = .hidden
    private var screenChangeWork: DispatchWorkItem?
    private var notchVisibilityWork: DispatchWorkItem?
    private var suppressResize = false
    private var lastRenderedCounts: StatusCounts?
    private var hasNotch = false
    private var focusLocation: NSPoint?
    private var cancellables: Set<AnyCancellable> = []
    @AppStorage("appearanceMode") var appearanceMode: String = "system"

    private enum PanelPositionKeys {
        static let positions = "panelPositions"
        // MIGRATION(v0.12.0→v0.13.0): Remove legacyOriginX, legacyTopY, migrateLegacyPanelPosition
        static let legacyOriginX = "panelCustomX"
        static let legacyTopY = "panelCustomTopY"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["notificationsEnabled": true])
        migrateLegacyPanelPosition()
        installHookBinaryIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        notchController = NotchStatusController()
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
            navigate: navigateController
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
        panel.panelDelegate = self

        applyAppearance()
        registerShortcuts()
        observeSessionUpdates()
        observeThemeChanges()
    }

    @MainActor private func registerShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in self?.togglePanel() }
        KeyboardShortcuts.onKeyUp(for: .navigate) { [weak self] in
            self?.focusLocation = NSEvent.mouseLocation
            self?.handleEvent(.navigateShortcut)
        }
        navigateController.didConfirmSubject
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.handleEvent(.navigateConfirmed) }
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
            self?.updateNotchVisibility()
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

    @MainActor private func observeThemeChanges() {
        ThemeManager.shared.$current
            .dropFirst() // skip initial value
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, let counts = self.lastRenderedCounts else { return }
                self.refreshStatusDisplay(counts: counts)
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
        focusLocation = NSEvent.mouseLocation

        let onDifferentScreen: Bool = {
            guard panelMode == .normal,
                  let click = focusLocation,
                  let clickKey = screenKey(at: click),
                  let currentKey = panelScreenKey() else { return false }
            return clickKey != currentKey
        }()

        handleEvent(.menubarIconClicked(appIsActive: NSApp.isActive, onDifferentScreen: onDifferentScreen))
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
            guard let self else { return }
            let action = NotchStatusController.resolveVisibility(
                hasNotch: self.hasNotch,
                hasBuiltinScreen: NSScreen.builtin != nil,
                appIsActive: NSApp.isActive,
                pillExists: self.notchController.pillFrame != nil,
                statusItemOccluded: self.isStatusItemOccluded
            )
            switch action {
            case .show:
                if let screen = NSScreen.builtin {
                    self.notchController.showOnScreen(screen, counts: counts)
                }
            case .keep:
                break
            case .tearDown:
                self.notchController.tearDown()
            }
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

    // MARK: - Custom panel position (per-screen)

    private func saveCustomPanelPosition(originX: CGFloat, topY: CGFloat, forScreenKey key: String) {
        var dict = savedPanelPositionsDict()
        dict[key] = ["originX": originX, "topY": topY]
        UserDefaults.standard.set(dict, forKey: PanelPositionKeys.positions)
    }

    private func clearCustomPanelPosition(forScreenKey key: String) {
        var dict = savedPanelPositionsDict()
        dict.removeValue(forKey: key)
        UserDefaults.standard.set(dict, forKey: PanelPositionKeys.positions)
    }

    private func savedPanelPositions() -> [String: (originX: CGFloat, topY: CGFloat)] {
        savedPanelPositionsDict().compactMapValues { entry in
            guard let originX = entry["originX"], let topY = entry["topY"] else { return nil }
            return (originX: originX, topY: topY)
        }
    }

    private func savedPanelPositionsDict() -> [String: [String: CGFloat]] {
        UserDefaults.standard.dictionary(forKey: PanelPositionKeys.positions)
            as? [String: [String: CGFloat]] ?? [:]
    }

    /// The screen key for the screen the panel is currently on.
    @MainActor private func panelScreenKey() -> String? {
        guard let panelScreen = panel.screen ?? NSScreen.main else { return nil }
        return panelScreen.screenKey
    }

    /// The screen key for the screen containing a point.
    private func screenKey(at point: NSPoint) -> String? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }?.screenKey
    }

    /// Migrate legacy single-position UserDefaults to per-screen dictionary.
    private func migrateLegacyPanelPosition() {
        let ud = UserDefaults.standard
        guard let originX = ud.object(forKey: PanelPositionKeys.legacyOriginX) as? Double else { return }
        let topY = ud.double(forKey: PanelPositionKeys.legacyTopY)
        let point = NSPoint(x: originX, y: topY)
        let key = screenKey(at: point) ?? NSScreen.main?.screenKey ?? "builtin"
        saveCustomPanelPosition(originX: CGFloat(originX), topY: CGFloat(topY), forScreenKey: key)
        ud.removeObject(forKey: PanelPositionKeys.legacyOriginX)
        ud.removeObject(forKey: PanelPositionKeys.legacyTopY)
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

    private var screenLayouts: [ScreenLayout] {
        NSScreen.screens.map { ScreenLayout($0) }
    }

    @MainActor private func positionPanel(animate: Bool = false) {
        guard let size = panelFittingSize() else { return }
        let clickKey = focusLocation.flatMap { screenKey(at: $0) }
            ?? panelScreenKey()
        if let frame = PanelPositioning.resolveShowPosition(
            savedPositions: savedPanelPositions(),
            clickScreenKey: clickKey,
            clickLocation: focusLocation,
            anchorRect: anchorRect(),
            panelSize: size,
            screens: screenLayouts
        ) {
            setPanelFrame(frame, animate: animate)
        }
    }

    /// The screen-space rect of the anchor (notch pill or menubar icon).
    @MainActor private func anchorRect() -> NSRect? {
        if let pillFrame = notchController.pillFrame {
            return pillFrame
        } else if let button = statusItem.button, let buttonWindow = button.window {
            return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        }
        return nil
    }

    /// Reset panel position on double-click. If the panel is on the same screen
    /// as the anchor (menubar icon / notch pill), snap to anchor. Otherwise, snap
    /// to the top-center of the panel's current screen so it doesn't jump across screens.
    @MainActor private func resetPanelToCurrentScreen(animate: Bool = false) {
        guard let size = panelFittingSize() else { return }
        let layouts = screenLayouts
        let panelIdx = (panel.screen ?? NSScreen.main).flatMap { screen in
            layouts.firstIndex { $0.frame == ScreenLayout(screen).frame }
        }
        if let frame = PanelPositioning.resolveResetPosition(
            anchorRect: anchorRect(),
            panelScreenIndex: panelIdx,
            panelSize: size,
            screens: layouts
        ) {
            setPanelFrame(frame, animate: animate)
        }
    }

    @MainActor private func positionPanelAtAnchor(animate: Bool = false) {
        guard let size = panelFittingSize() else { return }
        if let frame = PanelPositioning.resolveAnchorPosition(
            anchorRect: anchorRect(),
            clickLocation: focusLocation,
            panelSize: size,
            screens: screenLayouts
        ) {
            setPanelFrame(frame, animate: animate)
        }
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
            // Update saved position if it was clamped to new screen bounds
            if let key = self.panelScreenKey(),
               self.savedPanelPositions()[key] != nil {
                let frame = self.panel.frame
                self.saveCustomPanelPosition(
                    originX: frame.origin.x, topY: frame.maxY, forScreenKey: key
                )
            }
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @MainActor private func resizePanel(animate: Bool = false) {
        guard !suppressResize else { return }
        guard let size = panelFittingSize() else { return }
        let oldFrame = panel.frame
        let hasPositionOnCurrentScreen = panelScreenKey().map { savedPanelPositions()[$0] != nil } ?? false
        let newFrame: NSRect
        if hasPositionOnCurrentScreen {
            // Keep top-left corner stable
            newFrame = NSRect(
                x: oldFrame.origin.x, y: oldFrame.maxY - size.height,
                width: size.width, height: size.height
            )
        } else {
            // Keep midX centered, top edge stable
            newFrame = NSRect(
                x: oldFrame.midX - size.width / 2, y: oldFrame.maxY - size.height,
                width: size.width, height: size.height
            )
        }
        setPanelFrame(newFrame, animate: animate)
    }

    private func panelFittingSize() -> NSSize? {
        panel.contentView?.layout()
        guard let size = panel.contentView?.fittingSize else { return nil }
        return NSSize(width: max(size.width, 320), height: min(size.height, 600))
    }

    private func setPanelFrame(_ frame: NSRect, animate: Bool) {
        guard panel.frame != frame else { return }
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

// Hardware key codes for digit row (1-9). Using keyCode instead of
// event.characters so digit navigation works with non-English input
// methods (e.g. Zhuyin where "1" produces "ㄅ").
private let digitKeyCodeMap: [UInt16: Int] = [
    18: 1, 19: 2, 20: 3, 21: 4, 23: 5,
    22: 6, 26: 7, 28: 8, 25: 9
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

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    @MainActor private func execute(_ actions: [PanelAction]) {
        for action in actions {
            switch action {
            case .showPanel:
                notchVisibilityWork?.cancel()
                panel.makeKeyAndOrderFront(nil)
                // Re-position after SwiftUI layout settles
                DispatchQueue.main.async { [weak self] in
                    self?.positionPanel()
                    self?.focusLocation = nil
                }
            case .dismissPanel:
                panel.orderOut(nil)
                focusLocation = nil
                previousApp = nil
                stopNavKeyMonitor()
                updateNotchVisibility(immediate: true)
            case .navigatePanel:
                panel.makeKeyAndOrderFront(nil)
            case .positionPanel:
                positionPanel()
                // If panel didn't land on target screen, clear stale position and retry
                if let click = focusLocation,
                   let clickKey = screenKey(at: click),
                   panelScreenKey() != clickKey {
                    clearCustomPanelPosition(forScreenKey: clickKey)
                    positionPanel()
                }
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
            case .startNavigateMode(let panelWasClosed):
                navigateController.activate(
                    sessions: sessionManager.sessions,
                    previousApp: NSWorkspace.shared.frontmostApplication,
                    panelWasClosed: panelWasClosed
                )
                navigateController.startTimeout { [weak self] in
                    self?.handleEvent(.navigateTimedOut)
                }
            case .endNavigateMode:
                navigateController.deactivate()
            }
        }
    }

    @MainActor private func jumpToSession(index: Int) {
        guard index < navigateController.frozenSessions.count else { return }
        focusTerminal(session: navigateController.frozenSessions[index])
        handleEvent(.navigateConfirmed)
    }

    private func startNavKeyMonitor() {
        guard navKeyMonitor == nil else { return }
        navKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }

            // Navigate: digit keys jump to session (use keyCode for IME compatibility)
            if self.navigateController.isActive,
               let digit = digitKeyCodeMap[event.keyCode] {
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
                if self.navigateController.isActive { self.navigateController.cancelTimeout() }
                let consumed = self.handleEvent(.navKey(navAction))
                return consumed ? nil : event
            }

            // Navigate: any other key exits
            if self.navigateController.isActive {
                DispatchQueue.main.async { self.handleEvent(.unrecognizedKeyDuringNavigate) }
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
        navigateController.navActionSubject.send(action)
    }
}
// MARK: - FloatingPanelDelegate
extension AppDelegate: FloatingPanelDelegate {
    @MainActor func panelDidDrag(originX: CGFloat, topY: CGFloat) {
        guard let key = panelScreenKey() else { return }
        saveCustomPanelPosition(originX: originX, topY: topY, forScreenKey: key)
    }

    @MainActor func panelDidRequestReset() {
        if let key = panelScreenKey() {
            clearCustomPanelPosition(forScreenKey: key)
        }
        resetPanelToCurrentScreen(animate: true)
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
