import AppKit
import SwiftUI

extension Color {
    /// Warm amber accent — the primary brand color.
    /// Dark: #e8952e, Light: #b56c0a
    static let amber = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 232 / 255, green: 149 / 255, blue: 46 / 255, alpha: 1)
            : NSColor(red: 181 / 255, green: 108 / 255, blue: 10 / 255, alpha: 1)
    })

    /// Segmented control background.
    /// Dark: #161310, Light: #e8e2d8
    static let segmentBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 22 / 255, green: 19 / 255, blue: 16 / 255, alpha: 1)
            : NSColor(red: 232 / 255, green: 226 / 255, blue: 216 / 255, alpha: 1)
    })

    /// Segmented control inactive text.
    /// Dark: #6e6358, Light: #6e6358
    static let segmentText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 110 / 255, green: 99 / 255, blue: 88 / 255, alpha: 1)
            : NSColor(red: 110 / 255, green: 99 / 255, blue: 88 / 255, alpha: 1)
    })

    /// Active segment / logo text — contrasts with amber background.
    /// Both modes: #ffffff
    static let segmentActiveText = Color.white

    /// Settings section background.
    /// Dark: #1f1b17, Light: #f0ece5
    static let settingsBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 31 / 255, green: 27 / 255, blue: 23 / 255, alpha: 1)
            : NSColor(red: 240 / 255, green: 236 / 255, blue: 229 / 255, alpha: 1)
    })

    /// Settings section border.
    /// Dark: #383026, Light: #ddd7cc
    static let settingsBorder = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 56 / 255, green: 48 / 255, blue: 38 / 255, alpha: 1)
            : NSColor(red: 221 / 255, green: 215 / 255, blue: 204 / 255, alpha: 1)
    })
}
