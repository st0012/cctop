import SwiftUI

/// 6×11pt terminal-style caret that hard-blinks at 0.55s intervals.
/// Used at the end of the running command on `working` cards.
/// Hidden when `accessibilityReduceMotion` is set.
///
/// Uses `.task` (not `Timer.scheduledTimer`) so the blink loop is automatically
/// cancelled when the view disappears — no manual lifecycle management.
struct BlinkingCaret: View {
    var color: Color = .statusGreen

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var visible = true

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(color)
                .frame(width: 6, height: 11)
                .opacity(visible ? 0.85 : 0)
                .accessibilityHidden(true)
                .task {
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 550_000_000)
                        visible.toggle()
                    }
                }
        }
    }
}

#Preview {
    HStack(spacing: 4) {
        Text("Reading SessionCardView.swift")
            .font(.system(size: 11, design: .monospaced))
        BlinkingCaret()
    }
    .padding()
}
