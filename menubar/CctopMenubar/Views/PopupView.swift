import Combine
import KeyboardShortcuts
import SwiftUI

extension Notification.Name {
    static let settingsToggled = Notification.Name("settingsToggled")
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
            switch selectedTab {
            case .active:
                activeContent
            case .recent:
                recentContent
            }
            if showSettings {
                Divider()
                SettingsSection(
                    updater: updater,
                    pluginManager: pluginManager ?? PluginManager()
                )
                .padding(.vertical, 8)
            }
            Divider()
            footerBar
        }
        .onReceive(jumpMode?.$isActive.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()) { active in
            guard active else { return }
            if selectedTab == .recent {
                selectedTab = .active
            }
            if showSettings {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings = false }
                notifyLayoutChanged()
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
                    ocBanner
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
            withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() }
            notifyLayoutChanged()
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

    /// Notify the panel to resize after a layout change (tab switch, settings toggle).
    private func notifyLayoutChanged() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NotificationCenter.default.post(name: .settingsToggled, object: nil)
        }
    }

    private func openInFinder(path: String) {
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    private var ocBanner: some View {
        OpenCodeBanner(
            pluginManager: pluginManager,
            installed: $ocBannerInstalled,
            dismissed: $ocBannerDismissed
        )
    }
}

private struct OpenCodeBanner: View {
    var pluginManager: PluginManager?
    @Binding var installed: Bool
    @Binding var dismissed: Bool
    @State private var installHovered = false
    @State private var dismissHovered = false

    var body: some View {
        HStack(spacing: 4) {
            if installed {
                Image(systemName: "checkmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text("Installed \u{2014} restart opencode to start tracking")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
            } else {
                Text("Track opencode sessions too?")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                Spacer()
                Button {
                    if pluginManager?.installOpenCodePlugin() == true {
                        withAnimation { installed = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { dismissed = true }
                        }
                    }
                } label: {
                    Text("Install")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.amber)
                        .opacity(installHovered ? 1.0 : 0.8)
                        .underline(installHovered)
                }
                .buttonStyle(.plain)
                .onHover { installHovered = $0 }
                Button {
                    withAnimation { dismissed = true }
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.textMuted)
                        .opacity(dismissHovered ? 1.0 : 0.7)
                        .underline(dismissHovered)
                }
                .buttonStyle(.plain)
                .onHover { dismissHovered = $0 }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.amber.opacity(0.05))
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
