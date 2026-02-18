import Combine
import KeyboardShortcuts
import SwiftUI

extension Notification.Name {
    static let layoutChanged = Notification.Name("layoutChanged")
}

enum PopupTab {
    case active, recent
}

private enum Overlay: Equatable {
    case settings, about
}

private let overlayAnimationDuration: TimeInterval = 0.2

struct PopupView: View {
    let sessions: [Session]
    var recentProjects: [RecentProject] = []
    @ObservedObject var updater: UpdaterBase
    var pluginManager: PluginManager?
    var refocus: RefocusController?
    var initialTab: PopupTab = .active
    @State private var selectedTab: PopupTab = .active
    @State private var activeOverlay: Overlay?
    @State private var hideContent = false
    @State private var selectedIndex: Int?
    @State private var gearHovered = false
    @State private var versionHovered = false
    @State private var ocBannerInstalled = false
    @AppStorage("ocBannerDismissed") private var ocBannerDismissed = false

    private var showOcBanner: Bool {
        pluginManager.map { $0.ocConfigExists && !$0.ocInstalled && !ocBannerDismissed } ?? false
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
                .opacity(hideContent ? 0 : 1)
                .animation(.none, value: hideContent)
                if let overlay = activeOverlay {
                    overlayPanel {
                        switch overlay {
                        case .settings:
                            SettingsSection(
                                updater: updater,
                                pluginManager: pluginManager ?? PluginManager()
                            )
                        case .about:
                            AboutView()
                        }
                    }
                }
            }
            .clipped()
            .animation(.easeInOut(duration: overlayAnimationDuration), value: activeOverlay)
            Divider()
            footerBar
        }
        .onReceive(refocus?.didActivateSubject.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { _ in
            selectedIndex = nil
            if selectedTab == .recent { selectedTab = .active }
            if activeOverlay != nil { closeOverlay(animated: false) }
        }
        .onReceive(refocus?.navActionSubject.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { action in
            guard activeOverlay == nil else { return }
            handleNavAction(action)
        }
        .onChange(of: selectedTab) { _ in selectedIndex = nil }
        .onAppear { selectedTab = initialTab }
    }

    private func overlayPanel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
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
            if activeOverlay != nil { closeOverlay(animated: true) }
            withAnimation(.easeInOut(duration: 0.15)) { selectedTab = tab }
            notifyLayoutChanged()
        }
    }

    // MARK: - Active tab

    private var activeContent: some View {
        Group {
            if sessions.isEmpty {
                if let pluginManager {
                    EmptyStateView(pluginManager: pluginManager)
                }
            } else {
                if showOcBanner {
                    OpenCodeBanner(
                        pluginManager: pluginManager,
                        installed: $ocBannerInstalled,
                        dismissed: $ocBannerDismissed
                    )
                }
                ScrollViewReader { proxy in
                    ScrollView(showsIndicators: false) {
                        LazyVStack(spacing: 4) {
                            ForEach(Array(sortedSessions.enumerated()), id: \.element.id) { index, session in
                                SessionCardView(
                                    session: session,
                                    refocusIndex: isRefocusActive ? index + 1 : nil,
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
                        .padding(8)
                    }
                    .frame(maxHeight: 290)
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
                    LazyVStack(spacing: 4) {
                        ForEach(Array(recentProjects.enumerated()), id: \.element.id) { index, project in
                            recentCard(project, isSelected: selectedIndex == index)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 290)
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

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            QuitButton()
            versionButton
            if let shortcut = KeyboardShortcuts.getShortcut(for: .refocus) {
                Text("\(shortcut.description) to refocus")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            settingsGearButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var versionButton: some View {
        let isActive = activeOverlay == .about
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
                .foregroundStyle(activeOverlay == .settings ? Color.amber : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.primary.opacity(gearHovered ? 0.1 : 0))
                )
                .overlay(alignment: .topTrailing) {
                    if updater.pendingUpdateVersion != nil && activeOverlay != .settings {
                        Circle().fill(Color.amber).frame(width: 7, height: 7).offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { gearHovered = $0 }
    }

}

extension PopupView {
    private var isRefocusActive: Bool { refocus?.isActive ?? false }

    private var hasMultipleSources: Bool { Set(sessions.map(\.sourceLabel)).count > 1 }

    private var sortedSessions: [Session] {
        if isRefocusActive, let frozen = refocus?.frozenSessions, !frozen.isEmpty {
            return frozen
        }
        return Session.sorted(sessions)
    }

    private func focusSession(_ session: Session) {
        focusTerminal(session: session)
        NSApp.deactivate()
    }

    private func toggleOverlay(_ overlay: Overlay) {
        if activeOverlay == overlay {
            closeOverlay(animated: true)
        } else {
            activeOverlay = nil
            hideContent = true
            activeOverlay = overlay
            notifyLayoutChanged()
        }
    }

    private func closeOverlay(animated: Bool) {
        activeOverlay = nil
        notifyLayoutChanged()
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + overlayAnimationDuration) {
                hideContent = false
            }
        } else {
            hideContent = false
        }
    }

    private func notifyLayoutChanged() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .layoutChanged, object: nil)
        }
    }

    private func openInFinder(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    // MARK: - Keyboard navigation

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
        if let current = selectedIndex {
            selectedIndex = min(max(0, current + delta), count - 1)
        } else {
            selectedIndex = delta > 0 ? 0 : count - 1
        }
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
        if isRefocusActive {
            refocus?.didConfirmSubject.send()
        }
    }

    private func switchTab(to action: PanelNavAction) {
        guard showTabs else { return }
        let newTab: PopupTab
        switch action {
        case .previousTab: newTab = .active
        case .nextTab: newTab = .recent
        default: newTab = selectedTab == .active ? .recent : .active
        }
        guard newTab != selectedTab else { return }
        if activeOverlay != nil { closeOverlay(animated: true) }
        withAnimation(.easeInOut(duration: 0.15)) { selectedTab = newTab }
        notifyLayoutChanged()
    }
}
