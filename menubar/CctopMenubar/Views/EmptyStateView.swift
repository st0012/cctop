import SwiftUI

struct EmptyStateView: View {
    @ObservedObject var pluginManager: PluginManager
    @State private var justInstalledOC = false
    @State private var justInstalledPi = false

    private var anyInstalled: Bool {
        pluginManager.ccInstalled || pluginManager.ocInstalled
            || pluginManager.piInstalled
    }

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.amber)
                .frame(width: 36, height: 36)
                .overlay(
                    Text("C")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                )
                .padding(.top, 4)

            Text("Monitor your AI coding sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            if anyInstalled {
                installedView
            } else {
                notInstalledView
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    private var installedView: some View {
        VStack(spacing: 8) {
            pluginStatusRow(
                "Claude Code", installed: pluginManager.ccInstalled
            )
            if pluginManager.ocConfigExists {
                ocPluginRow
            }
            if pluginManager.piConfigExists {
                piPluginRow
            }

            Text("Start a session \u{2014} it will appear here automatically.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Text("Existing sessions need a restart to pick up hooks.")
                .font(.system(size: 11))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
    }

    private func pluginStatusRow(_ name: String, installed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(installed ? .green : Color.textMuted)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(installed ? Color.textSecondary : Color.textMuted)
            Spacer()
        }
    }

    private var ocPluginRow: some View {
        thirdPartyPluginRow(
            name: "opencode",
            installed: pluginManager.ocInstalled,
            justInstalled: $justInstalledOC,
            install: { pluginManager.installOpenCodePlugin() }
        )
    }

    private var piPluginRow: some View {
        thirdPartyPluginRow(
            name: "pi",
            installed: pluginManager.piInstalled,
            justInstalled: $justInstalledPi,
            install: { pluginManager.installPiPlugin() }
        )
    }

    private func thirdPartyPluginRow(
        name: String,
        installed: Bool,
        justInstalled: Binding<Bool>,
        install: @escaping () -> Bool
    ) -> some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                pluginStatusRow(name, installed: installed)
                if !installed && !justInstalled.wrappedValue {
                    Button {
                        if install() {
                            justInstalled.wrappedValue = true
                            DispatchQueue.main.asyncAfter(
                                deadline: .now() + 3
                            ) {
                                justInstalled.wrappedValue = false
                            }
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
            }
            if justInstalled.wrappedValue {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text(
                        "Installed \u{2014} restart \(name) to start tracking sessions"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                    Spacer()
                }
                .transition(.opacity)
            }
        }
    }

    private var notInstalledView: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                sectionHeader("Claude Code")
                HStack {
                    Spacer()
                    ClaudeCodeInstallButton()
                }
            }

            if pluginManager.ocConfigExists {
                VStack(spacing: 6) {
                    sectionHeader("opencode")
                    ocPluginRow
                }
            }

            if pluginManager.piConfigExists {
                VStack(spacing: 6) {
                    sectionHeader("pi")
                    piPluginRow
                }
            }

            stepRow(text: "Restart sessions after installing")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
    }

    private func stepRow(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
    }
}

// MARK: - Previews

@MainActor
private func previewPluginManager(
    cc: Bool = false, oc: Bool = false, ocConfig: Bool = false,
    pi: Bool = false, piConfig: Bool = false
) -> PluginManager {
    let pm = PluginManager()
    pm.ccInstalled = cc
    pm.ocInstalled = oc
    pm.ocConfigExists = ocConfig
    pm.piInstalled = pi
    pm.piConfigExists = piConfig
    return pm
}

#Preview("Not installed (CC only user)") {
    EmptyStateView(pluginManager: previewPluginManager())
        .frame(width: 320)
}
#Preview("Not installed (OC + Pi detected)") {
    EmptyStateView(
        pluginManager: previewPluginManager(
            ocConfig: true, piConfig: true
        )
    )
    .frame(width: 320)
}
#Preview("CC installed") {
    EmptyStateView(pluginManager: previewPluginManager(cc: true))
        .frame(width: 320)
}
#Preview("CC installed + Pi detected") {
    EmptyStateView(
        pluginManager: previewPluginManager(
            cc: true, piConfig: true
        )
    )
    .frame(width: 320)
}
#Preview("All installed") {
    EmptyStateView(
        pluginManager: previewPluginManager(
            cc: true, oc: true, ocConfig: true, pi: true, piConfig: true
        )
    )
    .frame(width: 320)
}
#Preview("Pi only") {
    EmptyStateView(
        pluginManager: previewPluginManager(pi: true, piConfig: true)
    )
    .frame(width: 320)
}
