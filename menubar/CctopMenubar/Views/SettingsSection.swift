import AppKit
import ServiceManagement
import SwiftUI

struct SettingsSection: View {
    @ObservedObject var updater: UpdaterBase
    @ObservedObject var pluginManager: PluginManager
    @ObservedObject private var themeManager = ThemeManager.shared
    @StateObject private var notificationPermission: NotificationPermissionController
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var installFailed = false

    init(
        updater: UpdaterBase,
        pluginManager: PluginManager,
        notificationPermission: NotificationPermissionController = NotificationPermissionController()
    ) {
        self.updater = updater
        self.pluginManager = pluginManager
        _notificationPermission = StateObject(wrappedValue: notificationPermission)
    }

    var body: some View {
        ScrollView(showsIndicators: true) {
            settingsContent
        }
        .frame(maxHeight: AppChrome.settingsScrollViewportHeight)
        .background(Color.groupedContentBackground)
        .onAppear { notificationPermission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            notificationPermission.refresh()
        }
    }

    private var settingsContent: some View {
        VStack(spacing: 0) {
            updateSection

            sectionHeader("Tools")
            settingsGroup {
                MonitoredToolsView(
                    pluginManager: pluginManager,
                    installFailed: $installFailed
                )
            }

            sectionHeader("Appearance")
            settingsGroup {
                settingsRow("Color") {
                    let binding = Binding(get: { themeManager.current }, set: { themeManager.setTheme($0) })
                    AmberSegmentedPicker(options: AppTheme.allCases.map { ($0, $0.displayName) }, selection: binding)
                }
                groupedDivider
                settingsRow("Mode") {
                    AmberSegmentedPicker(options: AppearanceMode.allCases.map { ($0.rawValue, $0.label) }, selection: $appearanceMode)
                }
                .onChange(of: appearanceMode) { _ in UserDefaults.standard.synchronize() }
            }

            sectionHeader("Shortcuts")
            settingsGroup {
                settingsRow("Toggle Panel") {
                    ShortcutBadge(name: .togglePanel)
                }
                groupedDivider
                navigateShortcutRow
            }

            sectionHeader("General")
            settingsGroup {
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
                groupedDivider
                NotificationSettingsRow(notificationPermission: notificationPermission)
            }
        }
        .padding(AppChrome.settingsContentPadding)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppChrome.settingsSectionHeaderHorizontalPadding)
            .padding(.top, 10)
            .padding(.bottom, 6)
    }

    private func settingsGroup<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) {
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.groupedRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius, style: .continuous)
                .stroke(Color.groupedRowBorder, lineWidth: 1)
        }
    }

    private func settingsRow<Content: View>(_ label: String, @ViewBuilder trailing: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
        .padding(.vertical, 8)
    }

    private var groupedDivider: some View {
        Rectangle()
            .fill(Color.groupedRowBorder)
            .frame(height: 1)
            .padding(.leading, AppChrome.settingsDividerLeadingPadding)
    }

    private var navigateShortcutRow: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Navigate")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text("Jump to sessions by number")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
            }
            Spacer()
            ShortcutBadge(name: .navigate)
        }
        .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var updateSection: some View {
        if let version = updater.pendingUpdateVersion {
            settingsGroup {
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
                            .foregroundStyle(Color.accentButtonText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.amber)
                            .clipShape(RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius, style: .continuous))
                    }
                    .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        } else if let reason = updater.disabledReason {
            settingsGroup {
                disabledSection(reason: reason)
            }
        } else if updater.canCheckForUpdates {
            settingsGroup {
                updateControlsSection
            }
        }
    }

    private var currentVersion: String { Bundle.main.appVersion }

    private var updateControlsSection: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.statusGreen)
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
        .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
        .padding(.vertical, 10)
    }

    private func disabledSection(reason: DisabledReason) -> some View {
        Text(reason.reasonText)
            .font(.system(size: 10))
            .foregroundStyle(Color.textMuted)
            .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
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
        .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
        .padding(.vertical, 2)
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
                    Image(systemName: "checkmark").font(.system(size: 10)).foregroundStyle(Color.statusGreen)
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
                .foregroundStyle(Color.accentButtonText)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.amber)
                .clipShape(RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius))
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
            RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius)
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
                .foregroundStyle(Color.accentButtonText)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.amber)
                .clipShape(RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius))
        }
        .buttonStyle(.plain)
    }
}

struct StatusDotBadge: View {
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(Color.statusGreen).frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
        }
    }
}

struct ConnectedBadge: View { var body: some View { StatusDotBadge(text: "Connected") } }
