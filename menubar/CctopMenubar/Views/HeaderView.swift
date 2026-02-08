import SwiftUI

struct HeaderView: View {
    let sessions: [Session]

    var body: some View {
        HStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.orange)
                .frame(width: 20, height: 20)
                .overlay(Text("C").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            Text("cctop").font(.system(size: 14, weight: .semibold))
            Spacer()
            StatusChip(count: sessions.filter { $0.status.needsAttention }.count, color: .orange)
            StatusChip(count: sessions.filter { $0.status == .working }.count, color: .green)
            StatusChip(count: sessions.filter { $0.status == .idle }.count, color: .gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
