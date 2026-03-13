import SwiftUI

extension Session {
    var sourceBadgeColor: Color {
        source == "opencode" ? .blue : .amber
    }
}

struct SessionCardView: View {
    let session: Session
    /// 1-based index for navigate mode (1-9). nil = normal mode (show accent bar).
    var navigateIndex: Int?
    var showSourceBadge = false
    var isSelected = false
    @State private var isHovered = false
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            // Left accent bar
            accentBar
                .accessibilityHidden(true)

            // Content
            VStack(alignment: .leading, spacing: 2) {
                // Row 1: project name + badges
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            session.status == .idle
                                ? Color.textDimmed : Color.textPrimary
                        )

                    if session.subagentCount > 0 {
                        let count = session.subagentCount
                        Text("\(count) agent\(count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.agentBadge)
                    }

                    if showSourceBadge {
                        Text(session.sourceLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(session.sourceBadgeColor)
                    }

                    Spacer()
                }

                // Row 2: branch / context
                HStack(spacing: 5) {
                    Text(session.branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)

                    if let name = session.sessionName {
                        Text("/")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.textMuted.opacity(0.6))
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    } else if let context = session.contextLine {
                        Text("/")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.textMuted.opacity(0.6))
                        Text(context)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                }
            }

            // Right: status + time
            VStack(alignment: .trailing, spacing: 1) {
                statusLabel
                TimelineView(.periodic(from: .now, by: 10)) { _ in
                    Text(session.relativeTime)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textMuted)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .cardSelectionStyle(
            isSelected: isSelected, isHovered: isHovered, cornerRadius: 0
        )
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardAccessibilityLabel)
        .onAppear { updatePulsing(for: session.status) }
        .onChange(of: session.status) { updatePulsing(for: $0) }
    }

    @ViewBuilder
    private var accentBar: some View {
        if let idx = navigateIndex, idx <= 9 {
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(session.status.color)
                    .frame(width: 16, height: 16)
                Text("\(idx)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityLabel("Press \(idx) to jump")
        } else {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(session.status.color.opacity(accentOpacity))
                .frame(width: 3)
                .opacity(
                    session.status.needsAttention && !pulsing ? 0.6 : 1.0
                )
        }
    }

    private var accentOpacity: Double {
        switch session.status {
        case .waitingPermission, .waitingInput, .needsAttention: return 1.0
        case .working, .compacting: return 0.4
        case .idle: return 0.1
        }
    }

    private var statusLabel: some View {
        Text(statusLabelText)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(statusLabelColor)
    }

    private var statusLabelText: String {
        switch session.status {
        case .idle: return "Idle"
        case .working: return "Working"
        case .compacting: return "Compacting"
        case .waitingPermission: return "Permission"
        case .waitingInput, .needsAttention: return "Waiting"
        }
    }

    private var statusLabelColor: Color {
        switch session.status {
        case .waitingPermission: return Color.amber
        case .waitingInput, .needsAttention: return Color.amber
        case .working, .compacting: return Color.textSecondary
        case .idle: return Color.textMuted
        }
    }

    private var cardAccessibilityLabel: String {
        var parts: [String] = []
        if let idx = navigateIndex, idx <= 9 {
            parts.append("Press \(idx) to jump to")
        }
        parts += [
            session.projectName, "on branch", session.branch,
            session.status.accessibilityDescription,
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

    private func updatePulsing(for status: SessionStatus) {
        if status.needsAttention {
            withAnimation(
                .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
            ) {
                pulsing = true
            }
        } else {
            withAnimation(.default) { pulsing = false }
        }
    }
}

#Preview("Working") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Bash",
            lastToolDetail: "cargo test"
        )
    )
    .frame(width: 300).padding()
}
#Preview("Permission") {
    SessionCardView(
        session: .mock(
            status: .waitingPermission,
            notificationMessage: "Allow Bash: rm -rf"
        )
    )
    .frame(width: 300).padding()
}
#Preview("Idle") {
    SessionCardView(session: .mock(status: .idle))
        .frame(width: 300).padding()
}
#Preview("Compacting") {
    SessionCardView(session: .mock(status: .compacting))
        .frame(width: 300).padding()
}
#Preview("Named Session") {
    SessionCardView(
        session: .mock(
            sessionName: "refactor auth flow", status: .working,
            lastTool: "Edit", lastToolDetail: "/src/auth.ts"
        )
    )
    .frame(width: 300).padding()
}
#Preview("Source Badge CC") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Edit",
            lastToolDetail: "/src/main.rs"
        ),
        showSourceBadge: true
    )
    .frame(width: 300).padding()
}
#Preview("Source Badge OC") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "bash",
            lastToolDetail: "go test ./...", source: "opencode"
        ),
        showSourceBadge: true
    )
    .frame(width: 300).padding()
}
#Preview("Navigate Badge") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Edit",
            lastToolDetail: "/src/auth.ts"
        ),
        navigateIndex: 3
    )
    .frame(width: 300).padding()
}
#Preview("Navigate Attention") {
    SessionCardView(
        session: .mock(
            status: .waitingPermission,
            notificationMessage: "Allow Bash: rm -rf"
        ),
        navigateIndex: 1
    )
    .frame(width: 300).padding()
}
#Preview("Navigate 10+") {
    SessionCardView(
        session: .mock(status: .idle),
        navigateIndex: 10
    )
    .frame(width: 300).padding()
}
#Preview("1 Subagent") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Edit",
            lastToolDetail: "/src/main.rs",
            activeSubagents: [
                SubagentInfo(
                    agentId: "a1", agentType: "Explore",
                    startedAt: Date()
                )
            ]
        )
    )
    .frame(width: 300).padding()
}
#Preview("3 Subagents") {
    SessionCardView(
        session: .mock(
            status: .working, lastTool: "Agent",
            lastToolDetail: "Research API endpoints",
            activeSubagents: [
                SubagentInfo(
                    agentId: "a1", agentType: "Explore",
                    startedAt: Date()
                ),
                SubagentInfo(
                    agentId: "a2", agentType: "Explore",
                    startedAt: Date()
                ),
                SubagentInfo(
                    agentId: "a3", agentType: "Plan",
                    startedAt: Date()
                ),
            ]
        )
    )
    .frame(width: 300).padding()
}
