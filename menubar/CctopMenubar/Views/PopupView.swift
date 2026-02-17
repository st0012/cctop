import Combine
import KeyboardShortcuts
import SwiftUI

extension Notification.Name {
    static let layoutChanged = Notification.Name("layoutChanged")
}

enum PopupTab {
    case active, recent
}

struct PopupView: View {
    let sessions: [Session]
    var recentProjects: [RecentProject] = []
    @ObservedObject var updater: UpdaterBase
    var pluginManager: PluginManager?
    var jumpMode: JumpModeController?
    @State private var selectedTab: PopupTab = .active
    @State private var showSettings = false
    @State private var hideContent = false
    @State private var gearHovered = false
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
                    case .active:
                        activeContent
                    case .recent:
                        recentContent
                    }
                }
                .opacity(hideContent ? 0 : 1)
                .animation(.none, value: hideContent)
                if showSettings {
                    VStack(spacing: 0) {
                        SettingsSection(
                            updater: updater,
                            pluginManager: pluginManager ?? PluginManager()
                        )
                        .padding(.vertical, 8)
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
            }
            .clipped()
            .animation(.easeInOut(duration: 0.2), value: showSettings)
            Divider()
            footerBar
        }
        .onReceive(jumpMode?.$isActive.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { active in
            guard active else { return }
            if selectedTab == .recent {
                selectedTab = .active
            }
            if showSettings {
                closeSettings(animated: false)
            }
        }
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
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(sortedSessions.enumerated()), id: \.element.id) { index, session in
                            SessionCardView(
                                session: session,
                                jumpIndex: isJumpModeActive ? index + 1 : nil,
                                showSourceBadge: hasMultipleSources
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
                    .padding(8)
                }
                .frame(maxHeight: 290)
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
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 4) {
                    ForEach(recentProjects) { project in
                        recentCard(project)
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 290)
        }
    }

    private func recentCard(_ project: RecentProject) -> some View {
        RecentProjectCardView(project: project)
            .contentShape(Rectangle())
            .onTapGesture { openProject(project) }
            .contextMenu {
                Button { openProject(project) } label: {
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
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.system(size: 10)).foregroundStyle(Color.textMuted)
            if let shortcut = KeyboardShortcuts.getShortcut(for: .quickJump) {
                Text("\(shortcut.description) for jump mode")
                    .font(.system(size: 10)).foregroundStyle(Color.textMuted).lineLimit(1)
            }
            Spacer()
            settingsGearButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var settingsGearButton: some View {
        Button {
            toggleSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .foregroundStyle(showSettings ? Color.amber : Color.secondary)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(gearHovered ? 0.1 : 0)))
                .overlay(alignment: .topTrailing) {
                    if updater.pendingUpdateVersion != nil && !showSettings {
                        Circle().fill(Color.amber).frame(width: 7, height: 7).offset(x: 2, y: -2)
                    }
                }
        }
        .buttonStyle(.plain)
        .onHover { gearHovered = $0 }
    }

    // MARK: - Helpers

    private var isJumpModeActive: Bool { jumpMode?.isActive ?? false }

    private var hasMultipleSources: Bool { Set(sessions.map(\.sourceLabel)).count > 1 }

    private var sortedSessions: [Session] {
        if isJumpModeActive, let frozen = jumpMode?.frozenSessions, !frozen.isEmpty {
            return frozen
        }
        return Session.sorted(sessions)
    }

    private func focusSession(_ session: Session) {
        focusTerminal(session: session)
        NSApp.deactivate()
    }

    private func openProject(_ project: RecentProject) {
        openInEditor(project: project)
        NSApp.deactivate()
    }

    private func toggleSettings() {
        if showSettings {
            closeSettings(animated: true)
        } else {
            hideContent = true
            showSettings = true
            notifyLayoutChanged()
        }
    }

    /// Close the settings panel. When animated, the content is revealed after
    /// the 0.2s roll-up animation finishes. Otherwise both states reset immediately.
    private func closeSettings(animated: Bool) {
        showSettings = false
        notifyLayoutChanged()
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { hideContent = false }
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
}

private struct RollUpEffect: ViewModifier {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.mask {
            Color.black.scaleEffect(y: progress, anchor: .top)
        }
    }
}

private struct TabButtonView: View {
    let label: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.amber : Color.textMuted)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(isSelected ? Color.amber : Color.textMuted)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.amber.opacity(0.15) : Color.primary.opacity(0.06))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected || isHovered ? Color.primary.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

#Preview("With sessions") {
    PopupView(sessions: Session.mockSessions, updater: DisabledUpdater()).frame(width: 320)
}
#Preview("Mixed sources") {
    PopupView(sessions: Session.qaShowcase, updater: DisabledUpdater()).frame(width: 320)
}
#Preview("Empty") {
    PopupView(
        sessions: [], updater: DisabledUpdater(), pluginManager: PluginManager()
    ).frame(width: 320)
}
#Preview("With Tabs") {
    PopupView(
        sessions: Session.mockSessions,
        recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater()
    ).frame(width: 320)
}
#Preview("Only Recents") {
    PopupView(
        sessions: [],
        recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(),
        pluginManager: PluginManager()
    ).frame(width: 320)
}
#Preview("Empty Recents Tab") {
    PopupView(
        sessions: Session.mockSessions,
        recentProjects: [RecentProject.mock()],
        updater: DisabledUpdater()
    ).frame(width: 320)
}
#Preview("Jump Mode") {
    let jm = JumpModeController()
    jm.isActive = true
    return PopupView(
        sessions: Session.qaShowcase,
        recentProjects: RecentProject.mockRecents,
        updater: DisabledUpdater(),
        jumpMode: jm
    ).frame(width: 320)
}
