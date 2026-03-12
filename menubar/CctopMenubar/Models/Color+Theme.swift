import AppKit
import SwiftUI

extension Color {
    /// Red accent — the primary brand color. Dark: #ec5e5e, Light: #d04040
    static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 236 / 255, green: 94 / 255, blue: 94 / 255, alpha: 1)
            : NSColor(red: 208 / 255, green: 64 / 255, blue: 64 / 255, alpha: 1)
    })

    /// Segmented control background. Dark: white 0.06, Light: black 0.04
    static let segmentBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.06)
            : NSColor(white: 0, alpha: 0.04)
    })

    /// Segmented control inactive text. Dark: white 0.25, Light: black 0.3
    static let segmentText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.25)
            : NSColor(white: 0, alpha: 0.3)
    })

    /// Active segment text. Dark: white 0.8, Light: black 0.7
    static let segmentActiveText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.8)
            : NSColor(white: 0, alpha: 0.7)
    })

    /// Settings section background — matches cardBackground (to be removed in Task 5)
    static let settingsBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.04)
            : NSColor(white: 0, alpha: 0.02)
    })

    /// Settings section border — matches cardBorder (to be removed in Task 5)
    static let settingsBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.04)
            : NSColor(white: 0, alpha: 0.04)
    })

    /// Panel background. Dark: #111111, Light: #ffffff
    static let panelBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 17 / 255, green: 17 / 255, blue: 17 / 255, alpha: 1)
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

    /// Secondary text — context lines, labels. Dark: white 0.22, Light: black 0.25
    static let textSecondary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.22)
            : NSColor(white: 0, alpha: 0.25)
    })

    /// Muted text — timestamps, versions, branch names. Dark: white 0.15, Light: black 0.2
    static let textMuted = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.15)
            : NSColor(white: 0, alpha: 0.2)
    })
}
