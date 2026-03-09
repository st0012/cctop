import SwiftUI

struct NotchStatusView: View {
    let counts: StatusCounts

    var body: some View {
        HStack(spacing: 4) {
            GridIcon(highlighted: counts.needsAction > 0)
                .frame(width: 10, height: 10)

            if counts.total > 0 {
                StatusBar(counts: counts)
                    .frame(width: 36, height: 5)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(counts.accessibilityLabel)
    }
}

private struct GridIcon: View {
    let highlighted: Bool

    private var tint: Color {
        highlighted ? StatusColors.accent.color : .white
    }

    var body: some View {
        VStack(spacing: 1.5) {
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(tint.opacity(0.85))
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(tint.opacity(0.85))
            }
            HStack(spacing: 1.5) {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(tint.opacity(0.50))
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(tint.opacity(0.30))
            }
        }
    }
}

private struct StatusBar: View {
    let counts: StatusCounts

    private var segments: [(Double, Color)] {
        var segs: [(Double, Color)] = []
        if counts.needsAction > 0 {
            let color = counts.permission > 0
                ? StatusColors.permission.color
                : StatusColors.attention.color
            segs.append((Double(counts.needsAction) / Double(counts.total), color))
        }
        if counts.working > 0 {
            segs.append((Double(counts.working) / Double(counts.total), StatusColors.working.color))
        }
        if counts.idle > 0 {
            segs.append((Double(counts.idle) / Double(counts.total), StatusColors.idle.color))
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
    NotchStatusView(counts: StatusCounts(permission: 1, attention: 1, working: 2, idle: 0))
        .padding()
        .background(Color.gray)
}

#Preview("All idle") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 0, working: 0, idle: 3))
        .padding()
        .background(Color.gray)
}

#Preview("No sessions") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 0, working: 0, idle: 0))
        .padding()
        .background(Color.gray)
}
