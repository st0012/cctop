import SwiftUI

struct EmptyStateView: View {
    @ObservedObject var pluginManager: PluginManager
    @State private var copiedIndex: Int?
    @State private var justInstalled = false

    private static let ccMarketplace = "claude plugin marketplace add st0012/cctop"
    private static let ccInstall = "claude plugin install cctop"

    private var anyInstalled: Bool { pluginManager.ccInstalled || pluginManager.ocInstalled }

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
            pluginStatusRow("Claude Code", installed: pluginManager.ccInstalled)
            if pluginManager.ocConfigExists {
                ocPluginRow
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
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                pluginStatusRow("opencode", installed: pluginManager.ocInstalled)
                if !pluginManager.ocInstalled && !justInstalled {
                    Button {
                        if pluginManager.installOpenCodePlugin() {
                            justInstalled = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                                justInstalled = false
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
            if justInstalled {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.green)
                    Text("Installed \u{2014} restart opencode to start tracking sessions")
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
                commandRow(Self.ccMarketplace, index: 1)
                commandRow(Self.ccInstall, index: 2)
            }

            if pluginManager.ocConfigExists {
                VStack(spacing: 6) {
                    sectionHeader("opencode")
                    ocPluginRow
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

    private func commandRow(_ command: String, index: Int) -> some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedIndex = index
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if copiedIndex == index { copiedIndex = nil }
                }
            } label: {
                Image(systemName: copiedIndex == index ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copiedIndex == index ? .green : Color.textSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
    cc: Bool = false, oc: Bool = false, ocConfig: Bool = false
) -> PluginManager {
    let pm = PluginManager()
    pm.ccInstalled = cc
    pm.ocInstalled = oc
    pm.ocConfigExists = ocConfig
    return pm
}

#Preview("Not installed (CC only user)") {
    EmptyStateView(pluginManager: previewPluginManager())
        .frame(width: 320)
}
#Preview("Not installed (OC detected)") {
    EmptyStateView(pluginManager: previewPluginManager(ocConfig: true))
        .frame(width: 320)
}
#Preview("Not installed (OC installed)") {
    EmptyStateView(pluginManager: previewPluginManager(oc: true, ocConfig: true))
        .frame(width: 320)
}
#Preview("CC installed") {
    EmptyStateView(pluginManager: previewPluginManager(cc: true))
        .frame(width: 320)
}
#Preview("CC installed + OC detected") {
    EmptyStateView(pluginManager: previewPluginManager(cc: true, ocConfig: true))
        .frame(width: 320)
}
#Preview("Both installed") {
    EmptyStateView(pluginManager: previewPluginManager(cc: true, oc: true, ocConfig: true))
        .frame(width: 320)
}
#Preview("OC only") {
    EmptyStateView(pluginManager: previewPluginManager(oc: true, ocConfig: true))
        .frame(width: 320)
}
