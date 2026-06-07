import AppKit
import SwiftUI

struct CodexPluginRowView: View {
    @ObservedObject var pluginManager: PluginManager
    @Binding var installFailed: Bool
    @State private var justInstalled = false
    @State private var removeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Codex CLI / Desktop")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                trailingControl
            }
            .padding(.vertical, 7)

            if justInstalled {
                settingsHint(
                    icon: "checkmark",
                    iconColor: Color.statusGreen,
                    text: "Plugin installed. Use the cctop diagnostics skill to finish setup.",
                    textColor: Color.textMuted,
                    iconWeight: .bold
                )
                .transition(.opacity)
            } else if pluginManager.codexHookStatus == .hooksDisabled {
                settingsHint(
                    icon: "pause.circle.fill",
                    iconColor: Color.statusAttention,
                    text: "Codex hooks are disabled in config.toml.",
                    textColor: Color.textMuted
                )
                .transition(.opacity)
            } else if pluginManager.codexHookStatus.needsTrust {
                settingsHint(
                    icon: "exclamationmark.circle.fill",
                    iconColor: Color.statusAttention,
                    text: pluginManager.codexPluginPackageInstalled
                        ? "Plugin installed. Codex still needs to trust cctop hooks."
                        : "Install the cctop plugin to add Codex hooks.",
                    textColor: Color.textMuted
                )
                .transition(.opacity)
            }

            if installFailed {
                Text("Failed. Check permissions")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.amber)
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if justInstalled {
            EmptyView()
        } else {
            switch pluginManager.codexHookStatus {
            case .notInstalled:
                actionButton("Install Plugin") {
                    runInstallAction()
                }
            case .hooksDisabled:
                actionButton("Enable Hooks") {
                    runInstallAction()
                }
            case .needsUpdate:
                actionButton("Update Plugin") {
                    runInstallAction()
                }
            case .installedUntrusted:
                if pluginManager.codexPluginPackageInstalled {
                    CodexHookTrustButton(label: "Fix Hooks", refresh: { pluginManager.refresh() })
                } else {
                    actionButton("Install Plugin") {
                        runInstallAction()
                    }
                }
            case .trusted:
                installedControls
            }
        }
    }

    private var installedControls: some View {
        Group {
            HooksReadyBadge()
            Button {
                if !pluginManager.removeCodexPlugin() { flashFailed() }
            } label: {
                Text("Remove")
                    .font(.system(size: 10))
                    .foregroundStyle(removeHovered ? Color.textPrimary : Color.textMuted)
            }
            .buttonStyle(.plain)
            .onHover { removeHovered = $0 }
        }
    }

    private func actionButton(_ label: String, action: @escaping () -> Void) -> some View {
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

    private func runInstallAction() {
        if pluginManager.installCodexPluginPackage() {
            justInstalled = true
            installFailed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                justInstalled = false
            }
        } else {
            flashFailed()
        }
    }

    private func flashFailed() {
        installFailed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { installFailed = false }
    }

    private func settingsHint(
        icon: String, iconColor: Color, text: String, textColor: Color,
        iconWeight: Font.Weight = .regular
    ) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: iconWeight))
                .foregroundStyle(iconColor)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(textColor)
            Spacer()
        }
    }
}

struct CodexHookTrustButton: View {
    var label: String
    var refresh: (() -> Void)?
    @State private var showingInstructions = false

    var body: some View {
        Button { showingInstructions.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.segmentActiveText)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.statusAttention)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showingInstructions) {
            CodexHookCheckInstructions(refresh: refresh)
        }
    }
}

private struct CodexHookCheckInstructions: View {
    var refresh: (() -> Void)?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Fix Codex hook trust")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(
                    "Use the cctop diagnostics skill. It checks setup, tries the background trust flow, "
                        + "and drafts a sanitized issue if it gets stuck."
                )
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                instructionStep(number: "1", text: "Open Codex")
                instructionStep(number: "2", text: "Start a new local thread")
                instructionStep(number: "3", text: "Ask: Use $cctop-diagnostics to check my cctop setup")
                instructionStep(number: "4", text: "Review any issue draft before sharing it")
            }

            Text("No Terminal required. The skill reads local diagnostics for you and avoids sharing private paths, prompts, and session IDs.")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            HStack(spacing: 8) {
                Button {
                    NSPasteboard.copyToClipboard(Self.copyText)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copied = false
                    }
                } label: {
                    Text(copied ? "Copied" : "Copy Prompt")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(copied ? Color.statusGreen : Color.textPrimary)
                }
                .buttonStyle(.plain)

                Spacer()

                if let refresh {
                    Button {
                        refresh()
                    } label: {
                        Text("Refresh")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(width: 304)
    }

    private func instructionStep(number: String, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(number)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.statusAttention)
                .frame(width: 12, alignment: .leading)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static let copyText = """
    Use $cctop-diagnostics to check my cctop setup.
    """
}

struct HooksReadyBadge: View {
    var body: some View {
        StatusDotBadge(text: "Ready")
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
