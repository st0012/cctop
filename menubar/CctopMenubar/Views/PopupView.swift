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
                        ForEach(sessions.sorted {
                            ($0.status.sortOrder, $1.lastActivity) < ($1.status.sortOrder, $0.lastActivity)
                        }) { session in
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
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Spacer()
            }
        }
    }

    private func focusSession(_ session: Session) {
        focusTerminal(session: session)
        NSApp.deactivate()
    }
}
