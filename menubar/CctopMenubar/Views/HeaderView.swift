import SwiftUI

struct HeaderView: View {
    let sessions: [Session]

    static func statusCounts(for sessions: [Session]) -> StatusCounts {
        var permission = 0, attention = 0, working = 0, idle = 0
        for session in sessions {
            switch session.status {
            case .idle: idle += 1
            case .working, .compacting: working += 1
            case .waitingPermission: permission += 1
            case .waitingInput, .needsAttention: attention += 1
            }
        }
        return StatusCounts(
            permission: permission, attention: attention,
            working: working, idle: idle
        )
    }

    private var statusCounts: StatusCounts {
        Self.statusCounts(for: sessions)
    }

    var body: some View {
        let counts = statusCounts

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
