import SwiftUI

@main
struct CctopApp: App {
    @StateObject private var sessionManager = SessionManager()

    var body: some Scene {
        MenuBarExtra {
            PopupView(sessions: sessionManager.sessions)
                .frame(width: 320)
        } label: {
            let count = sessionManager.sessions.filter { $0.status.needsAttention }.count
            if count > 0 {
                Text("CC (\(count))")
            } else {
                Text("CC")
            }
        }
        .menuBarExtraStyle(.window)
    }
}
