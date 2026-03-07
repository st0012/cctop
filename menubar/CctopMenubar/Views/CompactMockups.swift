import SwiftUI

// MARK: - Concept A: "Dot Strip" (narrow + translucent)
// 28px tall, dynamic width, 14x14 logo + one dot per session
// Semi-transparent background

struct DotStripView: View {
    let sessions: [Session]

    private var dotGroups: [(color: Color, size: CGFloat, count: Int)] {
        let counts = HeaderView.statusCounts(for: sessions)
        var groups: [(Color, CGFloat, Int)] = []
        if counts.permission > 0 { groups.append((.red, 8, counts.permission)) }
        if counts.attention > 0 { groups.append((Color.amber, 8, counts.attention)) }
        if counts.working > 0 { groups.append((Color.statusGreen, 6, counts.working)) }
        if counts.idle > 0 { groups.append((.gray, 6, counts.idle)) }
        return groups
    }

    private var needsAttention: Bool {
        let counts = HeaderView.statusCounts(for: sessions)
        return counts.permission > 0 || counts.attention > 0
    }

    var body: some View {
        HStack(spacing: 0) {
            // Logo
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.amber.opacity(needsAttention ? 1.0 : 0.5))
                .frame(width: 14, height: 14)
                .overlay(
                    Text("C")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.red.opacity(needsAttention ? 0.8 : 0), lineWidth: 1.5)
                )

            if !sessions.isEmpty {
                Spacer().frame(width: 10)

                // Dots grouped by status
                HStack(spacing: 3) {
                    ForEach(Array(dotGroups.enumerated()), id: \.offset) { groupIdx, group in
                        if groupIdx > 0 {
                            Spacer().frame(width: 5)
                        }
                        ForEach(0..<group.count, id: \.self) { _ in
                            Circle()
                                .fill(needsAttention ? group.color : Color.secondary.opacity(0.35))
                                .frame(width: group.size, height: group.size)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
    }
}

// MARK: - Mock data helpers

private let allClearSessions: [Session] = [
    .mock(status: .working, lastTool: "Edit"),
    .mock(status: .working, lastTool: "Bash"),
    .mock(status: .idle),
    .mock(status: .idle),
]

private let mixedSessions: [Session] = [
    .mock(status: .waitingPermission),
    .mock(status: .waitingPermission),
    .mock(status: .waitingInput),
    .mock(status: .working, lastTool: "Edit"),
    .mock(status: .working, lastTool: "Bash"),
    .mock(status: .idle),
]

private let singleAttention: [Session] = [
    .mock(status: .waitingPermission),
    .mock(status: .working, lastTool: "Edit"),
    .mock(status: .working, lastTool: "Bash"),
]

private let manySessions: [Session] = [
    .mock(status: .waitingPermission),
    .mock(status: .waitingInput),
    .mock(status: .working, lastTool: "Edit"),
    .mock(status: .working, lastTool: "Bash"),
    .mock(status: .working, lastTool: "Read"),
    .mock(status: .working, lastTool: "Grep"),
    .mock(status: .idle),
    .mock(status: .idle),
    .mock(status: .idle),
    .mock(status: .compacting),
]

private let currentHeader: [Session] = Session.qaShowcase

// MARK: - Previews

#Preview("Concept A: Dot Strip") {
    VStack(spacing: 20) {
        label("All Clear (2 working, 2 idle)")
        TranslucentPill { DotStripView(sessions: allClearSessions) }

        label("Needs Attention (2 perm, 1 input, 2 working, 1 idle)")
        TranslucentPill { DotStripView(sessions: mixedSessions) }

        label("Single Alert (1 perm, 2 working)")
        TranslucentPill { DotStripView(sessions: singleAttention) }

        label("Many Sessions (10)")
        TranslucentPill { DotStripView(sessions: manySessions) }
    }
    .padding(24)
    .frame(width: 360)
    .background(desktopGradient)
}

#Preview("Concept B: Smart Bar") {
    VStack(spacing: 20) {
        label("All Clear (2 working, 2 idle)")
        TranslucentPill { SmartBarView(sessions: allClearSessions) }

        label("Needs Attention (2 perm, 1 input, 2 working, 1 idle)")
        TranslucentPill { SmartBarView(sessions: mixedSessions) }

        label("Single Alert (1 perm, 2 working)")
        TranslucentPill { SmartBarView(sessions: singleAttention) }

        label("Many Sessions (10)")
        TranslucentPill { SmartBarView(sessions: manySessions) }
    }
    .padding(24)
    .frame(width: 360)
    .background(desktopGradient)
}

#Preview("Side-by-Side Comparison") {
    VStack(spacing: 20) {
        label("CURRENT (44px, 320px wide)")
        HeaderView(sessions: currentHeader, isCompactMode: true)
            .background(.ultraThinMaterial.opacity(0.85))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .frame(width: 320)

        label("CONCEPT A: DOT STRIP (28px, narrow)")
        TranslucentPill { DotStripView(sessions: currentHeader) }

        label("CONCEPT B: SMART BAR (32px, narrow)")
        TranslucentPill { SmartBarView(sessions: currentHeader) }
    }
    .padding(24)
    .frame(width: 360)
    .background(desktopGradient)
}

// Helpers for previews
private func label(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.7))
        .frame(maxWidth: .infinity, alignment: .leading)
}

// Simulated desktop background for translucency demo
private var desktopGradient: some View {
    LinearGradient(
        colors: [
            Color(red: 0.15, green: 0.12, blue: 0.25),
            Color(red: 0.1, green: 0.18, blue: 0.28),
            Color(red: 0.12, green: 0.15, blue: 0.22),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}
