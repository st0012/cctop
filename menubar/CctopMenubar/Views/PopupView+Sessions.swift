import SwiftUI

struct PanelSessionRow: Identifiable {
    let slot: Int
    let session: SessionData
    let id: SessionIdentityPolicy.LogicalIdentity
}

extension PopupView {
    var isNavigateActive: Bool { navigate?.isActive ?? false }
    var hasMultipleSources: Bool { Set(sessions.map(\.agentBadge)).count > 1 }

    var currentActiveSessions: [SessionData] {
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
            guard let session = currentSession(for: identity, in: .active) else { return nil }
            return PanelSessionRow(slot: index, session: session, id: identity)
        }
    }

    var sortedActiveSessions: [SessionData] {
        activeSessionRows.map(\.session)
    }

    var sortedIdleSessions: [SessionData] {
        SessionData.sorted(SessionDisplayPolicy.idleSessions(from: sessions))
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
        SessionCardView(
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
                Label("Jump to Terminal", systemImage: "terminal")
            }
            Button { openInFinder(path: row.session.projectPath) } label: {
                Label("Open in Finder", systemImage: "folder")
            }
            Button { copyPath(row.session.projectPath) } label: {
                Label("Copy Project Path", systemImage: "doc.on.doc")
            }
            Divider()
            Button { requestHideSession(row.session) } label: {
                Label("Hide Session", systemImage: "eye.slash")
            }
            .disabled(!CctopSessionID.isValid(row.session.cctopSessionId))
        }
        .help("Click to jump to session")
        .accessibilityActions {
            Button("Hide Session") { requestHideSession(row.session) }
                .disabled(!CctopSessionID.isValid(row.session.cctopSessionId))
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
        guard let session = currentSession(for: identity, in: selectedTab) else { return }
        focusSession(session)
        if isNavigateActive { navigate?.didConfirmSubject.send() }
    }

    func currentSession(
        for identity: SessionIdentityPolicy.LogicalIdentity,
        in tab: PopupTab
    ) -> SessionData? {
        let candidates: [UserSession]
        switch tab {
        case .active:
            candidates = SessionDisplayPolicy.activeSessions(from: userSessions)
        case .idle:
            candidates = SessionDisplayPolicy.idleSessions(from: userSessions)
        case .recent, .cleanup:
            return nil
        }
        return FocusTargetResolver.currentSession(for: identity, in: candidates)
    }
}
