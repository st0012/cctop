import AppKit
import Carbon
import os.log

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

    @MainActor func handleURLCommand(_ url: URL) {
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
