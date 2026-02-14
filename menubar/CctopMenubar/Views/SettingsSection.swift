import ServiceManagement
import SwiftUI
import KeyboardShortcuts

struct AmberSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                let isSelected = selection == option.value
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .foregroundStyle(isSelected ? Color.segmentActiveText : Color.segmentText)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isSelected ? Color.amber : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.segmentBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct SettingsSection: View {
    var updateAvailable: String?
    @ObservedObject var pluginManager: PluginManager
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @AppStorage("notificationsEnabled") private var notificationsEnabled = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var justInstalled = false
    @State private var installFailed = false
    @State private var removeHovered = false

    var body: some View {
        VStack(spacing: 0) {
            if let version = updateAvailable {
                Button {
                    NSWorkspace.shared.open(UpdateChecker.releasesPageURL)
                } label: {
                    HStack {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(Color.amber)
                        Text("Update available: v\(version)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: "arrow.up.forward")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.textSecondary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Divider().padding(.horizontal, 14)
            }
            monitoredToolsSection
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

    private var monitoredToolsSection: some View {
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

#Preview("Default") {
    SettingsSection(pluginManager: {
        let pm = PluginManager()
        pm.ccInstalled = true
        return pm
    }())
    .frame(width: 320)
    .padding()
}
#Preview("OC detected") {
    SettingsSection(pluginManager: {
        let pm = PluginManager()
        pm.ccInstalled = true
        pm.ocConfigExists = true
        return pm
    }())
    .frame(width: 320)
    .padding()
}
#Preview("Both connected") {
    SettingsSection(pluginManager: {
        let pm = PluginManager()
        pm.ccInstalled = true
        pm.ocInstalled = true
        pm.ocConfigExists = true
        return pm
    }())
    .frame(width: 320)
    .padding()
}
