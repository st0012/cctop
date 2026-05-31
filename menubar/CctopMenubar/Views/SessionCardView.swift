import SwiftUI

struct SessionCardView: View {
    let session: Session
    /// 1-based index for navigate mode (1-9). nil = normal mode.
    var navigateIndex: Int?
    var showSourceBadge = false
    var isSelected = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false
    @State private var attentionPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleRow
            metaRow
            thirdRowContent
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .cardSelectionStyle(
            isSelected: isSelected, isHovered: isHovered, cornerRadius: 0
        )
        // Dormant = desktop host app is not running; mute it so live work reads first.
        .opacity(session.lifecycle == .dormant ? 0.62 : 1.0)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardAccessibilityLabel)
        .onAppear { startAttentionPulseIfNeeded() }
        .onChange(of: session.status) { _ in startAttentionPulseIfNeeded() }
        // Without this, toggling macOS Reduce Motion while a waiting/permission
        // card is already on screen leaves attentionPulse stuck in its previous
        // state — the env value updates, but the @State pulse flag doesn't get
        // re-evaluated until the next status transition.
        .onChange(of: reduceMotion) { _ in startAttentionPulseIfNeeded() }
    }

    // MARK: - Rows

    private var titleRow: some View {
        HStack(spacing: 8) {
            if let idx = navigateIndex, idx <= 9 {
                navigateChip(idx)
            }
            Text(session.displayName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(
                    session.status == .idle ? Color.textSecondary : Color.textPrimary
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            if session.subagentCount > 0 {
                let count = session.subagentCount
                Text("\(count) agent\(count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.agentBadge)
            }

            statusLabel

            // TimelineView re-evaluates the closure every 10s so "just now / 5s /
            // 2m" labels (and the fresh/stale color transitions in `timeColor`)
            // stay live even when no session-file write triggers a re-render.
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                Text("· \(session.relativeTime)")
                    .font(.system(size: 10))
                    .foregroundStyle(timeColor)
            }
        }
    }

    @ViewBuilder
    private var metaRow: some View {
        // For Desktop sessions, folder + branch are usually noise (worktree dirs,
        // "unknown" branches), and the long "Claude Desktop" chip causes the row
        // to wrap when combined with them. Show only the Desktop app's own project
        // label plus the source badge.
        if session.agentBadge.isDesktop {
            if session.desktopProjectName != nil || showSourceBadge {
                HStack(spacing: 5) {
                    if let desktopProjectName = session.desktopProjectName {
                        Text(desktopProjectName)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    if showSourceBadge {
                        if session.desktopProjectName != nil {
                            Text("·")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.textMuted.opacity(0.6))
                        }
                        SourceBadgeView(badge: session.agentBadge)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    Spacer(minLength: 0)
                }
            }
        } else {
            HStack(spacing: 5) {
                // Folder shown only when sessionName is set AND differs from projectName,
                // otherwise the headline title would already display the folder name.
                if let name = session.sessionName, name != session.projectName {
                    Text(session.projectName)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textMuted.opacity(0.6))
                }
                Text(session.branch)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
                    .lineLimit(1)
                if showSourceBadge {
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textMuted.opacity(0.6))
                    SourceBadgeView(badge: session.agentBadge)
                }
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private var thirdRowContent: some View {
        if let cmd = workingCommandText {
            HStack(spacing: 0) {
                Text("› ")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.statusGreen.opacity(0.7))
                Text(cmd)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if session.status == .working {
                    BlinkingCaret().padding(.leading, 3)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 3)
        } else if let note = attentionNoteText {
            Text(note)
                .font(.system(size: 11))
                .italic()
                .foregroundStyle(Color.statusAttention)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.top, 3)
        }
    }

    // MARK: - Status label

    private var statusLabel: some View {
        Text(statusLabelText)
            .font(.system(size: 10.5, weight: statusLabelWeight))
            .foregroundStyle(statusLabelColor)
            .padding(.horizontal, isAttentionStatus ? 6 : 0)
            .padding(.vertical, isAttentionStatus ? 1.5 : 0)
            .background {
                if isAttentionStatus {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.statusAttention.opacity(attentionPulse ? 0.22 : 0.10))
                }
            }
    }

    private var statusLabelText: String {
        if session.lifecycle == .dormant { return "Dormant" }
        switch session.status {
        case .idle: return "Idle"
        case .working: return "Working"
        case .compacting: return "Compacting"
        case .waitingPermission: return "Permission"
        case .waitingInput, .needsAttention: return "Waiting"
        }
    }

    private var statusLabelWeight: Font.Weight {
        switch session.status {
        case .working, .waitingInput, .needsAttention, .waitingPermission: return .semibold
        case .compacting, .idle: return .medium
        }
    }

    private var statusLabelColor: Color {
        switch session.status {
        case .waitingPermission: return Color.statusPermission
        case .waitingInput, .needsAttention: return Color.statusAttention
        case .working: return Color.statusGreen
        case .compacting: return Color.textSecondary
        case .idle: return Color.textMuted
        }
    }

    private var isAttentionStatus: Bool {
        switch session.status {
        case .waitingInput, .needsAttention, .waitingPermission: return true
        default: return false
        }
    }

    // MARK: - Navigate chip

    @ViewBuilder
    private func navigateChip(_ idx: Int) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(session.status.color)
                .frame(width: 16, height: 16)
            Text("\(idx)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Press \(idx) to jump")
    }

    // MARK: - Computed copy

    /// Text for the third row when the session is working/compacting — the command stripe.
    /// Reuses `Session.contextLine` formatting (Reading X.swift, Running: foo, etc.).
    private var workingCommandText: String? {
        guard session.status == .working || session.status == .compacting else { return nil }
        return session.contextLine
    }

    /// Italic warm note for waiting/permission/needs-attention states.
    private var attentionNoteText: String? {
        switch session.status {
        case .waitingPermission:
            return session.notificationMessage ?? "Permission needed"
        case .waitingInput, .needsAttention:
            return session.contextLine ?? "Waiting for input"
        default:
            return nil
        }
    }

    private var timeColor: Color {
        // "just now" → accent (fresh); stale (>7d) → dimmer; otherwise muted.
        let seconds = -session.lastActivity.timeIntervalSinceNow
        if seconds <= 5 { return Color.statusGreen }
        if seconds > 7 * 86_400 { return Color.textMuted.opacity(0.55) }
        return Color.textMuted
    }

    private var cardAccessibilityLabel: String {
        var parts: [String] = []
        if let idx = navigateIndex, idx <= 9 {
            parts.append("Press \(idx) to jump to")
        }
        parts += [
            session.displayName, "on branch", session.branch,
            session.status.accessibilityDescription
        ]
        if session.subagentCount > 0 {
            parts.append(
                "\(session.subagentCount) active subagent\(session.subagentCount == 1 ? "" : "s")"
            )
        }
        if let context = session.contextLine {
            parts.append(context)
        }
        return parts.joined(separator: ", ")
    }

    // MARK: - Animations

    private func startAttentionPulseIfNeeded() {
        guard isAttentionStatus, !reduceMotion else {
            attentionPulse = false
            return
        }
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            attentionPulse = true
        }
    }
}

// MARK: - Previews

#Preview("Working — CC") {
    SessionCardView(
        session: .mock(
            sessionName: "Review RDoc pull request",
            status: .working, lastTool: "Read",
            lastToolDetail: "/src/SessionCardView.swift",
            source: "cc"
        ),
        showSourceBadge: true
    )
    .frame(width: 340).padding()
}

#Preview("Working — Claude Desktop") {
    SessionCardView(
        session: .mock(
            sessionName: "Verify Ruby master build",
            status: .working, lastTool: "Bash",
            lastToolDetail: "cd build && source /opt/homebrew/share/chruby/chruby.sh",
            terminal: TerminalInfo(bundleId: "com.anthropic.claudefordesktop"),
            source: nil
        ),
        showSourceBadge: true
    )
    .frame(width: 340).padding()
}

#Preview("Waiting — Permission") {
    SessionCardView(
        session: .mock(
            sessionName: "Verify migration safety",
            status: .waitingPermission,
            notificationMessage: "Allow Bash: rm -rf node_modules",
            source: "cc"
        ),
        showSourceBadge: true
    )
    .frame(width: 340).padding()
}

#Preview("Idle — Codex Desktop") {
    SessionCardView(
        session: .mock(
            sessionName: "Investigate tanstack incident",
            status: .idle,
            terminal: TerminalInfo(bundleId: "com.openai.codex"),
            source: "codex"
        ),
        showSourceBadge: true
    )
    .frame(width: 340).padding()
}

#Preview("Idle — no session name") {
    SessionCardView(
        session: .mock(
            project: "relaxed-gauss-e8a8ec",
            branch: "claude/relaxed-gauss-e8a8ec",
            status: .idle,
            source: "cc"
        ),
        showSourceBadge: true
    )
    .frame(width: 340).padding()
}

#Preview("Navigate badge") {
    SessionCardView(
        session: .mock(
            sessionName: "Review RDoc pull request",
            status: .working, lastTool: "Edit",
            lastToolDetail: "/src/auth.ts",
            source: "cc"
        ),
        navigateIndex: 3,
        showSourceBadge: true
    )
    .frame(width: 340).padding()
}

#Preview("3 subagents") {
    SessionCardView(
        session: .mock(
            sessionName: "Refactor auth flow",
            status: .working, lastTool: "Agent",
            lastToolDetail: "Research API endpoints",
            source: "cc",
            activeSubagents: [
                SubagentInfo(agentId: "a1", agentType: "Explore", startedAt: Date()),
                SubagentInfo(agentId: "a2", agentType: "Explore", startedAt: Date()),
                SubagentInfo(agentId: "a3", agentType: "Plan", startedAt: Date())
            ]
        ),
        showSourceBadge: true
    )
    .frame(width: 340).padding()
}
