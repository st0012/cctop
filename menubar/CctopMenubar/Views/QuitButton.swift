import SwiftUI

struct QuitButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Text("Quit")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(isHovered ? Color.textPrimary : Color.textMuted)
                .contentShape(Rectangle().inset(by: -8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Quit cctop")
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
