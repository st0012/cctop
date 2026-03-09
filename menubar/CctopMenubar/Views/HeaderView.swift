import SwiftUI

struct HeaderView: View {
    let sessions: [Session]

    var body: some View {
        let counts = StatusCounts(sessions: sessions)

        HStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.amber)
                .frame(width: 20, height: 20)
                .overlay(Text("C").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            Text("cctop").font(.system(size: 14, weight: .semibold))
            Spacer()
            StatusChip(count: counts.permission, color: .red, categoryLabel: "need permission")
            StatusChip(count: counts.attention, color: Color.amber, categoryLabel: "need attention")
            StatusChip(count: counts.working, color: Color.statusGreen, categoryLabel: "working")
            StatusChip(count: counts.idle, color: .gray, categoryLabel: "idle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

#Preview("Normal") {
    HeaderView(sessions: Session.qaShowcase).frame(width: 320).padding()
}
