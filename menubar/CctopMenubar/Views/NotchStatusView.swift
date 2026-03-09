import SwiftUI

struct NotchStatusView: View {
    let permission: Int
    let attention: Int
    let working: Int
    let idle: Int

    private var total: Int { permission + attention + working + idle }

    var body: some View {
        HStack(spacing: 4) {
            // Grid icon (matches MenubarIcon asset style)
            GridIcon()
                .frame(width: 10, height: 10)

            if total > 0 {
                StatusBar(
                    permission: permission, attention: attention,
                    working: working, idle: idle, total: total
                )
                .frame(width: 36, height: 5)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct GridIcon: View {
    var body: some View {
        VStack(spacing: 1.5) {
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.white.opacity(0.85))
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.white.opacity(0.85))
            }
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.white.opacity(0.50))
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(Color.white.opacity(0.30))
            }
        }
    }
}

private struct StatusBar: View {
    let permission: Int
    let attention: Int
    let working: Int
    let idle: Int
    let total: Int

    private var needsAction: Int { permission + attention }

    private var segments: [(Double, Color)] {
        var segs: [(Double, Color)] = []
        if needsAction > 0 {
            let color = permission > 0
                ? StatusColors.permission.color
                : StatusColors.attention.color
            segs.append((Double(needsAction) / Double(total), color))
        }
        if working > 0 {
            segs.append((Double(working) / Double(total), StatusColors.working.color))
        }
        if idle > 0 {
            segs.append((Double(idle) / Double(total), StatusColors.idle.color))
        }
        return segs
    }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(
                    Array(segments.enumerated()), id: \.offset
                ) { _, seg in
                    seg.1.frame(width: geo.size.width * seg.0)
                }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview("Mixed") {
    NotchStatusView(permission: 1, attention: 1, working: 2, idle: 0)
        .padding()
        .background(Color.gray)
}

#Preview("All idle") {
    NotchStatusView(permission: 0, attention: 0, working: 0, idle: 3)
        .padding()
        .background(Color.gray)
}

#Preview("No sessions") {
    NotchStatusView(permission: 0, attention: 0, working: 0, idle: 0)
        .padding()
        .background(Color.gray)
}
