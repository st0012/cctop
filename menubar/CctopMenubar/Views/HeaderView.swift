import SwiftUI

struct HeaderView: View {
    let sessions: [Session]

    var body: some View {
        let counts = StatusCounts(sessions: sessions)

        HStack(spacing: 0) {
            HStack(alignment: .center, spacing: 7) {
                HairlineBrandMark()
                Text("cctop")
                    .font(.system(size: 13, weight: .semibold))
                    .tracking(-0.1)
                    .foregroundStyle(Color.textPrimary)
                    .frame(height: 16, alignment: .center)
            }
            Spacer()
            HStack(spacing: 5) {
                StatusChip(
                    count: counts.permission,
                    color: Color.statusPermission,
                    textColor: Color.statusPermissionText,
                    categoryLabel: "need permission"
                )
                StatusChip(
                    count: counts.attention,
                    color: Color.statusAttention,
                    textColor: Color.statusAttentionText,
                    categoryLabel: "need attention"
                )
                StatusChip(
                    count: counts.working,
                    color: Color.statusGreen,
                    textColor: Color.statusWorkingText,
                    categoryLabel: "working"
                )
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(height: AppChrome.headerHeight)
    }
}

private struct HairlineBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let colors = colorScheme == .light
            ? [
                Color(red: 0x6F / 255, green: 0xA1 / 255, blue: 0x4C / 255),
                Color(red: 0xCE / 255, green: 0x80 / 255, blue: 0x36 / 255),
                Color(red: 0xC7 / 255, green: 0x54 / 255, blue: 0x54 / 255),
                Color(red: 0xA9 / 255, green: 0xAD / 255, blue: 0xB6 / 255),
            ]
            : [
                Color(red: 0x8C / 255, green: 0xBF / 255, blue: 0x6A / 255),
                Color(red: 0xE0 / 255, green: 0x9B / 255, blue: 0x56 / 255),
                Color(red: 0xDB / 255, green: 0x6E / 255, blue: 0x6E / 255),
                Color(red: 0x4D / 255, green: 0x50 / 255, blue: 0x58 / 255),
            ]

        HStack(spacing: 0) {
            Rectangle().fill(colors[0]).frame(width: 14)
            Rectangle().fill(colors[1]).frame(width: 5)
            Rectangle().fill(colors[2]).frame(width: 3)
            Rectangle().fill(colors[3]).frame(width: 4)
        }
        .frame(width: 26, height: 5)
        .clipShape(Capsule())
        .frame(width: 26, height: 16, alignment: .center)
        .offset(y: 2)
        .accessibilityHidden(true)
    }
}

#Preview("Normal") {
    HeaderView(sessions: Session.qaShowcase).frame(width: 320).padding()
}
