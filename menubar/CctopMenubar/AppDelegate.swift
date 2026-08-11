// swiftlint:disable file_length
import AppKit
import Carbon
import Combine
import KeyboardShortcuts
import os.log
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
    private var cleanupManager: WorktreeCleanupManager!
    private var cleanupRefreshGate: WorktreeCleanupRefreshGate!
    private let cleanupRemovalService = WorktreeRemovalService.live()
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
    private let notificationPermissionReconciler = NotificationPermissionController()
    private let displayStateWriter = DisplayStateWriter()
    private var pendingURL: URL?
    private var isFullyLaunched = false
    @AppStorage("appearanceMode") var appearanceMode: String = "system"

    private let panelGeometry = PanelGeometryModel(store: UserDefaultsPanelPositionStore())

    private enum PanelPositionKeys {
        // MIGRATION(v0.12.0→v0.13.0): Remove legacyOriginX, legacyTopY, migrateLegacyPanelPosition
        static let legacyOriginX = "panelCustomX"
        static let legacyTopY = "panelCustomTopY"
    }

    private static var isXcodeTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CCTOP_XCODE_TEST_HOST"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard !Self.isXcodeTestHost else { return }
        registerURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isXcodeTestHost else { return }
        UserDefaults.standard.register(defaults: ["notificationsEnabled": true])
        notificationPermissionReconciler.refresh()
        migrateLegacyPanelPosition()
        installHookBinaryIfNeeded()
        UNUserNotificationCenter.current().delegate = self
        notchController = NotchStatusController()
        notchController.onPillClicked = { [weak self] in self?.togglePanel() }
        historyManager = HistoryManager()
        sessionManager = SessionManager(historyManager: historyManager)
        cleanupManager = WorktreeCleanupManager()
        cleanupRefreshGate = WorktreeCleanupRefreshGate(manager: cleanupManager)
        sessionManager.cleanupRefreshHandler = { [weak self] cleanupSources, activePaths in
            self?.cleanupRefreshGate.updateSources(cleanupSources, activeProjectPaths: activePaths)
        }
        cleanupRefreshGate.updateSources(
            sessionManager.cleanupSources,
            activeProjectPaths: sessionManager.cleanupActiveProjectPaths
        )
        updater = makeUpdater()
        pluginManager = PluginManager()

        setupStatusItem()
        hasNotch = NSScreen.builtin?.hasPhysicalNotch == true

        let contentView = makePanelContentView()
        let hostingView = NSHostingView(rootView: contentView)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.layer?.cornerRadius = AppChrome.panelCornerRadius
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

        isFullyLaunched = true
        if let pendingURL {
            self.pendingURL = nil
            handleURLCommand(pendingURL)
        }
    }

    private func makePanelContentView() -> PanelContentView {
        PanelContentView(
            sessionManager: sessionManager,
            historyManager: historyManager,
            cleanupManager: cleanupManager,
            cleanupRefreshGate: cleanupRefreshGate,
            updater: updater,
            pluginManager: pluginManager,
            navigate: navigateController,
            onOpenUpdater: { [weak self] in
                Task { @MainActor in self?.openUpdaterFromPanel() }
            },
            onSelectCleanupRemovalAction: { [weak self] candidate in
                await self?.selectCleanupRemovalAction(candidate) ?? .blocked(candidate, "Cleanup is unavailable right now.")
            },
            onExecuteCleanupRemovalAction: { [weak self] action in
                await self?.executeCleanupRemovalAction(action) ?? .refused(action.candidate)
            },
            onCleanupTabVisible: { [weak self] in
                Task { @MainActor in self?.setCleanupTabSelected(true) }
            },
            onCleanupTabHidden: { [weak self] in
                Task { @MainActor in self?.setCleanupTabSelected(false) }
            },
            onLayoutChanged: { [weak self] in
                Task { @MainActor in self?.resizePanel(animate: true) }
            }
        )
    }

    @MainActor private func selectCleanupRemovalAction(
        _ candidate: WorktreeCleanupCandidate
    ) async -> WorktreeRemovalService.RemovalAction {
        let cleanupSnapshot = sessionManager.cleanupSnapshotForRemoval()
        let removalService = cleanupRemovalService
        let action = await Task.detached(priority: .utility) {
            removalService.selectedAction(
                for: candidate,
                cleanupSources: cleanupSnapshot.cleanupSources,
                activeProjectPaths: cleanupSnapshot.activeProjectPaths
            )
        }.value
        if case .blocked = action {
            cleanupRefreshGate.refreshIfVisible(force: true)
        }
        return action
    }

    @MainActor private func executeCleanupRemovalAction(
        _ action: WorktreeRemovalService.RemovalAction
    ) async -> WorktreeRemovalService.RemovalResult {
        let cleanupSnapshot = sessionManager.cleanupSnapshotForRemoval()
        let removalService = cleanupRemovalService
        let result = await Task.detached(priority: .utility) {
            removalService.executeConfirmed(
                action,
                cleanupSources: cleanupSnapshot.cleanupSources,
                activeProjectPaths: cleanupSnapshot.activeProjectPaths
            )
        }.value

        switch result {
        case .removed, .refused:
            await MainActor.run {
                cleanupRefreshGate.refreshIfVisible(force: true)
            }
        case .failed:
            break
        }
        return result
    }

    @MainActor private func setCleanupTabSelected(_ selected: Bool) {
        cleanupRefreshGate.setCleanupTabSelected(selected)
    }

    @MainActor private func updateCleanupPanelVisibility() {
        cleanupRefreshGate.setPanelVisible(panel?.isVisible == true)
    }

    @MainActor private func registerShortcuts() {
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in self?.togglePanel() }
        KeyboardShortcuts.onKeyUp(for: .navigate) { [weak self] in
            guard let self else { return }
            self.focusLocation = NSEvent.mouseLocation
            self.handleEvent(.navigateShortcut(panelVisibleInActiveSpace: self.panelVisibleInActiveSpace))
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
    }

    @MainActor private func observeSessionUpdates() {
        sessionManager.$userSessions
            .receive(on: RunLoop.main)
            .sink { [weak self] userSessions in
                guard let self else { return }
                let counts = StatusCounts(userSessions: userSessions)

                self.displayStateWriter.write(
                    userSessions: userSessions,
                    theme: ThemeManager.shared.current,
                    appRunning: true
                )

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
                guard let self else { return }
                self.displayStateWriter.write(
                    userSessions: self.sessionManager.userSessions,
                    theme: ThemeManager.shared.current,
                    appRunning: true
                )
                guard let counts = self.lastRenderedCounts else { return }
                self.refreshStatusDisplay(counts: counts)
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let sessionManager else { return }
        displayStateWriter.write(
            userSessions: sessionManager.userSessions,
            theme: ThemeManager.shared.current,
            appRunning: false
        )
    }

    @MainActor private func refreshStatusDisplay(counts: StatusCounts) {
        lastRenderedCounts = counts
        statusItem.button?.image = MenubarIconRenderer.render(counts: counts)
        notchController.update(counts: counts)
        updateNotchVisibility()
        statusItem.button?.setAccessibilityLabel(counts.accessibilityLabel)
    }

    @MainActor private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = MenubarIconRenderer.render(counts: .zero)
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

        handleEvent(.menubarIconClicked(
            appIsActive: NSApp.isActive,
            onDifferentScreen: onDifferentScreen,
            panelVisibleInActiveSpace: panelVisibleInActiveSpace
        ))
    }

    @MainActor private var panelVisibleInActiveSpace: Bool {
        panel.isVisible && panel.isOnActiveSpace
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

    /// The screen key for the screen the panel is currently on.
    @MainActor private func panelScreenKey() -> String? {
        PanelPositioning.screenKey(forPanelFrame: panel.frame, in: screenLayouts)
    }

    /// The screen key for the screen containing a point.
    private func screenKey(at point: NSPoint) -> String? {
        PanelPositioning.screenKey(containing: point, in: screenLayouts)
    }

    /// Migrate legacy single-position UserDefaults to per-screen dictionary.
    private func migrateLegacyPanelPosition() {
        let ud = UserDefaults.standard
        guard let originX = ud.object(forKey: PanelPositionKeys.legacyOriginX) as? Double else { return }
        let topY = ud.double(forKey: PanelPositionKeys.legacyTopY)
        panelGeometry.saveLegacyPosition(
            originX: CGFloat(originX), topY: CGFloat(topY),
            screens: screenLayouts,
            fallbackScreenKey: NSScreen.main?.screenKey
        )
        ud.removeObject(forKey: PanelPositionKeys.legacyOriginX)
        ud.removeObject(forKey: PanelPositionKeys.legacyTopY)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            sessionManager.loadSessions()
            if let focusTarget = Self.notificationFocusTarget(
                matchingUserInfo: userInfo,
                in: sessionManager.userSessions
            ) {
                focusTerminal(session: focusTarget)
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

    nonisolated static func notificationFocusTarget(
        matchingUserInfo userInfo: [AnyHashable: Any],
        in userSessions: [UserSession]
    ) -> SessionData? {
        guard let cctopSessionID = SessionIdentityPolicy.notificationCctopSessionID(
            matchingNotificationUserInfo: userInfo,
            in: userSessions
        ) else { return nil }
        return FocusTargetResolver.currentUserSession(
            forCctopSessionID: cctopSessionID,
            in: SessionDisplayPolicy.activeSessions(from: userSessions)
        )?.focusTarget
    }

    private var screenLayouts: [ScreenLayout] {
        NSScreen.screens.map { ScreenLayout($0) }
    }

    @MainActor private func positionPanel(animate: Bool = false) {
        guard let size = panelFittingSize() else { return }
        let clickKey = focusLocation.flatMap { screenKey(at: $0) }
            ?? panelScreenKey()
        if let frame = panelGeometry.showFrame(
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
        notchController.pillFrame ?? menubarIconRect()
    }

    /// The screen-space rect of the menubar icon, even when the notch pill
    /// is the anchor (the pill only exists on the built-in screen).
    @MainActor private func menubarIconRect() -> NSRect? {
        guard let button = statusItem.button, let buttonWindow = button.window else { return nil }
        return buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
    }

    /// Reset panel position on double-click. If the panel is on the same screen
    /// as the anchor (menubar icon / notch pill), snap to anchor. Otherwise, snap
    /// under the menubar icon's mirrored position on the panel's current screen
    /// so it doesn't jump across screens.
    @MainActor private func resetPanelToCurrentScreen(animate: Bool = false) {
        guard let size = panelFittingSize() else { return }
        let layouts = screenLayouts
        let panelIdx = PanelPositioning.screenIndex(forPanelFrame: panel.frame, in: layouts)
        if let frame = PanelPositioning.resolveResetPosition(
            anchorRect: anchorRect(),
            menubarIconRect: menubarIconRect(),
            panelScreenIndex: panelIdx,
            panelSize: size,
            screens: layouts
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
            self.refreshStatusDisplay(counts: StatusCounts(userSessions: self.sessionManager.userSessions))
            guard self.panel.isVisible else { return }
            // A click location captured before the debounce must not drive
            // screen-change repositioning; clearing it keeps the key below
            // and positionPanel's internal key identical.
            self.focusLocation = nil
            self.positionPanel(animate: false)
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    @MainActor private func resizePanel(animate: Bool = false) {
        guard !suppressResize else { return }
        guard let size = panelFittingSize() else { return }
        let newFrame = panelGeometry.resizedFrame(
            from: panel.frame, to: size, panelScreenKey: panelScreenKey()
        )
        setPanelFrame(newFrame, animate: animate)
    }

    private func panelFittingSize() -> NSSize? {
        panel.contentView?.layout()
        guard let size = panel.contentView?.fittingSize else { return nil }
        return NSSize(width: max(size.width, 320), height: min(size.height, 600))
    }

    private func setPanelFrame(_ frame: NSRect, animate: Bool) {
        guard !panel.frame.isNearlyEqual(to: frame) else { return }
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

private extension NSRect {
    func isNearlyEqual(to other: NSRect) -> Bool {
        abs(origin.x - other.origin.x) < 0.5 &&
            abs(origin.y - other.origin.y) < 0.5 &&
            abs(size.width - other.size.width) < 0.5 &&
            abs(size.height - other.size.height) < 0.5
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

    @MainActor private func execute(_ actions: [PanelAction]) {
        for action in actions {
            switch action {
            case .showPanel:
                notchVisibilityWork?.cancel()
                // Plugin/hook state can change outside the app (e.g. trusting
                // Codex hooks in Codex itself) — re-read it on every open.
                pluginManager.refresh()
                panel.makeKeyAndOrderFront(nil)
                updateCleanupPanelVisibility()
                // Re-position after SwiftUI layout settles
                DispatchQueue.main.async { [weak self] in
                    self?.positionPanel()
                    self?.focusLocation = nil
                }
            case .dismissPanel:
                dismissPanel()
            case .navigatePanel:
                panel.makeKeyAndOrderFront(nil)
                updateCleanupPanelVisibility()
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
            case .startNavigateMode:
                navigateController.activate(
                    userSessions: SessionDisplayPolicy.activeSessions(from: sessionManager.userSessions)
                )
                navigateController.startTimeout { [weak self] in
                    self?.handleEvent(.navigateTimedOut)
                }
            case .endNavigateMode:
                navigateController.deactivate()
            }
        }
    }

    @MainActor private func dismissPanel() {
        panel.orderOut(nil)
        updateCleanupPanelVisibility()
        focusLocation = nil
        previousApp = nil
        stopNavKeyMonitor()
        updateNotchVisibility(immediate: true)
    }

    @MainActor private func openUpdaterFromPanel() {
        if navigateController.isActive {
            navigateController.deactivate()
            postNavAction(.reset)
        }
        panelMode = .hidden
        dismissPanel()
        updater.checkForUpdates()
    }

    @MainActor private func jumpToSession(index: Int) {
        guard let identity = navigateController.sessionIdentity(at: index) else { return }
        let currentUserSessions = SessionDisplayPolicy.activeSessions(from: sessionManager.userSessions)
        guard let userSession = FocusTargetResolver.currentUserSession(
            for: identity,
            in: currentUserSessions
        ) else { return }
        focusTerminal(session: userSession.focusTarget)
        handleEvent(.navigateConfirmed)
    }

    private func startNavKeyMonitor() {
        guard navKeyMonitor == nil else { return }
        navKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.panel.isVisible else { return event }

            // Navigate: digit keys jump to session (use keyCode for IME compatibility)
            if self.navigateController.isActive,
               let digit = digitKeyCodeMap[event.keyCode] {
                let index = digit - 1
                DispatchQueue.main.async { self.jumpToSession(index: index) }
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
        panelGeometry.saveUserDraggedPosition(
            originX: originX,
            topY: topY,
            panelSize: panel.frame.size,
            screens: screenLayouts
        )
    }

    @MainActor func panelDidRequestReset() {
        panelGeometry.clearUserPosition(forPanelFrame: panel.frame, screens: screenLayouts)
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
// MARK: - URL scheme handling (cctop://)
extension AppDelegate {
    /// Registers a handler for the `cctop://` URL scheme so the panel can be
    /// toggled programmatically — e.g. `open cctop://toggle` from the shell or
    /// any automation tool. This avoids needing a global hotkey or a menubar click.
    @MainActor func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(
        _ event: NSAppleEventDescriptor, withReplyEvent _: NSAppleEventDescriptor
    ) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string) else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.isFullyLaunched else {
                self.pendingURL = url
                return
            }
            self.handleURLCommand(url)
        }
    }

    @MainActor private func handleURLCommand(_ url: URL) {
        guard url.scheme?.lowercased() == "cctop" else { return }
        let command = Self.urlCommand(from: url)
        switch command {
        case "toggle":
            togglePanel()
        case "focus":
            guard let cctopSessionID = Self.focusSessionID(from: url),
                  CctopSessionID.isValid(cctopSessionID) else {
                Self.urlLogger.notice("Ignored malformed cctop focus command")
                return
            }
            let initialUserSessions = sessionManager.userSessions
            let initialActiveUserSessions = SessionDisplayPolicy.activeSessions(from: initialUserSessions)
            if let userSession = FocusTargetResolver.currentUserSession(
                forCctopSessionID: cctopSessionID,
                in: initialActiveUserSessions
            ) {
                focusTerminal(session: userSession.focusTarget)
                return
            }
            let displayState = DisplayStateWriter.currentPublishedState()
            logFocusTargetMissBeforeRefresh(
                requestedID: cctopSessionID,
                userSessions: initialUserSessions,
                activeUserSessions: initialActiveUserSessions,
                displayState: displayState
            )

            let refreshStart = ProcessInfo.processInfo.systemUptime
            sessionManager.loadSessions()
            let refreshElapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - refreshStart) * 1_000
            let refreshedUserSessions = sessionManager.userSessions
            let refreshedActiveUserSessions = SessionDisplayPolicy.activeSessions(from: refreshedUserSessions)
            let resolvedUserSession = FocusTargetResolver.currentUserSession(
                forCctopSessionID: cctopSessionID,
                in: refreshedActiveUserSessions
            )
            logFocusTargetRefreshOutcome(
                outcome: resolvedUserSession == nil ? "final_missing" : "recovered_after_refresh",
                requestedID: cctopSessionID,
                userSessions: refreshedUserSessions,
                activeUserSessions: refreshedActiveUserSessions,
                refreshElapsedMilliseconds: refreshElapsedMilliseconds
            )
            guard let resolvedUserSession else { return }
            focusTerminal(session: resolvedUserSession.focusTarget)
        default:
            break
        }
    }

    nonisolated static func urlCommand(from url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let host = components?.host, !host.isEmpty { return host }
        return (components?.path ?? url.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    nonisolated static func focusSessionID(from url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let value = components.queryItems?.first(where: { $0.name == "sid" })?.value,
              !value.isEmpty else { return nil }
        return value
    }

    private func logFocusTargetMissBeforeRefresh(
        requestedID: String,
        userSessions: [UserSession],
        activeUserSessions: [UserSession],
        displayState: DisplayState?
    ) {
        let processPID = ProcessInfo.processInfo.processIdentifier
        let processStartTime = SessionData.processStartTime(pid: UInt32(processPID))
        let appVersion = Bundle.main.appVersion.isEmpty ? "unavailable" : Bundle.main.appVersion
        let userSessionMatches = userSessions.filter { $0.identity.cctopSessionID == requestedID }
        let processStartValue = processStartTime.map { String($0) } ?? "unavailable"
        let displayGeneratedAt = displayState?.generatedAt ?? "unavailable"
        let displayOwnerPID = displayState.flatMap(\.appPID).map { String($0) } ?? "unavailable"
        let displayOwnerStartTime = displayState.flatMap(\.appStartTime).map { String($0) } ?? "unavailable"
        let displaySessionCount = displayState.map { String($0.sessions.count) } ?? "unavailable"
        let displayMatchCount = displayState.map {
            String($0.sessions.count { $0.cctopSessionId == requestedID })
        } ?? "unavailable"

        Self.urlLogger.notice(
            """
            event=focus_target_stale route=cctop_url source=launch_services phase=pre_refresh outcome=stale_detected \
            requested_cctop_session_id=\(requestedID, privacy: .private(mask: .hash)) \
            app_version=\(appVersion, privacy: .public) app_pid=\(processPID, privacy: .public) \
            app_start_time=\(processStartValue, privacy: .public) \
            user_session_count=\(userSessions.count, privacy: .public) \
            focus_eligible_user_session_count=\(activeUserSessions.count, privacy: .public) \
            requested_id_user_session_matches=\(userSessionMatches.count, privacy: .public) \
            display_state_generated_at=\(displayGeneratedAt, privacy: .public) \
            display_state_owner_pid=\(displayOwnerPID, privacy: .public) \
            display_state_owner_start_time=\(displayOwnerStartTime, privacy: .public) \
            display_state_session_count=\(displaySessionCount, privacy: .public) \
            display_state_requested_id_matches=\(displayMatchCount, privacy: .public)
            """
        )
    }

    private func logFocusTargetRefreshOutcome(
        outcome: String,
        requestedID: String,
        userSessions: [UserSession],
        activeUserSessions: [UserSession],
        refreshElapsedMilliseconds: Double
    ) {
        let userSessionMatchCount = userSessions.count { $0.identity.cctopSessionID == requestedID }
        let activeUserSessionMatchCount = activeUserSessions.count { $0.identity.cctopSessionID == requestedID }
        let elapsed = String(format: "%.3f", refreshElapsedMilliseconds)

        Self.urlLogger.notice(
            """
            event=focus_target_stale route=cctop_url source=launch_services phase=post_refresh \
            outcome=\(outcome, privacy: .public) \
            requested_cctop_session_id=\(requestedID, privacy: .private(mask: .hash)) \
            refresh_elapsed_ms=\(elapsed, privacy: .public) \
            user_session_count=\(userSessions.count, privacy: .public) \
            focus_eligible_user_session_count=\(activeUserSessions.count, privacy: .public) \
            requested_id_user_session_matches=\(userSessionMatchCount, privacy: .public) \
            requested_id_active_user_session_matches=\(activeUserSessionMatchCount, privacy: .public)
            """
        )
    }

    private static let urlLogger = Logger(
        subsystem: "com.st0012.CctopMenubar",
        category: "URLCommands"
    )
}
