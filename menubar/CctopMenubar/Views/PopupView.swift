import SwiftUI

extension Notification.Name {
    static let settingsToggled = Notification.Name("settingsToggled")
}

struct PopupView: View {
    let sessions: [Session]
    @State private var showSettings = false
    @State private var gearHovered = false

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
            SettingsSection()
                .padding(.bottom, showSettings ? 8 : 0)
                .frame(maxHeight: showSettings ? nil : 0, alignment: .top)
                .clipped()
                .opacity(showSettings ? 1 : 0)
            Divider()
            HStack {
                QuitButton()
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NotificationCenter.default.post(name: .settingsToggled, object: nil)
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(showSettings ? Color.orange : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(gearHovered ? 0.1 : 0))
                        )
                }
                .buttonStyle(.plain)
                .onHover { gearHovered = $0 }
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
