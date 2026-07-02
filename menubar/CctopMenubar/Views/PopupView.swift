import Combine
import KeyboardShortcuts
import SwiftUI

private let overlayAnimationDuration: TimeInterval = 0.2
private let relativeTimeRefresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

struct PopupView: View {
    let sessions: [Session]
    var recentProjects: [RecentProject] = []
    var cleanupCandidates: [WorktreeCleanupCandidate] = []
    var cleanupIsScanning = false
    @ObservedObject var updater: UpdaterBase
    let pluginManager: PluginManager
    var navigate: NavigateController?
    @ObservedObject var overlayController: OverlayController = OverlayController()
    var initialTab: PopupTab = .active
    var initialCleanupCandidate: WorktreeCleanupCandidate?
    var onSelectCleanupRemovalAction: ((WorktreeCleanupCandidate) async -> WorktreeRemovalService.RemovalAction)?
    var onExecuteCleanupRemovalAction: ((WorktreeRemovalService.RemovalAction) async -> WorktreeRemovalService.RemovalResult)?
    var onCleanupTabVisible: () -> Void = {}
    var onCleanupTabHidden: () -> Void = {}
    /// Called (async on main) whenever content layout changes so the host can resize the panel.
    var onLayoutChanged: () -> Void = {}
    @State private var selectedTab: PopupTab = .active
    @State var selectedIndex: Int?
    @State private var gearHovered = false
    @State private var versionHovered = false
    @State private var shortcutHovered = false
    @State var selectedCleanupCandidate: WorktreeCleanupCandidate?
    @State var cleanupRemovalNotice: WorktreeRemovalNotice?
    @State var removingCleanupCandidateID: String?
    @State var pendingRemovalConfirmation: WorktreeRemovalConfirmation?
    @State var cleanupRemovalSelectsCandidateOnResult = true
    @State private var ocBannerInstalled = false
    @State private var lastFocusTime: Date = .distantPast
    @State private var piBannerInstalled = false
    @State var relativeTimeNow = Date()
    @AppStorage("ocBannerDismissed") private var ocBannerDismissed = false
    @AppStorage("piBannerDismissed") private var piBannerDismissed = false

    private var showOcBanner: Bool {
        pluginManager.ocConfigExists && !pluginManager.ocInstalled && !ocBannerDismissed
    }
    private var showPiBanner: Bool {
        pluginManager.piConfigExists && !pluginManager.piInstalled && !piBannerDismissed
    }

    private var showTabs: Bool { availableTabs.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(sessions: sessions)
                .background(Color.panelControlBackground)
            panelDivider
            if showTabs {
                tabPicker
                    .background(Color.panelControlBackground)
                panelDivider
            }
            ZStack(alignment: .top) {
                Group {
                    switch selectedTab {
                    case .active: activeContent
                    case .idle: idleContent
                    case .recent: recentContent
                    case .cleanup: cleanupContent
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(overlayController.hideContent ? 0 : 1)
                .animation(.none, value: overlayController.hideContent)
                if let overlay = overlayController.active {
                    switch overlay {
                    case .settings:
                        overlayPanel(verticalPadding: AppChrome.settingsOverlayVerticalPadding) {
                            SettingsSection(updater: updater, pluginManager: pluginManager)
                        }
                    case .about:
                        overlayPanel {
                            AboutView()
                        }
                    }
                }
            }
            .frame(minHeight: overlayController.active != nil ? AppChrome.overlayMinimumContentHeight : 0)
            .clipped()
            .animation(.easeInOut(duration: overlayAnimationDuration), value: overlayController.active)
            panelDivider
            footerBar
                .background(Color.panelControlBackground)
        }
        .onReceive(navigate?.didActivateSubject.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            selectedIndex = nil
            if selectedTab != .active { selectedTab = .active }
            if overlayController.active != nil { closeOverlay(animated: false) }
        }
        .onReceive(navigate?.navActionSubject.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { action in
            guard overlayController.active == nil else { return }
            handleNavAction(action)
        }
        .onReceive(relativeTimeRefresh) { relativeTimeNow = $0 }
        .onChange(of: selectedTab) { handleSelectedTabChanged($0) }
        .onChange(of: sessions) { _ in ensureSelectedTabAvailable() }
        .onChange(of: recentProjects.map(\.id)) { _ in ensureSelectedTabAvailable() }
        .onChange(of: actionableCleanupCandidates) { _ in handleCleanupCandidatesChanged() }
        .onChange(of: cleanupIsScanning) { _ in handleCleanupScanningChanged() }
        .onChange(of: selectedCleanupCandidate?.id) { _ in
            notifyLayoutChanged()
        }
        .alert(item: $pendingRemovalConfirmation) { confirmation in
            removalAlert(for: confirmation)
        }
        .onAppear {
            selectedTab = availableTabs.contains(initialTab) ? initialTab : .active
            if selectedTab == .cleanup,
               let initialCleanupCandidate,
               actionableCleanupCandidates.contains(where: { $0.id == initialCleanupCandidate.id }) {
                selectedCleanupCandidate = initialCleanupCandidate
            }
            if selectedTab == .cleanup {
                onCleanupTabVisible()
            } else {
                onCleanupTabHidden()
            }
        }
    }

    // MARK: - Tab picker

    private var panelDivider: some View {
        Rectangle()
            .fill(Color.panelControlBorder)
            .frame(height: 1)
    }

    private var tabPicker: some View {
        HStack(spacing: 6) {
            tabButton("Active", count: sortedActiveSessions.count, tab: .active)
            if !sortedIdleSessions.isEmpty {
                tabButton("Idle", count: sortedIdleSessions.count, tab: .idle)
            }
            if !recentProjects.isEmpty {
                tabButton("Recent", count: recentProjects.count, tab: .recent)
            }
            tabButton("Cleanup", count: actionableCleanupCandidates.count, tab: .cleanup, isScanning: cleanupIsScanning)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tabButton(_ label: String, count: Int, tab: PopupTab, isScanning: Bool = false) -> some View {
        TabButtonView(label: label, count: count, isScanning: isScanning, isSelected: selectedTab == tab) {
            if overlayController.active != nil { closeOverlay(animated: false) }
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
            notifyLayoutChanged()
        }
    }
    // MARK: - Active tab
    private var activeContent: some View {
        Group {
            if sessions.isEmpty {
                EmptyStateView(pluginManager: pluginManager)
            } else if sortedActiveSessions.isEmpty {
                noActiveSessionsContent
            } else {
                VStack(spacing: 0) {
                    if showOcBanner {
                        ToolInstallBanner(
                            toolName: "opencode", iconLabel: ">_", iconColor: Color.opencodeBadge,
                            installAction: { pluginManager.installOpenCodePlugin() },
                            installed: $ocBannerInstalled, dismissed: $ocBannerDismissed)
                    }
                    if showPiBanner {
                        ToolInstallBanner(
                            toolName: "pi", iconLabel: "\u{03C0}", iconColor: Color.piBadge,
                            installAction: { pluginManager.installPiPlugin() },
                            installed: $piBannerInstalled, dismissed: $piBannerDismissed)
                    }
                    sessionList(sortedActiveSessions, tab: .active, showNavigateNumbers: true)
                }
            }
        }
    }
    // MARK: - Idle tab
    @ViewBuilder
    private var idleContent: some View {
        if sortedIdleSessions.isEmpty {
            noIdleSessionsContent
        } else {
            sessionList(sortedIdleSessions, tab: .idle)
        }
    }
    // MARK: - Recent tab
    @ViewBuilder
    private var recentContent: some View {
        if recentProjects.isEmpty {
            emptyPlaceholder(systemImage: "clock", title: "Recent projects will appear here\nafter sessions end")
        } else {
            panelList(recentProjects, tab: .recent) { _, project, isSelected in
                recentCard(project, isSelected: isSelected)
            }
        }
    }

    private func recentCard(_ project: RecentProject, isSelected: Bool = false) -> some View {
        RecentProjectCardView(project: project, isSelected: isSelected, relativeTimeNow: relativeTimeNow)
            .contentShape(Rectangle())
            .onTapGesture { openInEditor(project: project); NSApp.deactivate() }
            .contextMenu {
                Button { openInEditor(project: project); NSApp.deactivate() } label: {
                    Label("Open in Editor", systemImage: "macwindow")
                }
                Button { openInFinder(path: project.projectPath) } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                Button { copyPath(project.projectPath) } label: {
                    Label("Copy Project Path", systemImage: "doc.on.doc")
                }
            }
            .help("Click to open in \(project.lastEditor ?? "editor")")
    }

    private func sessionList(_ list: [Session], tab: PopupTab, showNavigateNumbers: Bool = false) -> some View {
        panelList(list, tab: tab) { index, session, isSelected in
            SessionCardView(
                session: session,
                navigateIndex: showNavigateNumbers && isNavigateActive ? index + 1 : nil,
                showSourceBadge: hasMultipleSources,
                isSelected: isSelected,
                relativeTimeNow: relativeTimeNow
            )
            .onTapGesture { focusSession(session) }
            .contextMenu {
                Button { focusSession(session) } label: {
                    Label("Jump to Terminal", systemImage: "terminal")
                }
                Button { openInFinder(path: session.projectPath) } label: {
                    Label("Open in Finder", systemImage: "folder")
                }
                Button { copyPath(session.projectPath) } label: {
                    Label("Copy Project Path", systemImage: "doc.on.doc")
                }
            }
            .help("Click to jump to session")
        }
    }

    private func panelList<Item: Identifiable, Row: View>(
        _ list: [Item],
        tab: PopupTab,
        @ViewBuilder row: @escaping (Int, Item, Bool) -> Row
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(list.enumerated()), id: \.element.id) { index, item in
                        if index > 0 && selectedIndex != index && selectedIndex != index - 1 {
                            Rectangle()
                                .fill(Color.panelControlBorder)
                                .frame(height: 1)
                                .padding(.horizontal, 16)
                        }
                        row(index, item, selectedIndex == index)
                            .id(item.id)
                    }
                }
                .padding(.vertical, AppChrome.listVerticalPadding)
            }
            .frame(maxHeight: AppChrome.overlayMinimumContentHeight)
            .onChange(of: selectedIndex) { newIndex in
                guard selectedTab == tab,
                      let idx = newIndex, idx < list.count else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(list[idx].id, anchor: .center)
                }
            }
        }
    }
}

// MARK: - Overlay & Footer

extension PopupView {
    func overlayPanel<Content: View>(
        verticalPadding: CGFloat = AppChrome.overlayContentVerticalPadding,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: AppChrome.overlayMinimumContentHeight, alignment: .top)
            .background {
                PanelSurfaceBackground(usesMaterial: false)
            }
            .transition(.asymmetric(
                insertion: .move(edge: .top),
                removal: .modifier(
                    active: RollUpEffect(progress: 0),
                    identity: RollUpEffect(progress: 1)
                )
            ))
    }

    var footerBar: some View {
        HStack {
            QuitButton()
            versionButton
            footerShortcutHints
            Spacer()
            settingsGearButton
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var versionButton: some View {
        let isActive = overlayController.active == .about
        let color: Color = isActive ? .amber : (versionHovered ? .textPrimary : .textMuted)
        return Button { toggleOverlay(.about) } label: {
            Text("v\(Bundle.main.appVersion)")
                .font(.system(size: 10))
                .foregroundStyle(color)
                .underline(versionHovered && !isActive)
        }
        .buttonStyle(.plain)
        .onHover { versionHovered = $0 }
    }

    private var settingsGearButton: some View {
        Button { toggleOverlay(.settings) } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(overlayController.active == .settings ? Color.amber : Color.textMuted)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous)
                        .fill(gearHovered ? Color.panelSelectionBackground : Color.clear)
                )
                .overlay(alignment: .topTrailing) {
                    if updater.pendingUpdateVersion != nil && overlayController.active != .settings {
                        Circle().fill(Color.amber).frame(width: 7, height: 7).offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { gearHovered = $0 }
    }

    // MARK: - Helpers

    @ViewBuilder private var footerShortcutHints: some View {
        if let sc = KeyboardShortcuts.getShortcut(for: .navigate) {
            Button { toggleOverlay(.settings) } label: {
                Text("\(sc.description) navigate")
                    .font(.system(size: 10))
                    .foregroundStyle(shortcutHovered ? Color.textPrimary : Color.textSecondary)
                    .underline(shortcutHovered)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .onHover { shortcutHovered = $0 }
        } else { EmptyView() }
    }
    private var isNavigateActive: Bool { navigate?.isActive ?? false }
    private var hasMultipleSources: Bool { Set(sessions.map(\.agentBadge)).count > 1 }
    private var sortedActiveSessions: [Session] {
        if isNavigateActive, let frozen = navigate?.frozenSessions, !frozen.isEmpty {
            return frozen
        }
        return Session.sorted(SessionDisplayPolicy.activeSessions(from: sessions))
    }
    private var sortedIdleSessions: [Session] {
        Session.sorted(SessionDisplayPolicy.idleSessions(from: sessions))
    }
    var actionableCleanupCandidates: [WorktreeCleanupCandidate] {
        cleanupCandidates.filter(\.state.isActionable)
    }

    private func syncSelectedCleanupCandidate() {
        selectedCleanupCandidate = Self.syncedCleanupCandidate(
            selectedCleanupCandidate,
            in: actionableCleanupCandidates
        )
    }
    private var availableTabs: [PopupTab] {
        PopupTab.availableTabs(
            hasIdleSessions: !sortedIdleSessions.isEmpty,
            hasRecentProjects: !recentProjects.isEmpty,
            hasCleanupCandidates: !actionableCleanupCandidates.isEmpty
        )
    }

    private func focusSession(_ session: Session) {
        guard Date().timeIntervalSince(lastFocusTime) > 0.5 else { return }
        lastFocusTime = Date()
        focusTerminal(session: session)
    }

    private func toggleOverlay(_ overlay: PopupOverlay) {
        if overlayController.active == overlay {
            closeOverlay(animated: true)
        } else {
            overlayController.active = nil
            overlayController.hideContent = true
            overlayController.active = overlay
            notifyLayoutChanged()
        }
    }
    private func closeOverlay(animated: Bool) {
        overlayController.active = nil
        notifyLayoutChanged()
        guard animated else { overlayController.hideContent = false; return }
        DispatchQueue.main.asyncAfter(deadline: .now() + overlayAnimationDuration) { overlayController.hideContent = false }
    }

    func notifyLayoutChanged() {
        DispatchQueue.main.async { onLayoutChanged() }
    }
    private func handleNavAction(_ action: PanelNavAction) {
        switch action {
        case .up: moveSelection(by: -1)
        case .down: moveSelection(by: 1)
        case .confirm: confirmSelection()
        case .escape, .reset: selectedIndex = nil
        case .toggleTab, .previousTab, .nextTab: switchTab(to: action)
        }
    }

    private func moveSelection(by delta: Int) {
        let count: Int
        switch selectedTab {
        case .active: count = sortedActiveSessions.count
        case .idle: count = sortedIdleSessions.count
        case .recent: count = recentProjects.count
        case .cleanup: count = actionableCleanupCandidates.count
        }
        guard count > 0 else { return }
        selectedIndex = selectedIndex.map { ($0 + delta + count) % count } ?? (delta > 0 ? 0 : count - 1)
    }

    private func confirmSelection() {
        guard let index = selectedIndex else { return }
        guard let target = PopupSelectionTarget.target(
            for: selectedTab,
            index: index,
            in: PopupSelectionContext(
                activeSessions: sortedActiveSessions,
                idleSessions: sortedIdleSessions,
                recentProjects: recentProjects,
                cleanupCandidates: actionableCleanupCandidates
            )
        ) else {
            return
        }
        switch target {
        case .activeSession(let session), .idleSession(let session):
            focusSession(session)
        case .recentProject(let project):
            openInEditor(project: project)
            NSApp.deactivate()
        case .cleanupCandidate(let candidate):
            openCleanupDetail(candidate)
        }
        if isNavigateActive && target.confirmsNavigate {
            navigate?.didConfirmSubject.send()
        }
    }

    private func switchTab(to action: PanelNavAction) {
        guard showTabs else { return }
        let tabs = availableTabs
        let newTab = PopupTab.switched(from: selectedTab, action: action, availableTabs: tabs)
        guard newTab != selectedTab else { return }
        if overlayController.active != nil { closeOverlay(animated: true) }
        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = newTab }
        notifyLayoutChanged()
    }

    private func ensureSelectedTabAvailable() {
        guard availableTabs.contains(selectedTab) else {
            selectedTab = .active
            return
        }
        syncSelectedCleanupCandidate()
    }

    func handleCleanupCandidatesChanged() {
        ensureSelectedTabAvailable()
        syncSelectedCleanupCandidate()
        cleanupRemovalNotice = Self.noticeAfterCleanupCandidatesChanged(cleanupRemovalNotice)
        notifyLayoutChanged()
    }

    func openCleanupDetail(_ candidate: WorktreeCleanupCandidate) {
        cleanupRemovalNotice = nil
        selectedCleanupCandidate = candidate
    }

}
