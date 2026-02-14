import SwiftUI

extension Notification.Name {
    static let settingsToggled = Notification.Name("settingsToggled")
}

struct PopupView: View {
    let sessions: [Session]
    var resetSession: ((Session) -> Void)?
    var updateAvailable: String?
    @State private var showSettings = false
    @State private var gearHovered = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(sessions: sessions)
            Divider()
            if sessions.isEmpty {
                EmptyStateView()
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 4) {
                        ForEach(sortedSessions) { session in
                            SessionCardView(
                                session: session,
                                showSourceBadge: hasMultipleSources,
                                onReset: resetSession
                            )
                            .onTapGesture { focusSession(session) }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 290)
            }
            if showSettings {
                Divider()
                SettingsSection(updateAvailable: updateAvailable)
                    .padding(.vertical, 8)
            }
            Divider()
            HStack {
                QuitButton()
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showSettings.toggle() }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                        NotificationCenter.default.post(name: .settingsToggled, object: nil)
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .foregroundStyle(showSettings ? Color.amber : Color.secondary)
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(gearHovered ? 0.1 : 0))
                        )
                        .overlay(alignment: .topTrailing) {
                            if updateAvailable != nil && !showSettings {
                                Circle()
                                    .fill(Color.amber)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 2, y: -2)
                            }
                        }
                }
                .buttonStyle(.plain)
                .onHover { gearHovered = $0 }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var hasMultipleSources: Bool {
        sessions.contains { $0.source != nil } && sessions.contains { $0.source == nil }
            || Set(sessions.compactMap(\.source)).count > 1
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
#Preview("Mixed sources") {
    PopupView(sessions: Session.qaShowcase).frame(width: 320)
}
#Preview("Empty") {
    PopupView(sessions: []).frame(width: 320)
}
