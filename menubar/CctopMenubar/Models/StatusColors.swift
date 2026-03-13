import AppKit
import SwiftUI

/// Shared status bar colors used by both the menubar icon renderer and the notch status view.
/// Colors are derived from the current theme (dark variant, for visibility on any menu bar).
@MainActor
enum StatusColors {
    static var permission: RGBColor {
        RGBColor(nsColor: ThemeManager.shared.current.statusPermission.dark)
    }
    static var attention: RGBColor {
        RGBColor(nsColor: ThemeManager.shared.current.statusAttention.dark)
    }
    static var working: RGBColor {
        RGBColor(nsColor: ThemeManager.shared.current.statusWorking.dark)
    }
    static var idle: RGBColor {
        RGBColor(nsColor: ThemeManager.shared.current.statusIdle.dark)
    }
    /// Accent — used to tint icons when sessions need attention.
    static var accent: RGBColor { permission }

    struct RGBColor: Hashable {
        let red: Double
        let green: Double
        let blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init(nsColor color: NSColor) {
            let srgb = color.usingColorSpace(.sRGB) ?? color
            self.red = srgb.redComponent
            self.green = srgb.greenComponent
            self.blue = srgb.blueComponent
        }

        var nsColor: NSColor {
            NSColor(red: red, green: green, blue: blue, alpha: 1)
        }

        var color: Color {
            Color(red: red, green: green, blue: blue)
        }
    }
}
