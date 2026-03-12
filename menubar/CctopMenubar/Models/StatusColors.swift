import AppKit
import SwiftUI

/// Shared status bar colors used by both the menubar icon renderer and the notch status view.
enum StatusColors {
    static let permission = RGBColor(red: 236 / 255, green: 94 / 255, blue: 94 / 255)   // #ec5e5e
    static let attention = RGBColor(red: 0.91, green: 0.64, blue: 0.29)                 // #e8a44a
    static let working = RGBColor(red: 0.13, green: 0.77, blue: 0.37)
    static let idle = RGBColor(red: 0.60, green: 0.63, blue: 0.67)
    /// Red accent — used to tint icons when sessions need attention.
    static let accent = permission

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
