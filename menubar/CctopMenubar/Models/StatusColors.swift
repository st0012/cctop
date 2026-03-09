import AppKit
import SwiftUI

/// Shared status bar colors used by both the menubar icon renderer and the notch status view.
enum StatusColors {
    static let permission = RGBColor(red: 0.94, green: 0.27, blue: 0.27)
    static let attention = RGBColor(red: 217 / 255, green: 119 / 255, blue: 87 / 255)
    static let working = RGBColor(red: 0.13, green: 0.77, blue: 0.37)
    static let idle = RGBColor(red: 0.60, green: 0.63, blue: 0.67)
    /// Brand terracotta — used to tint icons when sessions need attention.
    static let accent = attention

    struct RGBColor: Hashable {
        let red: Double
        let green: Double
        let blue: Double

        var nsColor: NSColor {
            NSColor(red: red, green: green, blue: blue, alpha: 1)
        }

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }
    }
}
