import AppKit
import Carbon
import Combine
import KeyboardShortcuts
import os.log
import SwiftUI
import UserNotifications

class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var statusItem: NSStatusItem!
    var panel: FloatingPanel!
    var sessionManager: SessionManager!
    var updater: UpdaterBase!
    var pluginManager: PluginManager!
    private var historyManager: HistoryManager!
    private var cleanupManager: WorktreeCleanupManager!
    private var cleanupRefreshGate: WorktreeCleanupRefreshGate!
    private let cleanupRemovalService = WorktreeRemovalService.live()
    var navigateController = NavigateController()
    var notchController: NotchStatusController!
    var navKeyMonitor: Any?
    var previousApp: NSRunningApplication?
    var lastExternalApp: NSRunningApplication?
    var panelMode: PanelMode = .hidden
    var screenChangeWork: DispatchWorkItem?
    var notchVisibilityWork: DispatchWorkItem?
    var suppressResize = false
    private var lastRenderedCounts: StatusCounts?
    var hasNotch = false
    var focusLocation: NSPoint?
    private var cancellables: Set<AnyCancellable> = []
    private let notificationPermissionReconciler = NotificationPermissionController()
    private let displayStateWriter = DisplayStateWriter()
    var pendingURL: URL?
    var isFullyLaunched = false
    @AppStorage("appearanceMode") var appearanceMode: String = "system"

    let panelGeometry = PanelGeometryModel(store: UserDefaultsPanelPositionStore())

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
}

// MARK: - Worktree cleanup actions
extension AppDelegate {
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

    @MainActor func updateCleanupPanelVisibility() {
        cleanupRefreshGate.setPanelVisible(panel?.isVisible == true)
    }
}

// MARK: - Status item and notch
extension AppDelegate {
    @MainActor func refreshStatusDisplay(counts: StatusCounts) {
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

    @MainActor @objc func togglePanel() {
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
    @MainActor func updateNotchVisibility(immediate: Bool = false) {
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
}

// MARK: - UNUserNotificationCenterDelegate
extension AppDelegate {
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
