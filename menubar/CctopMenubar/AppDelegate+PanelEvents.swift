import AppKit

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

    @MainActor func openUpdaterFromPanel() {
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
