import SwiftUI

extension FocusStrategy {
    var actionTitle: String {
        switch self {
        case .openWithApp(let bundleID, _):
            let name = HostApp.from(bundleIdentifier: bundleID)?.displayName ?? "App"
            return "Open Project in \(name)"
        case .iTerm2:
            return "Focus iTerm2 Pane"
        case .kitty:
            return "Focus Kitty Window"
        case .ghostty:
            return "Focus Ghostty Terminal"
        case .appleTerminal:
            return "Focus Terminal Tab"
        case .activateByName(let name):
            let host = HostApp.from(editorName: name)
            if host == .cmux { return "Focus cmux" }
            let displayName = host == .unknown ? name : host.displayName
            return "Bring \(displayName) Forward"
        case .activateByBundleID(let bundleID):
            let host = HostApp.from(bundleIdentifier: bundleID)
            if host == .cmux { return "Focus cmux" }
            let name = host?.displayName ?? "App"
            return "Bring \(name) Forward"
        case .openURL(let url, _):
            if url.scheme?.lowercased() == "codex" {
                return "Focus Codex Task"
            }
            if url.scheme?.lowercased() == "cmux" {
                let target = url.pathComponents.contains("surface") ? "Surface" : "Pane"
                return "Focus cmux \(target)"
            }
            return "Open Session"
        case .openInFinder:
            return "Open Project in Finder"
        case .unavailable:
            return "Why Focus Is Unavailable"
        }
    }
}

struct PanelSessionRow: Identifiable {
    let slot: Int
    let userSession: UserSession
    let id: SessionIdentityPolicy.LogicalIdentity
    var presentation: PanelSessionPresentation = .standard

    /// Direct actions use the exact data selected for this rendered row.
    var session: SessionData { userSession.displayRecord.data }
}

enum PanelSessionPresentation: Equatable {
    case standard
    case acknowledged
    case dropped

    var statusLabel: String? {
        switch self {
        case .standard: nil
        case .acknowledged: "Acknowledged"
        case .dropped: "Dropped"
        }
    }
}

extension PopupView {
    var isNavigateActive: Bool { navigate?.isActive ?? false }
    var hasMultipleSources: Bool {
        Set((userSessions + droppedUserSessions).map(\.agentBadge)).count > 1
    }

    var currentActiveUserSessions: [UserSession] {
        SessionDisplayPolicy.activeSessions(from: userSessions)
    }

    var activeSessionRows: [PanelSessionRow] {
        guard let identities = navigate?.activeSessionIdentitySnapshot else {
            return currentActiveUserSessions.enumerated().map { index, userSession in
                PanelSessionRow(
                    slot: index,
                    userSession: userSession,
                    id: userSession.identity
                )
            }
        }
        return identities.enumerated().compactMap { index, identity in
            guard let userSession = currentUserSession(for: identity, in: .active) else { return nil }
            return PanelSessionRow(
                slot: index,
                userSession: userSession,
                id: identity
            )
        }
    }

    var currentIdleUserSessions: [UserSession] {
        SessionDisplayPolicy.idleSessions(from: userSessions)
    }

    var idleSessionRows: [PanelSessionRow] {
        currentIdleUserSessions.enumerated().map { index, userSession in
            PanelSessionRow(
                slot: index,
                userSession: userSession,
                id: userSession.identity
            )
        }
    }

    var currentAcknowledgedUserSessions: [UserSession] {
        userSessions.filter { userSession in
            guard let cctopSessionID = userSession.identity.cctopSessionID else { return false }
            return acknowledgedSessionIDs.contains(cctopSessionID)
        }
    }

    var acknowledgedSessionRows: [PanelSessionRow] {
        currentAcknowledgedUserSessions.enumerated().map { index, userSession in
            PanelSessionRow(
                slot: index,
                userSession: userSession,
                id: userSession.identity,
                presentation: .acknowledged
            )
        }
    }

    var droppedSessionRows: [PanelSessionRow] {
        droppedUserSessions.enumerated().map { index, userSession in
            PanelSessionRow(
                slot: index,
                userSession: userSession,
                id: userSession.identity,
                presentation: .dropped
            )
        }
    }

    @ViewBuilder
    var acknowledgedContent: some View {
        if acknowledgedSessionRows.isEmpty {
            noAcknowledgedSessionsContent
        } else {
            sessionList(acknowledgedSessionRows, tab: .acknowledged)
        }
    }

    @ViewBuilder
    var droppedContent: some View {
        if droppedSessionRows.isEmpty {
            noDroppedSessionsContent
        } else {
            sessionList(droppedSessionRows, tab: .dropped)
        }
    }

    func sessionList(
        _ rows: [PanelSessionRow],
        tab: PopupTab,
        showNavigateNumbers: Bool = false
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(rows) { row in
                        sessionRow(row, showNavigateNumbers: showNavigateNumbers)
                    }
                }
                .padding(.bottom, AppChrome.listVerticalPadding)
            }
            .frame(maxHeight: AppChrome.overlayMinimumContentHeight)
            .onChange(of: selectedSessionIdentity) { identity in
                guard selectedTab == tab, let identity else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(identity, anchor: .center)
                }
            }
        }
    }

    // swiftlint:disable:next function_body_length
    private func sessionRow(_ row: PanelSessionRow, showNavigateNumbers: Bool) -> some View {
        let focusStrategy = resolveFocusStrategy(session: row.session)
        let focusActionTitle = focusStrategy.actionTitle
        return SessionCardView(
            session: row.session,
            navigateIndex: showNavigateNumbers && isNavigateActive ? row.slot + 1 : nil,
            showSourceBadge: hasMultipleSources,
            isSelected: selectedSessionIdentity == row.id,
            relativeTimeNow: relativeTimeNow,
            presentationStatusLabel: row.presentation.statusLabel
        )
        .id(row.id)
        .onTapGesture { focusSession(row.session) }
        .contextMenu {
            Button { focusSession(row.session) } label: {
                Label(focusActionTitle, systemImage: "scope")
            }
            switch focusStrategy {
            case .openInFinder:
                EmptyView()
            default:
                Button { openInFinder(path: row.session.projectPath) } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
            }
            Button { copyPath(row.session.projectPath) } label: {
                Label("Copy Project Path", systemImage: "doc.on.doc")
            }
            if row.presentation == .dropped {
                Divider()
                Button { restoreDroppedSession(row) } label: {
                    Label("Restore Session", systemImage: "arrow.uturn.backward.circle")
                }
                .disabled(row.userSession.identity.cctopSessionID == nil)
            } else {
                if row.session.status.needsAttention {
                    Divider()
                    Button { acknowledgeSession(row) } label: {
                        Label("Acknowledge", systemImage: "checkmark.circle")
                    }
                    .disabled(row.userSession.identity.cctopSessionID == nil)
                }
                Divider()
                Button { dropSession(row) } label: {
                    Label("Drop Until Next Activity", systemImage: "xmark.circle")
                }
                .disabled(row.userSession.identity.cctopSessionID == nil)
            }
            Divider()
            Button { requestHideSession(row) } label: {
                Label("Hide Session", systemImage: "eye.slash")
            }
            .disabled(row.userSession.identity.cctopSessionID == nil)
        }
        .help(focusActionTitle)
        .accessibilityActions {
            if row.presentation == .dropped {
                Button("Restore Session") { restoreDroppedSession(row) }
                    .disabled(row.userSession.identity.cctopSessionID == nil)
            } else {
                if row.session.status.needsAttention {
                    Button("Acknowledge") { acknowledgeSession(row) }
                        .disabled(row.userSession.identity.cctopSessionID == nil)
                }
                Button("Drop Until Next Activity") { dropSession(row) }
                    .disabled(row.userSession.identity.cctopSessionID == nil)
            }
            Button("Hide Session") { requestHideSession(row) }
                .disabled(row.userSession.identity.cctopSessionID == nil)
        }
    }

    func acknowledgeSession(_ row: PanelSessionRow) {
        guard row.session.status.needsAttention,
              row.userSession.identity.cctopSessionID != nil else { return }
        onAcknowledgeSession(row.userSession.identity)
    }

    func dropSession(_ row: PanelSessionRow) {
        guard row.userSession.identity.cctopSessionID != nil else { return }
        onDropSession(row.userSession.identity)
        selectedIndex = nil
        selectedSessionIdentity = nil
    }

    func restoreDroppedSession(_ row: PanelSessionRow) {
        guard row.presentation == .dropped,
              row.userSession.identity.cctopSessionID != nil else { return }
        onRestoreDroppedSession(row.userSession.identity)
        selectedIndex = nil
        selectedSessionIdentity = nil
    }

    func moveSessionSelection(by delta: Int, in rows: [PanelSessionRow]) {
        guard !rows.isEmpty else { return }
        let currentIndex = selectedSessionIdentity.flatMap { identity in
            rows.firstIndex { $0.id == identity }
        }
        let nextIndex = currentIndex.map {
            ($0 + delta + rows.count) % rows.count
        } ?? (delta > 0 ? 0 : rows.count - 1)
        selectedSessionIdentity = rows[nextIndex].id
    }

    func confirmSessionSelection() {
        guard let identity = selectedSessionIdentity else { return }
        guard let userSession = currentUserSession(for: identity, in: selectedTab) else { return }
        focusSession(userSession.focusTarget)
        if isNavigateActive { navigate?.didConfirmSubject.send() }
    }

    func currentUserSession(
        for identity: SessionIdentityPolicy.LogicalIdentity,
        in tab: PopupTab
    ) -> UserSession? {
        let candidates: [UserSession]
        switch tab {
        case .active:
            candidates = SessionDisplayPolicy.activeSessions(from: userSessions)
        case .idle:
            candidates = SessionDisplayPolicy.idleSessions(from: userSessions)
        case .acknowledged:
            candidates = currentAcknowledgedUserSessions
        case .dropped:
            candidates = droppedUserSessions
        case .recent, .cleanup:
            return nil
        }
        return FocusTargetResolver.currentUserSession(for: identity, in: candidates)
    }
}
