import Combine
import KeyboardShortcuts
import SwiftUI

enum PopupTab {
    case active, recent
}

private let overlayAnimationDuration: TimeInterval = 0.2
private let popupContentHeight: CGFloat = 290

struct PopupView: View {
    let sessions: [Session]
    var recentProjects: [RecentProject] = []
    @ObservedObject var updater: UpdaterBase
    let pluginManager: PluginManager
    var navigate: NavigateController?
    @ObservedObject var overlayController: OverlayController = OverlayController()
    var initialTab: PopupTab = .active
    /// Called (async on main) whenever content layout changes so the host can resize the panel.
    var onLayoutChanged: () -> Void = {}
    @State private var selectedTab: PopupTab = .active
    @State private var selectedIndex: Int?
    @State private var gearHovered = false
    @State private var versionHovered = false
    @State private var shortcutHovered = false
    @State private var ocBannerInstalled = false
    @State private var lastFocusTime: Date = .distantPast
    @State private var piBannerInstalled = false
    @AppStorage("ocBannerDismissed") private var ocBannerDismissed = false
    @AppStorage("piBannerDismissed") private var piBannerDismissed = false

    private var showOcBanner: Bool {
        pluginManager.ocConfigExists && !pluginManager.ocInstalled && !ocBannerDismissed
    }
    private var showPiBanner: Bool {
        pluginManager.piConfigExists && !pluginManager.piInstalled && !piBannerDismissed
    }

    private var showTabs: Bool { !recentProjects.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(sessions: sessions)
            Divider()
            if showTabs {
                tabPicker
                Divider()
            }
            ZStack(alignment: .top) {
                Group {
                    switch selectedTab {
                    case .active: activeContent
                    case .recent: recentContent
                    }
                }
                .frame(maxWidth: .infinity)
                .opacity(overlayController.hideContent ? 0 : 1)
                .animation(.none, value: overlayController.hideContent)
                if let overlay = overlayController.active {
                    overlayPanel {
                        switch overlay {
                        case .settings:
                            SettingsSection(updater: updater, pluginManager: pluginManager)
                        case .about:
                            AboutView()
                        }
                    }
                }
            }
            .frame(minHeight: overlayController.active != nil ? popupContentHeight : 0)
            .clipped()
            .animation(.easeInOut(duration: overlayAnimationDuration), value: overlayController.active)
            Divider()
            footerBar
        }
        .onReceive(navigate?.didActivateSubject.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            selectedIndex = nil
            if selectedTab == .recent { selectedTab = .active }
            if overlayController.active != nil { closeOverlay(animated: false) }
        }
        .onReceive(navigate?.navActionSubject.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { action in
            guard overlayController.active == nil else { return }
            handleNavAction(action)
        }
        .onChange(of: selectedTab) { _ in selectedIndex = nil }
        .onAppear { selectedTab = initialTab }
    }

    // MARK: - Tab picker

    private var tabPicker: some View {
        HStack(spacing: 6) {
            tabButton("Active", count: sessions.count, tab: .active)
            tabButton("Recent", count: recentProjects.count, tab: .recent)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func tabButton(_ label: String, count: Int, tab: PopupTab) -> some View {
        TabButtonView(label: label, count: count, isSelected: selectedTab == tab) {
            if overlayController.active != nil { closeOverlay(animated: true) }
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
            notifyLayoutChanged()
        }
    }
    // MARK: - Active tab
    private var activeContent: some View {
        Group {
            if sessions.isEmpty {
                EmptyStateView(pluginManager: pluginManager)
            } else {
                VStack(spacing: 0) {
                if showOcBanner {
                    ToolInstallBanner(
                        toolName: "opencode", iconLabel: ">_", iconColor: .blue,
                        installAction: { pluginManager.installOpenCodePlugin() },
                        installed: $ocBannerInstalled, dismissed: $ocBannerDismissed)
                }
                if showPiBanner {
                    ToolInstallBanner(
                        toolName: "pi", iconLabel: "\u{03C0}", iconColor: .green,
                        installAction: { pluginManager.installPiPlugin() },
                        installed: $piBannerInstalled, dismissed: $piBannerDismissed)
                }
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(sortedSessions.enumerated()), id: \.element.id) { index, session in
                                if index > 0 && selectedIndex != index && selectedIndex != index - 1 {
                                    Divider()
                                        .padding(.horizontal, 16)
                                }
                                SessionCardView(
                                    session: session,
                                    navigateIndex: isNavigateActive ? index + 1 : nil,
                                    showSourceBadge: hasMultipleSources,
                                    isSelected: selectedIndex == index
                                )
                                .id(session.id)
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
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: popupContentHeight)
                    .onChange(of: selectedIndex) { newIndex in
                        guard selectedTab == .active,
                              let idx = newIndex, idx < sortedSessions.count else { return }
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo(sortedSessions[idx].id, anchor: .center)
                        }
                    }
                }
                }
            }
        }
    }
    // MARK: - Recent tab
    @ViewBuilder
    private var recentContent: some View {
        if recentProjects.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.textMuted)
                Text("Recent projects will appear here\nafter sessions end")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        } else {
            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(recentProjects.enumerated()), id: \.element.id) { index, project in
                            if index > 0 && selectedIndex != index && selectedIndex != index - 1 {
                                Divider()
                                    .padding(.horizontal, 16)
                            }
                            recentCard(project, isSelected: selectedIndex == index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: popupContentHeight)
                .onChange(of: selectedIndex) { newIndex in
                    guard selectedTab == .recent,
                          let idx = newIndex, idx < recentProjects.count else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(recentProjects[idx].id, anchor: .center)
                    }
                }
            }
        }
    }

    private func recentCard(_ project: RecentProject, isSelected: Bool = false) -> some View {
        RecentProjectCardView(project: project, isSelected: isSelected)
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

}

// MARK: - Overlay & Footer

extension PopupView {
    func overlayPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content().padding(.vertical, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.panelBackground)
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
        let color: Color = isActive ? .amber : (versionHovered ? .primary : .textMuted)
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
                .foregroundStyle(overlayController.active == .settings ? Color.amber : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.textPrimary.opacity(gearHovered ? 0.1 : 0))
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
                    .foregroundStyle(shortcutHovered ? Color.primary : Color.textSecondary)
                    .underline(shortcutHovered)
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .onHover { shortcutHovered = $0 }
        } else { EmptyView() }
    }
    private var isNavigateActive: Bool { navigate?.isActive ?? false }
    private var hasMultipleSources: Bool { Set(sessions.map(\.agentBadge)).count > 1 }
    private var sortedSessions: [Session] {
        if isNavigateActive, let frozen = navigate?.frozenSessions, !frozen.isEmpty {
            return frozen
        }
        return Session.sorted(sessions)
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

    private func notifyLayoutChanged() {
        DispatchQueue.main.async { onLayoutChanged() }
    }
    private func openInFinder(path: String) { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path) }
    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
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
        let count = selectedTab == .active ? sortedSessions.count : recentProjects.count
        guard count > 0 else { return }
        selectedIndex = selectedIndex.map { ($0 + delta + count) % count } ?? (delta > 0 ? 0 : count - 1)
    }

    private func confirmSelection() {
        guard let index = selectedIndex else { return }
        switch selectedTab {
        case .active:
            guard index < sortedSessions.count else { return }
            focusSession(sortedSessions[index])
        case .recent:
            guard index < recentProjects.count else { return }
            openInEditor(project: recentProjects[index])
            NSApp.deactivate()
        }
        if isNavigateActive {
            navigate?.didConfirmSubject.send()
        }
    }

    private func switchTab(to action: PanelNavAction) {
        guard showTabs else { return }
        let newTab: PopupTab = action == .previousTab ? .active : action == .nextTab ? .recent
            : (selectedTab == .active ? .recent : .active)
        guard newTab != selectedTab else { return }
        if overlayController.active != nil { closeOverlay(animated: true) }
        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = newTab }
        notifyLayoutChanged()
    }
}
