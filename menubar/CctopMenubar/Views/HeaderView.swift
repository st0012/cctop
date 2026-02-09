import SwiftUI

struct HeaderView: View {
    let sessions: [Session]

    private var statusCounts: (attention: Int, working: Int, idle: Int) {
        var attention = 0, working = 0, idle = 0
        for session in sessions {
            switch session.status {
            case .idle: idle += 1
            case .working, .compacting: working += 1
            case .waitingPermission, .waitingInput, .needsAttention: attention += 1
            }
        }
        return (attention, working, idle)
    }

    var body: some View {
        let counts = statusCounts
        HStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(.orange)
                .frame(width: 20, height: 20)
                .overlay(Text("C").font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            Text("cctop").font(.system(size: 14, weight: .semibold))
            Spacer()
            StatusChip(count: counts.attention, color: .orange)
            StatusChip(count: counts.working, color: .green)
            StatusChip(count: counts.idle, color: .gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
