import SwiftUI

struct StatusChip: View {
    let count: Int
    let color: Color
    var categoryLabel: String = ""

    var body: some View {
        if count > 0 {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 5, height: 5)
                Text("\(count)").font(.system(size: 10)).foregroundStyle(color)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(count) \(categoryLabel)")
        }
    }
}
