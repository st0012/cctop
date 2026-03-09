import SwiftUI

struct NotchStatusView: View {
    let counts: StatusCounts

    var body: some View {
        HStack(spacing: 4) {
            GridIcon(highlighted: counts.needsAction > 0)
                .frame(width: 10, height: 10)

            if counts.total > 0 {
                StatusBar(counts: counts)
                    .frame(width: 36, height: 6)
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
                    .fill(tint.opacity(0.45))
            }
        }
    }
}

private struct StatusBar: View {
    let counts: StatusCounts

    var body: some View {
        GeometryReader { geo in
            let segments = counts.barSegments
            HStack(spacing: 0) {
                ForEach(
                    Array(segments.enumerated()), id: \.offset
                ) { index, seg in
                    if index == segments.count - 1 {
                        // Last segment fills remaining space to avoid float rounding gaps
                        seg.color.color
                    } else {
                        seg.color.color.frame(width: geo.size.width * seg.proportion)
                    }
                }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview("Mixed") {
    NotchStatusView(counts: StatusCounts(permission: 1, attention: 1, working: 2, idle: 1))
        .padding()
        .background(Color.black)
}

#Preview("Needs permission") {
    NotchStatusView(counts: StatusCounts(permission: 2, attention: 0, working: 1, idle: 0))
        .padding()
        .background(Color.black)
}

#Preview("All working") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 0, working: 4, idle: 0))
        .padding()
        .background(Color.black)
}

#Preview("All idle") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 0, working: 0, idle: 3))
        .padding()
        .background(Color.black)
}

#Preview("No sessions") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 0, working: 0, idle: 0))
        .padding()
        .background(Color.black)
}
