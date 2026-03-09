import AppKit
import SwiftUI

/// Aggregated session status counts used by the menubar icon, notch pill, and accessibility labels.
struct StatusCounts {
    let permission: Int
    let attention: Int
    let working: Int
    let idle: Int

    var total: Int { permission + attention + working + idle }
    var needsAction: Int { permission + attention }

    /// Human-readable summary for VoiceOver / accessibility labels.
    var accessibilityLabel: String {
        guard total > 0 else { return "cctop, no sessions" }
        var parts: [String] = []
        if permission > 0 { parts.append("\(permission) need permission") }
        if attention > 0 { parts.append("\(attention) need attention") }
        if working > 0 { parts.append("\(working) working") }
        if idle > 0 { parts.append("\(idle) idle") }
        return "cctop, " + parts.joined(separator: ", ")
    }
}

/// Shared status bar colors used by both the menubar icon renderer and the notch status view.
enum StatusColors {
    static let permission = RGBColor(red: 0.94, green: 0.27, blue: 0.27)
    static let attention = RGBColor(red: 0.96, green: 0.62, blue: 0.04)
    static let working = RGBColor(red: 0.13, green: 0.77, blue: 0.37)
    static let idle = RGBColor(red: 0.42, green: 0.45, blue: 0.50)
    /// Brand terracotta — used to tint icons when sessions need attention.
    static let accent = RGBColor(red: 217 / 255, green: 119 / 255, blue: 87 / 255)

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
