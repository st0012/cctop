import SwiftUI

/// Settings row for the Codex CLI / Desktop integration. Unlike the generic
/// `PluginRowView`, installed hook files are not enough for tracking to work:
/// Codex only runs hooks the user has reviewed and trusted, so this row keeps
/// "installed" and "trusted" as separate user-visible states.
struct CodexPluginRowView: View {
    @ObservedObject var pluginManager: PluginManager
    @StateObject private var setupFlow = CodexSetupFlow()
    @State private var removeHovered = false
    @State private var installFailed = false

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

            if setupFlow.isInstalling {
                EmptyView()
            } else if pluginManager.codexHookStatus == .hooksDisabled {
                settingsHint(
                    icon: "pause.circle.fill",
                    iconColor: Color.statusAttention,
                    text: "Codex hooks are disabled \u{2014} Enable Hooks updates config.toml",
                    textColor: Color.textMuted
                )
                .transition(.opacity)
            } else if pluginManager.codexHookStatus.needsTrust {
                settingsHint(
                    icon: "exclamationmark.circle.fill",
                    iconColor: Color.statusAttention,
                    text: "Hooks installed \u{2014} Codex needs to trust them first",
                    textColor: Color.textMuted
                )
                .transition(.opacity)
            } else if showsLegacyKeyCleanup {
                legacyKeyCleanupHint
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

    @ViewBuilder
    private var trailingControl: some View {
        if setupFlow.isInstalling {
            CodexInstallingIndicator()
        } else {
            switch pluginManager.codexHookStatus {
            case .notInstalled:
                AmberActionButton(label: "Install Hooks") {
                    runInstallAction()
                }
            case .hooksDisabled:
                AmberActionButton(label: "Enable Hooks") {
                    runInstallAction()
                }
            case .needsUpdate:
                AmberActionButton(label: "Update Hooks") {
                    runInstallAction()
                }
            case .installedUntrusted:
                CodexHookTrustButton(
                    label: "Trust Hooks",
                    isPresented: $setupFlow.showWalkthrough,
                    refresh: { pluginManager.refresh() }
                )
                removeButton
            case .trusted:
                HooksReadyBadge()
                removeButton
            }
        }
    }

    /// Old cctop versions wrote the experimental `codex_hooks` flag; Codex
    /// warns on every load of the deprecated name. Install/Update/Remove all
    /// migrate it as part of their work, so a standalone cleanup is only
    /// offered when nothing is installed and no other action would fix it.
    private var showsLegacyKeyCleanup: Bool {
        pluginManager.codexHookStatus == .notInstalled && pluginManager.codexLegacyConfigKey
    }

    private var legacyKeyCleanupHint: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(Color.statusAttention)
            Text("Deprecated codex_hooks key in config.toml")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
            Button {
                if !pluginManager.cleanUpCodexLegacyConfig() { flashFailed() }
            } label: {
                Text("Clean Up")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.amber)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var removeButton: some View {
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

    /// No success flash here on purpose — see `CodexSetupFlow`. Green
    /// appears only once Codex trusts the hooks.
    private func runInstallAction() {
        installFailed = false
        setupFlow.runInstall(using: pluginManager) { flashFailed() }
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

/// Small spinner shown while the install action runs. Deliberately not a
/// checkmark: installing is step one of two, and a success flash here makes
/// users leave before trusting the hooks.
struct CodexInstallingIndicator: View {
    var body: some View {
        HStack(spacing: 5) {
            ProgressView()
                .controlSize(.small)
            Text("Installing\u{2026}")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
        }
    }
}

/// Attention-colored button that opens the manual trust walkthrough. cctop
/// can't trust hooks on the user's behalf — Codex owns the review flow.
/// The parent owns `isPresented` so it can open the walkthrough itself
/// right after an install completes.
struct CodexHookTrustButton: View {
    var label: String
    @Binding var isPresented: Bool
    var refresh: (() -> Void)?

    var body: some View {
        Button { isPresented.toggle() } label: {
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
            .clipShape(RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented) {
            CodexHookTrustInstructions(refresh: refresh)
        }
    }
}

private struct CodexHookTrustInstructions: View {
    var refresh: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("One step left: trust the hooks in Codex")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(
                    "The hooks are installed, but Codex won't run them until "
                        + "you trust them. Sessions won't appear in cctop until then."
                )
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                instructionStep(number: "1", text: "Start a new Codex session in your terminal")
                instructionStep(number: "2", text: "Codex shows \u{201C}Hooks need review\u{201D} at startup")
                instructionStep(number: "3", text: "Choose \u{201C}Trust all and continue\u{201D}")
                instructionStep(number: "4", text: "Come back and click Refresh")
            }

            Text("Codex Desktop has no review prompt \u{2014} trusting once in the CLI covers Desktop too.")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

            HStack {
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
        .frame(width: 260)
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
}

/// Trusted-hooks badge for the Codex row. "Ready" rather than "Connected":
/// trusted hooks mean tracking will work, not that a session is live.
struct HooksReadyBadge: View {
    var body: some View {
        StatusDotBadge(text: "Ready")
    }
}

// MARK: - Previews

@MainActor private func previewCodexPM(status: CodexHookStatus) -> PluginManager {
    let pm = PluginManager(homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false)
    pm.codexConfigExists = true
    pm.codexHookStatus = status
    pm.codexInstalled = status.isInstalled
    return pm
}

#Preview("Not installed") {
    CodexPluginRowView(pluginManager: previewCodexPM(status: .notInstalled))
        .frame(width: 320).padding()
}
#Preview("Untrusted") {
    CodexPluginRowView(pluginManager: previewCodexPM(status: .installedUntrusted))
        .frame(width: 320).padding()
}
#Preview("Hooks disabled") {
    CodexPluginRowView(pluginManager: previewCodexPM(status: .hooksDisabled))
        .frame(width: 320).padding()
}
#Preview("Trusted") {
    CodexPluginRowView(pluginManager: previewCodexPM(status: .trusted))
        .frame(width: 320).padding()
}
#Preview("Stray legacy key") {
    let pm = previewCodexPM(status: .notInstalled)
    pm.codexLegacyConfigKey = true
    return CodexPluginRowView(pluginManager: pm)
        .frame(width: 320).padding()
}
