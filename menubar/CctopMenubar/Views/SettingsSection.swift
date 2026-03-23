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
            toolStatusRow(name: "Claude Code", installed: pluginManager.ccInstalled)
            if pluginManager.ocConfigExists {
                PluginRowView(
                    name: "opencode", installed: pluginManager.ocInstalled,
                    needsUpdate: pluginManager.ocNeedsUpdate,
                    installFailed: $installFailed,
                    install: { pluginManager.installOpenCodePlugin() },
                    remove: { pluginManager.removeOpenCodePlugin() }
                )
            }
            if pluginManager.piConfigExists {
                PluginRowView(
                    name: "pi", installed: pluginManager.piInstalled,
                    installFailed: $installFailed,
                    install: { pluginManager.installPiPlugin() },
                    remove: { pluginManager.removePiPlugin() }
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private func toolStatusRow(name: String, installed: Bool) -> some View {
        HStack(spacing: 8) {
            Text(name).font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if installed {
                ConnectedBadge()
            } else {
                Text("Not installed").font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
            }
        }
        .padding(.vertical, 7)
    }
}

private struct PluginRowView: View {
    let name: String; let installed: Bool; var needsUpdate: Bool = false
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

    private var updateButton: some View { actionButton("Update Plugin") }
    private var installButton: some View { actionButton("Install Plugin") }

    private func actionButton(_ label: String) -> some View {
        Button {
            if install() {
                justInstalled = true; installFailed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { justInstalled = false }
            } else { flashFailed() }
        } label: {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.segmentActiveText)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.amber)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }.buttonStyle(.plain)
    }

    private func flashFailed() {
        installFailed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { installFailed = false }
    }
}

private struct ConnectedBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.statusGreen).frame(width: 5, height: 5)
            Text("Connected").font(.system(size: 10)).foregroundStyle(Color.textMuted)
        }
    }
}

// MARK: - Preview Helpers
@MainActor private class MockUpdater: UpdaterBase {
    override var canCheckForUpdates: Bool { true }
}
@MainActor private func previewPM(
    cc: Bool = true, oc: Bool = false, ocConfig: Bool = false, ocUpdate: Bool = false,
    pi: Bool = false, piConfig: Bool = false
) -> PluginManager {
    let pm = PluginManager(); pm.ccInstalled = cc; pm.ocInstalled = oc
    pm.ocNeedsUpdate = ocUpdate; pm.ocConfigExists = ocConfig
    pm.piInstalled = pi; pm.piConfigExists = piConfig; return pm
}
#Preview("Default") { SettingsSection(updater: DisabledUpdater(), pluginManager: previewPM()).frame(width: 320).padding() }
#Preview("Update available") { let up = DisabledUpdater(); up.pendingUpdateVersion = "0.7.0"
    return SettingsSection(updater: up, pluginManager: previewPM()).frame(width: 320).padding() }
#Preview("OC detected") { SettingsSection(
    updater: DisabledUpdater(), pluginManager: previewPM(ocConfig: true)).frame(width: 320).padding() }
#Preview("Pi detected") { SettingsSection(
    updater: DisabledUpdater(), pluginManager: previewPM(piConfig: true)).frame(width: 320).padding() }
#Preview("All connected") { SettingsSection(
    updater: DisabledUpdater(), pluginManager: previewPM(oc: true, ocConfig: true, pi: true, piConfig: true))
        .frame(width: 320).padding() }
#Preview("OC update available") { SettingsSection(
    updater: DisabledUpdater(), pluginManager: previewPM(oc: true, ocConfig: true, ocUpdate: true)).frame(width: 320).padding() }
#Preview("Sparkle: update available") { let mu = MockUpdater(); mu.pendingUpdateVersion = "0.7.0"
    return SettingsSection(updater: mu, pluginManager: previewPM()).frame(width: 320).padding() }
#Preview("Sparkle: up to date") { SettingsSection(updater: MockUpdater(), pluginManager: previewPM()).frame(width: 320).padding() }
