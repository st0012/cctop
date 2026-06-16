import SwiftUI

struct HeaderView: View {
    let sessions: [Session]

    var body: some View {
        let counts = StatusCounts(sessions: sessions)

        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(headerBarColor(counts: counts))
                .frame(width: 3, height: 14)
            Text("cctop")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            StatusChip(count: counts.permission, color: Color.statusPermission, categoryLabel: "need permission")
            StatusChip(count: counts.attention, color: Color.statusAttention, categoryLabel: "need attention")
            StatusChip(count: counts.working, color: Color.statusGreen, categoryLabel: "working")
            StatusChip(count: counts.idle, color: Color.statusIdle, categoryLabel: "idle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
    private func headerBarColor(counts: StatusCounts) -> Color {
        if counts.permission > 0 {
            return Color.statusPermission
        }
        if counts.attention > 0 {
            return Color.statusAttention
        }
        if counts.working > 0 {
            return Color.statusGreen.opacity(0.5)
        }
        return Color.textMuted
    }
}

#Preview("Normal") {
    HeaderView(sessions: Session.qaShowcase).frame(width: 320).padding()
}
