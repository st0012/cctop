import KeyboardShortcuts
import SwiftUI

extension Notification.Name {
    static let settingsToggled = Notification.Name("settingsToggled")
}

struct PopupView: View {
    let sessions: [Session]
    @ObservedObject var updater: UpdaterBase
    var pluginManager: PluginManager?
    var jumpMode: JumpModeController?
    @State private var showSettings = false
    @State private var gearHovered = false
    @State private var ocBannerInstalled = false
    @State private var installHovered = false
    @State private var dismissHovered = false
    @AppStorage("ocBannerDismissed") private var ocBannerDismissed = false

    private var showOcBanner: Bool {
        guard let pm = pluginManager else { return false }
        return pm.ocConfigExists && !pm.ocInstalled && !ocBannerDismissed
    }

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(sessions: sessions)
            Divider()
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
                                Button {
                                    focusSession(session)
                                } label: {
                                    Label("Jump to Terminal", systemImage: "terminal")
                                }
                                Button {
                                    NSWorkspace.shared.selectFile(
                                        nil,
                                        inFileViewerRootedAtPath: session.projectPath
                                    )
                                } label: {
                                    Label("Open in Finder", systemImage: "folder")
                                }
                                Button {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        session.projectPath, forType: .string
                                    )
                                } label: {
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
        .onChange(of: isJumpModeActive) { active in
            if active && showSettings {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings = false }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NotificationCenter.default.post(name: .settingsToggled, object: nil)
                }
            }
        }
    }

    private var footerBar: some View {
        HStack {
            QuitButton()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
            if let shortcut = KeyboardShortcuts.getShortcut(for: .quickJump) {
                Text("\(shortcut.description) for jump mode")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    NotificationCenter.default.post(name: .settingsToggled, object: nil)
                }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(showSettings ? Color.amber : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(gearHovered ? 0.1 : 0))
                    )
                    .overlay(alignment: .topTrailing) {
                        if updater.pendingUpdateVersion != nil && !showSettings {
                            Circle()
                                .fill(Color.amber)
                                .frame(width: 7, height: 7)
                                .offset(x: 2, y: -2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .onHover { gearHovered = $0 }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var isJumpModeActive: Bool {
        jumpMode?.isActive ?? false
    }

    private var hasMultipleSources: Bool {
        Set(sessions.map(\.sourceLabel)).count > 1
    }

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

    private var ocBanner: some View {
        HStack(spacing: 4) {
            if ocBannerInstalled {
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
                        withAnimation { ocBannerInstalled = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { ocBannerDismissed = true }
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
                    withAnimation { ocBannerDismissed = true }
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
#Preview("OC banner") {
    PopupView(sessions: Session.mockSessions, updater: DisabledUpdater(), pluginManager: {
        let pm = PluginManager()
        pm.ocConfigExists = true
        pm.ocInstalled = false
        return pm
    }()).frame(width: 320)
}
#Preview("Jump Mode") {
    let jm = JumpModeController()
    jm.isActive = true
    return PopupView(
        sessions: Session.qaShowcase, updater: DisabledUpdater(), jumpMode: jm
    ).frame(width: 320)
}
