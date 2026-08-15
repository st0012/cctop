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

    /// Direct actions use the exact data selected for this rendered row.
    var session: SessionData { userSession.displayRecord.data }
}

extension PopupView {
    var isNavigateActive: Bool { navigate?.isActive ?? false }
    var hasMultipleSources: Bool { Set(userSessions.map(\.agentBadge)).count > 1 }

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

    private func sessionRow(_ row: PanelSessionRow, showNavigateNumbers: Bool) -> some View {
        let focusStrategy = resolveFocusStrategy(session: row.session)
        let focusActionTitle = focusStrategy.actionTitle
        return SessionCardView(
            session: row.session,
            navigateIndex: showNavigateNumbers && isNavigateActive ? row.slot + 1 : nil,
            showSourceBadge: hasMultipleSources,
            isSelected: selectedSessionIdentity == row.id,
            relativeTimeNow: relativeTimeNow
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
            Divider()
            Button { requestHideSession(row) } label: {
                Label("Hide Session", systemImage: "eye.slash")
            }
            .disabled(row.userSession.identity.cctopSessionID == nil)
        }
        .help(focusActionTitle)
        .accessibilityActions {
            Button("Hide Session") { requestHideSession(row) }
                .disabled(row.userSession.identity.cctopSessionID == nil)
        }
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
        case .recent, .cleanup:
            return nil
        }
        return FocusTargetResolver.currentUserSession(for: identity, in: candidates)
    }
}
