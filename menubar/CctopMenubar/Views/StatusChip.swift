import SwiftUI

struct StatusChip: View {
    let count: Int
    let color: Color
    let textColor: Color
    var categoryLabel: String = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(textColor)
            }
            .padding(.leading, 6)
            .padding(.trailing, 7)
            .padding(.vertical, 2.5)
            .background(color.opacity(colorScheme == .dark ? 0.13 : 0.10))
            .clipShape(Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) \(categoryLabel)")
        }
    }
}
