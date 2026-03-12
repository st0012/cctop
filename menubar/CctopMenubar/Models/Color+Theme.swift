import AppKit
import SwiftUI

extension Color {
    /// Red accent — the primary brand color. Dark: #ff6b6b, Light: #d03830
    static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 255 / 255, green: 107 / 255, blue: 107 / 255, alpha: 1)
            : NSColor(red: 208 / 255, green: 56 / 255, blue: 48 / 255, alpha: 1)
    })

    /// Segmented control background. Dark: white 0.06, Light: black 0.04
    static let segmentBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 0, alpha: 0.04)
    })

    /// Segmented control inactive text. Dark: #777, Light: #777
    static let segmentText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0x77 / 255.0, alpha: 1)
            : NSColor(white: 0x77 / 255.0, alpha: 1)
    })

    /// Active segment text. Dark: #f0f0f0, Light: #1a1a1a
    static let segmentActiveText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0xf0 / 255.0, alpha: 1)
            : NSColor(white: 0x1a / 255.0, alpha: 1)
    })

    /// Settings section background (unused in current design, kept for compat)
    static let settingsBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.04)
            : NSColor(white: 0, alpha: 0.02)
    })

    /// Settings section border (unused in current design, kept for compat)
    static let settingsBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.04)
            : NSColor(white: 0, alpha: 0.04)
    })

    /// Panel background. Dark: #1e1e1e, Light: #ffffff
    static let panelBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0x1e / 255.0, alpha: 1)
            : NSColor.white
    })

    /// Card background. Dark: white 0.04, Light: black 0.02
    static let cardBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.04)
            : NSColor(white: 0, alpha: 0.02)
    })

    /// Card border. Dark: white 0.04, Light: black 0.04
    static let cardBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.04)
            : NSColor(white: 0, alpha: 0.04)
    })

    /// Working status green. Dark: #4ade80, Light: #34c759
    static let statusGreen = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 74 / 255, green: 222 / 255, blue: 128 / 255, alpha: 1)
            : NSColor(red: 52 / 255, green: 199 / 255, blue: 89 / 255, alpha: 1)
    })

    /// Secondary text — branch, meta, working status. Dark: #9e9e9e, Light: #666666
    static let textSecondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0x9e / 255.0, alpha: 1)
            : NSColor(white: 0x66 / 255.0, alpha: 1)
    })

    /// Muted text — timestamps, idle status, footer. Dark: #666666, Light: #999999
    static let textMuted = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0x66 / 255.0, alpha: 1)
            : NSColor(white: 0x99 / 255.0, alpha: 1)
    })

    /// Dimmed primary — idle project names. Dark: #888888, Light: #888888
    static let textDimmed = Color(nsColor: NSColor(white: 0x88 / 255.0, alpha: 1))

    /// Primary text. Dark: #f0f0f0, Light: #1a1a1a
    static let textPrimary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 0xf0 / 255.0, alpha: 1)
            : NSColor(white: 0x1a / 255.0, alpha: 1)
    })
}
