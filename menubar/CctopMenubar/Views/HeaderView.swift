import SwiftUI

struct HeaderView: View {
    let sessions: [Session]
    var onTap: (() -> Void)?
    var isCompactMode = false

    static func statusCounts(
        for sessions: [Session]
    ) -> (permission: Int, attention: Int, working: Int, idle: Int) {
        var permission = 0, attention = 0, working = 0, idle = 0
        for session in sessions {
            switch session.status {
            case .idle: idle += 1
            case .working, .compacting: working += 1
            case .waitingPermission: permission += 1
            case .waitingInput, .needsAttention: attention += 1
            }
        }
        return (permission, attention, working, idle)
    }

    private var statusCounts: (permission: Int, attention: Int, working: Int, idle: Int) {
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
                .overlay(alignment: .bottom) {
                    if isCompactMode {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.amber)
                            .frame(height: 2)
                            .offset(y: 3)
                    }
                }
            Spacer()
            StatusChip(count: counts.permission, color: .red, categoryLabel: "need permission")
            StatusChip(count: counts.attention, color: Color.amber, categoryLabel: "need attention")
            StatusChip(count: counts.working, color: Color.statusGreen, categoryLabel: "working")
            StatusChip(count: counts.idle, color: .gray, categoryLabel: "idle")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }
}

#Preview("Normal") {
    HeaderView(sessions: Session.qaShowcase).frame(width: 320).padding()
}
#Preview("Compact Mode") {
    HeaderView(sessions: Session.qaShowcase, isCompactMode: true).frame(width: 320).padding()
}
#Preview("Compact Tappable") {
    HeaderView(sessions: Session.qaShowcase, onTap: {}, isCompactMode: true).frame(width: 320).padding()
}
