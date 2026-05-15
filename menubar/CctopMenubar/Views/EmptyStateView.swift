import SwiftUI

/// First-run / no-sessions view. Shows a small branded hero, an install card
/// listing every detected agent with its identity color and current state,
/// and a discovery footer for any supported agents not detected on this
/// machine.
struct EmptyStateView: View {
    @ObservedObject var pluginManager: PluginManager
    @State private var justInstalled: Set<AgentKind> = []
    @State private var installFailed = false
    @State private var showCodexFlagAlert = false
    private static let codexFlagWarning =
        "Codex CLI requires the codex_hooks feature flag, which is "
        + "experimental. Codex will show a startup warning."

    var body: some View {
        VStack(spacing: 14) {
            heroMark
            heroCopy
            agentCard
            if !undetectedAgents.isEmpty {
                alsoWorksFooter
            }
            if anyUninstalled {
                restartHint
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
        .alert("Enable experimental feature?", isPresented: $showCodexFlagAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Enable & Install") { performCodexInstall() }
        } message: {
            Text(Self.codexFlagWarning)
        }
    }

    // MARK: - Hero

    private var heroMark: some View {
        VStack(spacing: 6) {
            Text("cctop_")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.amber)
                .tracking(0.5)
            HStack(spacing: 0) {
                Rectangle().fill(Color.statusGreen).frame(width: 26)
                Rectangle().fill(Color.statusAttention).frame(width: 14)
                Rectangle().fill(Color.statusPermission).frame(width: 8)
                Rectangle().fill(SessionStatus.idle.color).frame(width: 16)
            }
            .frame(height: 4)
            .clipShape(Capsule())
        }
        .padding(.top, 2)
    }

    private var heroCopy: some View {
        VStack(spacing: 4) {
            Text("Monitor your AI coding sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
        }
    }

    private var subtitle: String {
        if allConnected {
            return "Start a session \u{2014} it will appear here automatically."
        }
        return "Install the plugin for your AI tool to see live status here."
    }

    // MARK: - Agent card

    private var agentCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(detectedAgents.enumerated()), id: \.element) { index, agent in
                if index > 0 {
                    Divider().padding(.horizontal, 0)
                }
                agentRow(agent)
            }
        }
        .background(Color.cardBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.cardBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func agentRow(_ agent: AgentKind) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(agent.accentColor)
                    .frame(width: 3, height: 18)
                Text(agent.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                trailingControl(for: agent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if justInstalled.contains(agent) {
                installedHint(for: agent)
            }
        }
    }

    @ViewBuilder
    private func trailingControl(for agent: AgentKind) -> some View {
        if justInstalled.contains(agent) {
            EmptyView()
        } else if isInstalled(agent) {
            if needsUpdate(agent) {
                installButton(label: "Update", agent: agent)
            } else {
                connectedBadge
            }
        } else if agent == .claudeCode {
            ClaudeCodeInstallButton()
        } else {
            installButton(label: "Install", agent: agent)
        }
    }

    private var connectedBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(Color.statusGreen).frame(width: 5, height: 5)
            Text("Connected")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
        }
    }

    private func installButton(label: String, agent: AgentKind) -> some View {
        Button {
            triggerInstall(for: agent)
        } label: {
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

    private func installedHint(for agent: AgentKind) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.statusGreen)
            Text("Installed \u{2014} restart \(agent.displayName) to start tracking")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.opacity)
    }

    // MARK: - Also works with

    private var alsoWorksFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Also works with")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.textMuted)
                .textCase(.uppercase)
                .tracking(0.8)
            HStack(spacing: 12) {
                ForEach(undetectedAgents, id: \.self) { agent in
                    HStack(spacing: 5) {
                        Circle().fill(agent.accentColor).frame(width: 6, height: 6)
                        Text(agent.displayName)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    // MARK: - Restart hint

    private var restartHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
            Text("Restart sessions after installing to pick up hooks")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Install actions

    private func triggerInstall(for agent: AgentKind) {
        let success: Bool
        switch agent {
        case .claudeCode:
            return  // Handled by ClaudeCodeInstallButton
        case .opencode:
            success = pluginManager.installOpenCodePlugin()
        case .pi:
            success = pluginManager.installPiPlugin()
        case .codex:
            if pluginManager.codexFlagAlreadyEnabled {
                success = pluginManager.installCodexPlugin()
            } else {
                showCodexFlagAlert = true
                return
            }
        }
        handleInstallResult(agent: agent, success: success)
    }

    private func performCodexInstall() {
        let success = pluginManager.installCodexPlugin()
        handleInstallResult(agent: .codex, success: success)
    }

    private func handleInstallResult(agent: AgentKind, success: Bool) {
        if success {
            justInstalled.insert(agent)
            installFailed = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                justInstalled.remove(agent)
            }
        } else {
            installFailed = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                installFailed = false
            }
        }
    }

    // MARK: - Derived state

    private var detectedAgents: [AgentKind] {
        AgentKind.allCases.filter { isDetected($0) }
    }

    private var undetectedAgents: [AgentKind] {
        AgentKind.allCases.filter { !isDetected($0) }
    }

    private var anyUninstalled: Bool {
        detectedAgents.contains { !isInstalled($0) || needsUpdate($0) }
    }

    private var allConnected: Bool {
        !detectedAgents.contains { !isInstalled($0) || needsUpdate($0) }
    }

    private func isDetected(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claudeCode: return true   // Always supported
        case .opencode:   return pluginManager.ocConfigExists
        case .pi:         return pluginManager.piConfigExists
        case .codex:      return pluginManager.codexConfigExists
        }
    }

    private func isInstalled(_ agent: AgentKind) -> Bool {
        switch agent {
        case .claudeCode: return pluginManager.ccInstalled
        case .opencode:   return pluginManager.ocInstalled
        case .pi:         return pluginManager.piInstalled
        case .codex:      return pluginManager.codexInstalled
        }
    }

    private func needsUpdate(_ agent: AgentKind) -> Bool {
        switch agent {
        case .opencode: return pluginManager.ocNeedsUpdate
        case .codex:    return pluginManager.codexNeedsUpdate
        default:        return false
        }
    }
}

// MARK: - AgentKind

private enum AgentKind: String, CaseIterable, Hashable {
    case claudeCode, opencode, pi, codex

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .opencode:   return "opencode"
        case .pi:         return "pi"
        case .codex:      return "Codex CLI"
        }
    }

    var accentColor: Color {
        switch self {
        case .claudeCode: return .amber
        case .opencode:   return .opencodeBadge
        case .pi:         return .piBadge
        case .codex:      return .codexBadge
        }
    }
}

// MARK: - Previews

@MainActor
private func previewPluginManager(
    cc: Bool = false, oc: Bool = false, ocConfig: Bool = false,
    pi: Bool = false, piConfig: Bool = false,
    codex: Bool = false, codexConfig: Bool = false
) -> PluginManager {
    let pm = PluginManager()
    pm.ccInstalled = cc
    pm.ocInstalled = oc
    pm.ocConfigExists = ocConfig
    pm.piInstalled = pi
    pm.piConfigExists = piConfig
    pm.codexInstalled = codex
    pm.codexConfigExists = codexConfig
    return pm
}

#Preview("Fresh user (CC only)") {
    EmptyStateView(pluginManager: previewPluginManager())
        .frame(width: 320)
        .background(Color.panelBackground)
}

#Preview("All detected, nothing installed") {
    EmptyStateView(
        pluginManager: previewPluginManager(
            ocConfig: true, piConfig: true, codexConfig: true
        )
    )
    .frame(width: 320)
    .background(Color.panelBackground)
}

#Preview("CC installed, others detected") {
    EmptyStateView(
        pluginManager: previewPluginManager(
            cc: true, ocConfig: true, piConfig: true, codexConfig: true
        )
    )
    .frame(width: 320)
    .background(Color.panelBackground)
}

#Preview("All connected") {
    EmptyStateView(
        pluginManager: previewPluginManager(
            cc: true,
            oc: true, ocConfig: true,
            pi: true, piConfig: true,
            codex: true, codexConfig: true
        )
    )
    .frame(width: 320)
    .background(Color.panelBackground)
}

#Preview("Mixed states") {
    EmptyStateView(
        pluginManager: previewPluginManager(
            cc: true,
            ocConfig: true,
            pi: true, piConfig: true
        )
    )
    .frame(width: 320)
    .background(Color.panelBackground)
}

#Preview("Pi only") {
    EmptyStateView(
        pluginManager: previewPluginManager(pi: true, piConfig: true)
    )
    .frame(width: 320)
    .background(Color.panelBackground)
}
