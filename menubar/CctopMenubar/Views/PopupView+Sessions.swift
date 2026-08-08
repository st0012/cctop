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
    let session: Session
    let id: SessionIdentityPolicy.LogicalIdentity
}

extension PopupView {
    var isNavigateActive: Bool { navigate?.isActive ?? false }
    var hasMultipleSources: Bool { Set(sessions.map(\.agentBadge)).count > 1 }

    var currentActiveSessions: [Session] {
        SessionDisplayPolicy.activeSessions(from: sessions)
    }

    var activeSessionRows: [PanelSessionRow] {
        guard let identities = navigate?.activeSessionIdentitySnapshot else {
            return currentActiveSessions.enumerated().map { index, session in
                PanelSessionRow(
                    slot: index,
                    session: session,
                    id: SessionIdentityPolicy.logicalIdentity(for: session)
                )
            }
        }
        return identities.enumerated().compactMap { index, identity in
            guard let session = FocusTargetResolver.currentSession(
                for: identity,
                in: currentActiveSessions
            ) else { return nil }
            return PanelSessionRow(slot: index, session: session, id: identity)
        }
    }

    var sortedActiveSessions: [Session] {
        activeSessionRows.map(\.session)
    }

    var sortedIdleSessions: [Session] {
        Session.sorted(SessionDisplayPolicy.idleSessions(from: sessions))
    }

    var idleSessionRows: [PanelSessionRow] {
        sortedIdleSessions.enumerated().map { index, session in
            PanelSessionRow(
                slot: index,
                session: session,
                id: SessionIdentityPolicy.logicalIdentity(for: session)
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
            Button { requestHideSession(row.session) } label: {
                Label("Hide Session", systemImage: "eye.slash")
            }
            .disabled(!Session.isValidCctopSessionId(row.session.cctopSessionId))
        }
        .help(focusActionTitle)
        .accessibilityActions {
            Button("Hide Session") { requestHideSession(row.session) }
                .disabled(!Session.isValidCctopSessionId(row.session.cctopSessionId))
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
        let observations = selectedTab == .active ? currentActiveSessions : sortedIdleSessions
        guard let session = FocusTargetResolver.currentSession(for: identity, in: observations) else { return }
        focusSession(session)
        if isNavigateActive { navigate?.didConfirmSubject.send() }
    }
}
