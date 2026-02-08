import SwiftUI

struct QuitButton: View {
    @State private var isHovered = false

    var body: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Text("Quit")
                .font(.system(size: 11))
                .foregroundStyle(isHovered ? .primary : .tertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(isHovered ? Color.primary.opacity(0.08) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
    }
}
