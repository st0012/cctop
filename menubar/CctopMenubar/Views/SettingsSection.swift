import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct AmberSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                SegmentButton(
                    label: options[index].label,
                    isSelected: selection == options[index].value
                ) {
                    withAnimation(.easeOut(duration: 0.15)) { selection = options[index].value }
                }
            }
        }
        .padding(2).background(Color.segmentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct SegmentButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .foregroundStyle(foregroundColor)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(backgroundColor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var foregroundColor: Color {
        if isSelected { return Color.segmentActiveText }
        if isHovered { return Color.segmentActiveText.opacity(0.7) }
        return Color.segmentText
    }

    private var backgroundColor: Color {
        if isSelected { return Color.textPrimary.opacity(0.1) }
        if isHovered { return Color.textPrimary.opacity(0.05) }
        return .clear
    }
}

struct ShortcutBadge: View {
    let name: KeyboardShortcuts.Name
    @State private var showRecorder = false
    @State private var isHovered = false

    var body: some View {
        Button { showRecorder.toggle() } label: {
            if let shortcut = KeyboardShortcuts.getShortcut(for: name) {
                Text(shortcut.description)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(isHovered ? Color.segmentActiveText : Color.textSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.textPrimary.opacity(isHovered ? 0.12 : 0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Text("Record Shortcut")
                    .font(.system(size: 10))
                    .foregroundStyle(isHovered ? Color.textPrimary : Color.textMuted)
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .popover(isPresented: $showRecorder) {
            KeyboardShortcuts.Recorder("", name: name)
                .padding(8)
        }
    }
}

struct SettingsSection: View {
    @ObservedObject var updater: UpdaterBase
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject private var themeManager = ThemeManager.shared
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var installFailed = false

    var body: some View {
        VStack(spacing: 0) {
            updateSection

            sectionHeader("Tools")
            MonitoredToolsView(
                pluginManager: pluginManager,
                installFailed: $installFailed
            )
            Divider().padding(.horizontal, 8)

            sectionHeader("Appearance")
            settingsRow("Color") {
                let binding = Binding(get: { themeManager.current }, set: { themeManager.setTheme($0) })
                AmberSegmentedPicker(options: AppTheme.allCases.map { ($0, $0.displayName) }, selection: binding)
            }
            settingsRow("Mode") {
                AmberSegmentedPicker(options: AppearanceMode.allCases.map { ($0.rawValue, $0.label) }, selection: $appearanceMode)
            }
            .onChange(of: appearanceMode) { _ in UserDefaults.standard.synchronize() }
            Divider().padding(.horizontal, 8)
            sectionHeader("Shortcuts")
            settingsRow("Toggle Panel") {
                ShortcutBadge(name: .togglePanel)
            }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Navigate")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.textPrimary)
                    Text("Jump to sessions by number")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textMuted)
                }
                Spacer()
                ShortcutBadge(name: .navigate)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            Divider().padding(.horizontal, 8)

            sectionHeader("General")
            settingsRow("Launch at Login") {
                Toggle("", isOn: $launchAtLogin)
                    .toggleStyle(.switch).controlSize(.mini)
                    .labelsHidden()
            }
            .onChange(of: launchAtLogin) { newValue in
                do {
                    if newValue { try SMAppService.mainApp.register()
                    } else { try SMAppService.mainApp.unregister() }
                } catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
            }
            settingsRow("Notifications") {
                Toggle("", isOn: $notificationsEnabled)
                    .toggleStyle(.switch).controlSize(.mini)
                    .labelsHidden()
            }
            .onChange(of: notificationsEnabled) { newValue in
                if newValue { SessionManager.requestNotificationPermission() }
            }
        }
        .padding(.horizontal, 8)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.textSecondary)
            .textCase(.uppercase)
            .tracking(0.8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var updateSection: some View {
        if let version = updater.pendingUpdateVersion {
            Button {
                updater.checkForUpdates()
            } label: {
                HStack {
                    Text("v\(version) available")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    Text("Update")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.amber)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            Divider().padding(.horizontal, 8)
        } else if let reason = updater.disabledReason {
            disabledSection(reason: reason)
            Divider().padding(.horizontal, 8)
        } else if updater.canCheckForUpdates {
            updateControlsSection
            Divider().padding(.horizontal, 8)
        }
    }

    private var currentVersion: String { Bundle.main.appVersion }

    private var updateControlsSection: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Up to date \u{2014} v\(currentVersion)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button {
                updater.checkForUpdates()
            } label: {
                Text("Check for Updates")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func disabledSection(reason: DisabledReason) -> some View {
        Text(reason.reasonText)
            .font(.system(size: 10))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

}

// MARK: - Monitored Tools

private struct MonitoredToolsView: View {
    @ObservedObject var pluginManager: PluginManager
    @Binding var installFailed: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClaudeCodePluginRowView(pluginManager: pluginManager)
            if pluginManager.ocConfigExists {
                PluginRowView(name: "opencode", installed: pluginManager.ocInstalled,
                    needsUpdate: pluginManager.ocNeedsUpdate, installFailed: $installFailed,
                    install: { pluginManager.installOpenCodePlugin() },
                    remove: { pluginManager.removeOpenCodePlugin() })
            }
            if pluginManager.piConfigExists {
                PluginRowView(name: "pi", installed: pluginManager.piInstalled,
                    installFailed: $installFailed, install: { pluginManager.installPiPlugin() },
                    remove: { pluginManager.removePiPlugin() })
            }
            if pluginManager.codexConfigExists {
                CodexPluginRowView(pluginManager: pluginManager, installFailed: $installFailed)
            }
        }
        .padding(.horizontal, 14).padding(.bottom, 8)
    }
}

private struct PluginRowView: View {
    let name: String; let installed: Bool; var needsUpdate: Bool = false
    var installLabel = "Install Plugin"; var updateLabel = "Update Plugin"
    @Binding var installFailed: Bool
    let install: () -> Bool; let remove: () -> Bool
    @State private var justInstalled = false; @State private var removeHovered = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.textPrimary)
                Spacer()
                if justInstalled {
                    EmptyView()
                } else if needsUpdate {
                    updateButton
                } else if installed {
                    ConnectedBadge()
                    Button { if !remove() { flashFailed() } } label: {
                        Text("Remove").font(.system(size: 10))
                            .foregroundStyle(removeHovered ? Color.textPrimary : Color.textMuted)
                    }.buttonStyle(.plain).onHover { removeHovered = $0 }
                } else { installButton }
            }.padding(.vertical, 7)
            if justInstalled {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(.green)
                    Text("Installed \u{2014} restart \(name) to start tracking")
                        .font(.system(size: 10)).foregroundStyle(Color.textMuted)
                }.transition(.opacity)
            }
            if installFailed {
                Text("Failed \u{2014} check permissions")
                    .font(.system(size: 10)).foregroundStyle(Color.amber).transition(.opacity)
            }
        }
    }

    private var updateButton: some View { actionButton(updateLabel) }
    private var installButton: some View { actionButton(installLabel) }

    private func actionButton(_ label: String) -> some View {
        AmberActionButton(label: label) {
            if install() {
                justInstalled = true; installFailed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { justInstalled = false }
            } else { flashFailed() }
        }
    }

    private func flashFailed() {
        installFailed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { installFailed = false }
    }
}

private struct ClaudeCodePluginRowView: View {
    @ObservedObject var pluginManager: PluginManager

    var body: some View {
        HStack(spacing: 8) {
            Text("Claude Code / Desktop")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if pluginManager.ccInstalled {
                ConnectedBadge()
            } else {
                ClaudeCodeInstallButton()
            }
        }
        .padding(.vertical, 7)
    }
}

/// Amber "Copy Install Command" button that flips to a green confirmation pill for 2s on click.
/// Shared by the Settings row and the empty-state install prompt.
struct ClaudeCodeInstallButton: View {
    @State private var justCopied = false

    var body: some View {
        if justCopied {
            copiedPill
        } else {
            copyButton
        }
    }

    private var copyButton: some View {
        Button {
            NSPasteboard.copyToClipboard(PluginManager.ccInstallCommand)
            justCopied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                justCopied = false
            }
        } label: {
            Text("Copy Install Command")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.segmentActiveText)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.amber)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private var copiedPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.statusGreen)
            Text("Copied \u{2014} paste in terminal")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.statusGreen)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.statusGreen, lineWidth: 1)
        )
        .transition(.opacity)
    }
}

/// Amber pill action button shared by the plugin rows and the empty state.
struct AmberActionButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.segmentActiveText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.amber)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

struct StatusDotBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.statusGreen)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
        }
    }
}

struct ConnectedBadge: View {
    var body: some View {
        StatusDotBadge(text: "Connected")
    }
}
// MARK: - Previews
@MainActor private func previewCCRow(installed: Bool) -> PluginManager {
    let pm = PluginManager()
    pm.ccInstalled = installed
    return pm
}

#Preview("CC row - Not installed") {
    ClaudeCodePluginRowView(pluginManager: previewCCRow(installed: false))
        .frame(width: 320).padding()
}
#Preview("CC row - Connected") {
    ClaudeCodePluginRowView(pluginManager: previewCCRow(installed: true))
        .frame(width: 320).padding()
}

@MainActor private class MockUpdater: UpdaterBase { override var canCheckForUpdates: Bool { true } }
@MainActor private func previewPM() -> PluginManager {
    let pm = PluginManager(); pm.ccInstalled = true; pm.ocInstalled = true
    pm.ocConfigExists = true; pm.piInstalled = true; pm.piConfigExists = true
    pm.codexInstalled = true; pm.codexConfigExists = true
    pm.codexHookStatus = .trusted
    return pm
}
@MainActor private func previewPendingCodexTrustPM() -> PluginManager {
    let pm = previewPM()
    pm.codexHookStatus = .installedUntrusted
    return pm
}
#Preview("Default") { SettingsSection(updater: DisabledUpdater(), pluginManager: PluginManager()).frame(width: 320).padding() }
#Preview("All connected") { SettingsSection(updater: DisabledUpdater(), pluginManager: previewPM()).frame(width: 320).padding() }
#Preview("Codex trust needed") {
    SettingsSection(updater: DisabledUpdater(), pluginManager: previewPendingCodexTrustPM()).frame(width: 320).padding()
}
