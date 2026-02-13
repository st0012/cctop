import AppKit
import SwiftUI

extension Color {
    /// Terracotta accent — the primary brand color. Dark: #D97757, Light: #C0603E
    static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 217 / 255, green: 119 / 255, blue: 87 / 255, alpha: 1)
            : NSColor(red: 192 / 255, green: 96 / 255, blue: 62 / 255, alpha: 1)
    })

    /// Segmented control background. Dark: #1a1410, Light: #e5dbd0
    static let segmentBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 26 / 255, green: 20 / 255, blue: 16 / 255, alpha: 1)
            : NSColor(red: 229 / 255, green: 219 / 255, blue: 208 / 255, alpha: 1)
    })

    /// Segmented control inactive text. Dark: #7a6a58, Light: #8a7d70
    static let segmentText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 122 / 255, green: 106 / 255, blue: 88 / 255, alpha: 1)
            : NSColor(red: 138 / 255, green: 125 / 255, blue: 112 / 255, alpha: 1)
    })

    /// Active segment text. Dark: #1a1410, Light: #ffffff
    static let segmentActiveText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 26 / 255, green: 20 / 255, blue: 16 / 255, alpha: 1)
            : NSColor.white
    })

    /// Settings section background. Dark: #271e17, Light: #EDE3D8
    static let settingsBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 39 / 255, green: 30 / 255, blue: 23 / 255, alpha: 1)
            : NSColor(red: 237 / 255, green: 227 / 255, blue: 216 / 255, alpha: 1)
    })

    /// Settings section border. Dark: #3d3028, Light: #ddd4c8
    static let settingsBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 61 / 255, green: 48 / 255, blue: 40 / 255, alpha: 1)
            : NSColor(red: 221 / 255, green: 212 / 255, blue: 200 / 255, alpha: 1)
    })

    /// Panel background. Dark: #221a14, Light: #F5EDE4
    static let panelBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 34 / 255, green: 26 / 255, blue: 20 / 255, alpha: 1)
            : NSColor(red: 245 / 255, green: 237 / 255, blue: 228 / 255, alpha: 1)
    })

    /// Card background. Dark: #2e231b, Light: #ffffff
    static let cardBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 46 / 255, green: 35 / 255, blue: 27 / 255, alpha: 1)
            : NSColor.white
    })

    /// Card border. Dark: #3d3028, Light: #ddd4c8
    static let cardBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 61 / 255, green: 48 / 255, blue: 40 / 255, alpha: 1)
            : NSColor(red: 221 / 255, green: 212 / 255, blue: 200 / 255, alpha: 1)
    })

    /// Working status green. Dark: #4ade80, Light: #2da55e
    static let statusGreen = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 74 / 255, green: 222 / 255, blue: 128 / 255, alpha: 1)
            : NSColor(red: 45 / 255, green: 165 / 255, blue: 94 / 255, alpha: 1)
    })

    /// Secondary text — context lines, labels. Dark: #C4A882, Light: #4d4038
    static let textSecondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 196 / 255, green: 168 / 255, blue: 130 / 255, alpha: 1)
            : NSColor(red: 77 / 255, green: 64 / 255, blue: 56 / 255, alpha: 1)
    })

    /// Muted text — timestamps, versions, branch names. Dark: #7a6a58, Light: #8a7d70
    static let textMuted = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 122 / 255, green: 106 / 255, blue: 88 / 255, alpha: 1)
            : NSColor(red: 138 / 255, green: 125 / 255, blue: 112 / 255, alpha: 1)
    })
}
