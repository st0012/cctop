import SwiftUI

extension PopupView {
    var noActiveSessionsContent: some View {
        emptyPlaceholder(systemImage: "circle.dotted", title: "No active sessions")
    }

    var noIdleSessionsContent: some View {
        emptyPlaceholder(systemImage: "moon", title: "No idle sessions")
    }

    func emptyPlaceholder(systemImage: String, title: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Color.textMuted)
            Text(title)
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
