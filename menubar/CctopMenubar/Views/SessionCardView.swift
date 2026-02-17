import SwiftUI

extension Session {
    var sourceBadgeColor: Color {
        source == "opencode" ? .blue : .amber
    }
}

struct SessionCardView: View {
    let session: Session
    /// 1-based index for Quick Jump mode (1-9). nil = normal mode (show status dot).
    var jumpIndex: Int?
    var showSourceBadge = false
    var isSelected = false
    @State private var isHovered = false
    @State private var pulsing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Row 1: status indicator + project name + time + status badge
            HStack(spacing: 5) {
                statusIndicator
                    .accessibilityHidden(true)

                Text(session.projectName)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)

                if showSourceBadge {
                    Text(session.sourceLabel)
                        .font(.system(size: 9))
                        .foregroundStyle(session.sourceBadgeColor)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(session.sourceBadgeColor.opacity(0.1))
                        .clipShape(Capsule())
                }

                Spacer()

                TimelineView(.periodic(from: .now, by: 10)) { _ in
                    Text(session.relativeTime)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textMuted)
                }

                Text(session.status.label)
                    .font(.system(size: 9))
                    .foregroundStyle(session.status.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(session.status.color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(session.status.color.opacity(0.25), lineWidth: 1))
            }

            // Row 2: branch pill + optional session name
            HStack(spacing: 6) {
                Text(session.branch)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))

                if let name = session.sessionName {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.textMuted)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 17)

            // Row 3: context line (non-idle only)
            if let context = session.contextLine {
                Text(context)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .padding(.leading, 17)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .cardSelectionStyle(isSelected: isSelected, isHovered: isHovered)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(cardAccessibilityLabel)
        .onAppear { updatePulsing(for: session.status) }
        .onChange(of: session.status) { updatePulsing(for: $0) }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        ZStack {
            if let idx = jumpIndex, idx <= 9 {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 16, height: 16)
                Text("\(idx)")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 9, height: 9)
            }
        }
        .frame(width: 16, height: 16)
        .opacity(session.status.needsAttention && !pulsing ? 0.6 : 1.0)
    }

    private var cardAccessibilityLabel: String {
        var parts: [String] = []
        if let idx = jumpIndex, idx <= 9 {
            parts.append("Press \(idx) to jump to")
        }
        parts += [session.projectName, "on branch", session.branch, session.status.accessibilityDescription]
        if let context = session.contextLine {
            parts.append(context)
        }
        return parts.joined(separator: ", ")
    }

    private func updatePulsing(for status: SessionStatus) {
        if status.needsAttention {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        } else {
            withAnimation(.default) { pulsing = false }
        }
    }
}

#Preview("Working") {
    SessionCardView(session: .mock(status: .working, lastTool: "Bash", lastToolDetail: "cargo test"))
        .frame(width: 300).padding()
}
#Preview("Permission") {
    SessionCardView(session: .mock(status: .waitingPermission, notificationMessage: "Allow Bash: rm -rf"))
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
    SessionCardView(session: .mock(sessionName: "refactor auth flow", status: .working, lastTool: "Edit", lastToolDetail: "/src/auth.ts"))
        .frame(width: 300).padding()
}
#Preview("Source Badge CC") {
    SessionCardView(
        session: .mock(status: .working, lastTool: "Edit", lastToolDetail: "/src/main.rs"),
        showSourceBadge: true
    )
    .frame(width: 300).padding()
}
#Preview("Source Badge OC") {
    SessionCardView(
        session: .mock(status: .working, lastTool: "bash", lastToolDetail: "go test ./...", source: "opencode"),
        showSourceBadge: true
    )
    .frame(width: 300).padding()
}
#Preview("Jump Mode Badge") {
    SessionCardView(
        session: .mock(status: .working, lastTool: "Edit", lastToolDetail: "/src/auth.ts"),
        jumpIndex: 3
    )
    .frame(width: 300).padding()
}
#Preview("Jump Mode Attention") {
    SessionCardView(
        session: .mock(status: .waitingPermission, notificationMessage: "Allow Bash: rm -rf"),
        jumpIndex: 1
    )
    .frame(width: 300).padding()
}
#Preview("Jump Mode 10+") {
    SessionCardView(
        session: .mock(status: .idle),
        jumpIndex: 10
    )
    .frame(width: 300).padding()
}
