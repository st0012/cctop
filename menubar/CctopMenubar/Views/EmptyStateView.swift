import SwiftUI

/// First-run / no-sessions view. Shows a small branded hero and a single
/// install card that always lists every supported agent — Claude Code/Desktop,
/// opencode, pi, Codex CLI/Desktop — with its identity color and current state.
/// Agents not detected on this machine render with a muted "Not detected"
/// trailing label so users always see the full set of supported tools.
struct EmptyStateView: View {
    @ObservedObject var pluginManager: PluginManager
    @State private var justInstalled: Set<AgentKind> = []
    @State private var failedAgent: AgentKind?

    var body: some View {
        VStack(spacing: 14) {
            heroMark
            heroCopy
            agentCard
            if anyUninstalled {
                restartHint
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity)
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
        return "Install the plugin or hooks for your AI tool to see live status here."
    }

    // MARK: - Agent card

    private var agentCard: some View {
        VStack(spacing: 0) {
            ForEach(Array(AgentKind.allCases.enumerated()), id: \.element) { index, agent in
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
        let detected = isDetected(agent)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(agent.accentColor)
                    .frame(width: 3, height: 18)
                    .opacity(detected ? 1.0 : 0.45)
                Text(agent.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(detected ? Color.textPrimary : Color.textMuted)
                Spacer()
                trailingControl(for: agent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if justInstalled.contains(agent) {
                installedHint(for: agent)
            } else if failedAgent == agent {
                failedHint
            }
        }
    }

    @ViewBuilder
    private func trailingControl(for agent: AgentKind) -> some View {
        if justInstalled.contains(agent) {
            EmptyView()
        } else if !isDetected(agent) {
            notDetectedBadge
        } else if needsUpdate(agent) {
            installButton(label: "Update", agent: agent)
        } else if isInstalled(agent) {
            ConnectedBadge()
        } else if agent == .claudeCode {
            ClaudeCodeInstallButton()
        } else {
            installButton(label: "Install", agent: agent)
        }
    }

    private var notDetectedBadge: some View {
        Text("Not detected")
            .font(.system(size: 10))
            .foregroundStyle(Color.textMuted)
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
        hintRow(
            icon: "checkmark",
            iconColor: Color.statusGreen,
            text: "Installed \u{2014} restart \(agent.displayName) to start tracking",
            textColor: Color.textMuted,
            iconWeight: .bold
        )
    }

    private var failedHint: some View {
        hintRow(
            icon: "exclamationmark.triangle.fill",
            iconColor: Color.amber,
            text: "Install failed \u{2014} check file permissions and try again",
            textColor: Color.amber
        )
    }

    private func hintRow(
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
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .transition(.opacity)
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
            success = pluginManager.installCodexPlugin()
        }
        handleInstallResult(agent: agent, success: success)
    }

    private func handleInstallResult(agent: AgentKind, success: Bool) {
        if success {
            justInstalled.insert(agent)
            failedAgent = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                justInstalled.remove(agent)
            }
        } else {
            failedAgent = agent
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                if failedAgent == agent { failedAgent = nil }
            }
        }
    }

    // MARK: - Derived state

    private var anyUninstalled: Bool {
        AgentKind.allCases.contains {
            isDetected($0) && (!isInstalled($0) || needsUpdate($0))
        }
    }

    private var allConnected: Bool {
        !anyUninstalled
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
        case .claudeCode: return "Claude Code / Desktop"
        case .opencode:   return "opencode"
        case .pi:         return "pi"
        case .codex:      return "Codex CLI / Desktop"
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
