import SwiftUI

struct NotchStatusView: View {
    let counts: StatusCounts
    var themeId: String = ""

    var body: some View {
        HStack(spacing: 4) {
            GridIcon(highlighted: counts.needsAction > 0)
                .frame(width: 11, height: 11)

            if counts.total > 0 {
                StatusBar(counts: counts)
                    .frame(width: 36, height: 4)
            }
        }
        .id(themeId)
        .padding(.leading, 5)
        .padding(.trailing, 2)
        .padding(.top, 4)
        .padding(.bottom, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.90))
        .clipShape(NotchTabShape(radius: 6))
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
        VStack(spacing: 1) {
            HStack(spacing: 1) {
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(tint.opacity(0.85))
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(tint.opacity(0.85))
            }
            HStack(spacing: 1) {
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
            let segments = counts.barSegments(forWidth: Double(geo.size.width))
            HStack(spacing: 0) {
                ForEach(
                    Array(segments.enumerated()), id: \.offset
                ) { index, seg in
                    if index == segments.count - 1 {
                        // Last segment fills remaining space to avoid float rounding gaps
                        StatusColors.color(for: seg.kind).color
                    } else {
                        StatusColors.color(for: seg.kind).color.frame(width: geo.size.width * seg.proportion)
                    }
                }
            }
        }
        .clipShape(Capsule())
    }
}

/// Notch tab shape: flat top and right edge (meets the notch), rounded bottom-left corner only.
private struct NotchTabShape: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius),
            radius: radius
        )
        path.closeSubpath()
        return path
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

#Preview("1 attention in 10 (min width)") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 1, working: 7, idle: 2))
        .padding()
        .background(Color.black)
}

#Preview("1 permission in 20 (extreme squeeze)") {
    NotchStatusView(counts: StatusCounts(permission: 1, attention: 0, working: 19, idle: 0))
        .padding()
        .background(Color.black)
}

#Preview("No sessions") {
    NotchStatusView(counts: StatusCounts(permission: 0, attention: 0, working: 0, idle: 0))
        .padding()
        .background(Color.black)
}
