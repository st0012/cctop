import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct AmberSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = selection == option.value
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .foregroundStyle(isSelected ? Color.segmentActiveText : Color.segmentText)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(isSelected ? Color.amber : Color.clear))
                        .contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(2).background(Color.segmentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SettingsSection: View {
    @ObservedObject var updater: UpdaterBase
    @ObservedObject var pluginManager: PluginManager
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var justInstalled = false
    @State private var installFailed = false
    @State private var removeHovered = false

    var body: some View {
        VStack(spacing: 0) {
            updateSection
            MonitoredToolsView(
                pluginManager: pluginManager,
                justInstalled: $justInstalled,
                installFailed: $installFailed,
                removeHovered: $removeHovered
            )
            Divider().padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 8) {
                Text("Appearance")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                AmberSegmentedPicker(
                    options: AppearanceMode.allCases.map { ($0.rawValue, $0.label) },
                    selection: $appearanceMode
                )
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            HStack {
                Text("Toggle Shortcut")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
                Spacer()
                KeyboardShortcuts.Recorder("", name: .togglePanel)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Quick Jump Shortcut")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textSecondary)
                    Spacer()
                    KeyboardShortcuts.Recorder("", name: .quickJump)
                }
                Text("Focus the panel and jump to sessions by number.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 10)

            Divider().padding(.horizontal, 14)

            Toggle(isOn: $launchAtLogin) {
                Text("Launch at Login")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .onChange(of: launchAtLogin) { newValue in
                do {
                    if newValue {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    launchAtLogin = SMAppService.mainApp.status == .enabled
                }
            }

            Divider().padding(.horizontal, 14)

            Toggle(isOn: $notificationsEnabled) {
                Text("Notifications")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)
            .onChange(of: notificationsEnabled) { newValue in
                if newValue {
                    SessionManager.requestNotificationPermission()
                }
            }
        }
        .background(Color.settingsBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.settingsBorder, lineWidth: 1)
        )
        .padding(.horizontal, 8)
    }

    @ViewBuilder
    private var updateSection: some View {
        if let version = updater.pendingUpdateVersion {
            Button {
                updater.checkForUpdates()
            } label: {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(Color.amber)
                    Text("Update available: v\(version)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Spacer()
                    Text("Install v\(version)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.amber)
                        .clipShape(Capsule())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            Divider().padding(.horizontal, 14)
        } else if let reason = updater.disabledReason {
            disabledSection(reason: reason)
            Divider().padding(.horizontal, 14)
        } else if updater.canCheckForUpdates {
            updateControlsSection
            Divider().padding(.horizontal, 14)
        }
    }

    private var currentVersion: String { Bundle.main.appVersion }

    private var updateControlsSection: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Up to date \u{2014} v\(currentVersion)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.primary)
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
    @Binding var justInstalled: Bool
    @Binding var installFailed: Bool
    @Binding var removeHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Monitored Tools")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
            toolRow(name: "Claude Code", installed: pluginManager.ccInstalled)
            if pluginManager.ocConfigExists {
                openCodeRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    private var openCodeRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                toolLabel("opencode")
                Spacer()
                if justInstalled {
                    EmptyView()
                } else if pluginManager.ocInstalled {
                    connectedBadge
                    Button {
                        if !pluginManager.removeOpenCodePlugin() {
                            flashFailed()
                        }
                    } label: {
                        Text("Remove")
                            .font(.system(size: 10))
                            .foregroundStyle(removeHovered ? Color.primary : Color.textMuted)
                    }
                    .buttonStyle(.plain)
                    .onHover { removeHovered = $0 }
                } else {
                    installPluginButton
                }
            }
            if justInstalled {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("Installed \u{2014} restart opencode to start tracking")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textMuted)
                }
                .transition(.opacity)
            }
            if installFailed {
                Text("Failed \u{2014} check permissions")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.amber)
                    .transition(.opacity)
            }
        }
    }

    private var installPluginButton: some View {
        Button {
            if pluginManager.installOpenCodePlugin() {
                justInstalled = true
                installFailed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    justInstalled = false
                }
            } else {
                flashFailed()
            }
        } label: {
            Text("Install Plugin")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.segmentActiveText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.amber)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    private func flashFailed() {
        installFailed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            installFailed = false
        }
    }

    private func toolRow(name: String, installed: Bool) -> some View {
        HStack(spacing: 8) {
            toolLabel(name)
            Spacer()
            if installed {
                connectedBadge
            } else {
                Text("Not installed")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
            }
        }
    }

    private func toolLabel(_ name: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
                .frame(width: 16, height: 16)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    private var connectedBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.statusGreen)
                .frame(width: 6, height: 6)
            Text("Connected")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
        }
    }
}

// MARK: - Preview Helpers

@MainActor private class MockUpdater: UpdaterBase {
    override var canCheckForUpdates: Bool { true }
}
@MainActor private func previewPM(
    cc: Bool = true, oc: Bool = false, ocConfig: Bool = false
) -> PluginManager {
    let pm = PluginManager()
    pm.ccInstalled = cc
    pm.ocInstalled = oc
    pm.ocConfigExists = ocConfig
    return pm
}
#Preview("Default") {
    SettingsSection(updater: DisabledUpdater(), pluginManager: previewPM()).frame(width: 320).padding()
}
#Preview("Update available") {
    let up = DisabledUpdater(); up.pendingUpdateVersion = "0.7.0"
    return SettingsSection(updater: up, pluginManager: previewPM()).frame(width: 320).padding()
}
#Preview("OC detected") {
    SettingsSection(updater: DisabledUpdater(), pluginManager: previewPM(ocConfig: true)).frame(width: 320).padding()
}
#Preview("Both connected") {
    SettingsSection(updater: DisabledUpdater(), pluginManager: previewPM(oc: true, ocConfig: true)).frame(width: 320).padding()
}
#Preview("Sparkle: update available") {
    let mock = MockUpdater(); mock.pendingUpdateVersion = "0.7.0"
    return SettingsSection(updater: mock, pluginManager: previewPM()).frame(width: 320).padding()
}
#Preview("Sparkle: up to date") {
    SettingsSection(updater: MockUpdater(), pluginManager: previewPM()).frame(width: 320).padding()
}
