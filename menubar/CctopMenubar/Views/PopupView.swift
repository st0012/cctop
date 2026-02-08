import SwiftUI

struct PopupView: View {
    let sessions: [Session]

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(sessions: sessions)
            Divider()
            if sessions.isEmpty {
                Text("No active sessions")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(sortedSessions) { session in
                            SessionCardView(session: session)
                                .onTapGesture { focusSession(session) }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 520)
            }
            Divider()
            HStack {
                QuitButton()
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var sortedSessions: [Session] {
        sessions.sorted {
            ($0.status.sortOrder, $1.lastActivity) < ($1.status.sortOrder, $0.lastActivity)
        }
    }

    private func focusSession(_ session: Session) {
        focusTerminal(session: session)
        NSApp.deactivate()
    }
}

#Preview("With sessions") {
    PopupView(sessions: Session.mockSessions).frame(width: 320)
}
#Preview("Empty") {
    PopupView(sessions: []).frame(width: 320)
}
