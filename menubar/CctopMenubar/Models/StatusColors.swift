import AppKit
import SwiftUI

/// Shared status bar colors used by both the menubar icon renderer and the notch status view.
enum StatusColors {
    static let permission = RGBColor(red: 0.94, green: 0.27, blue: 0.27)
    static let attention = RGBColor(red: 0.96, green: 0.62, blue: 0.04)
    static let working = RGBColor(red: 0.13, green: 0.77, blue: 0.37)
    static let idle = RGBColor(red: 0.42, green: 0.45, blue: 0.50)

    struct RGBColor {
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
