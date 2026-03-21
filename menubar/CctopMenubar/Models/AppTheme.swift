import AppKit

enum AppTheme: String, CaseIterable, Identifiable, Hashable {
    case claude, tokyoNight, gruvbox, nord

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .tokyoNight: return "Tokyo Night"
        case .gruvbox: return "Gruvbox"
        case .nord: return "Nord"
        }
    }

    struct ColorPair {
        let dark: NSColor
        let light: NSColor
        func resolve(_ appearance: NSAppearance) -> NSColor {
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    var accent: ColorPair { Self.accents[self]! }
    var statusGreen: ColorPair { Self.greens[self]! }
    var textPrimary: ColorPair { Self.primaries[self]! }
    var textSecondary: ColorPair { Self.secondaries[self]! }
    var textMuted: ColorPair { Self.muteds[self]! }
    var textDimmed: ColorPair { Self.dimmeds[self]! }
    var panelBackground: ColorPair { Self.panels[self]! }
    var statusIdle: ColorPair { Self.idles[self]! }
    var agentBadge: ColorPair { Self.badges[self]! }

    var segmentText: ColorPair { textMuted }
    var segmentActiveText: ColorPair { textPrimary }
    var statusPermission: ColorPair { Self.permissions[self]! }
    var statusAttention: ColorPair { Self.attentions[self]! }
    var statusWorking: ColorPair { statusGreen }

    // Shared across all themes
    var cardBackground: ColorPair { Self.sharedCard }
    var cardBorder: ColorPair { Self.sharedBorder }
    var segmentBackground: ColorPair { Self.sharedSegBg }
    var settingsBackground: ColorPair { Self.sharedCard }
    var settingsBorder: ColorPair { Self.sharedBorder }
}

// MARK: - Color tables

private extension AppTheme {
    static let sharedCard = ColorPair(
        dark: NSColor(white: 1, alpha: 0.04), light: NSColor(white: 0, alpha: 0.02)
    )
    static let sharedBorder = ColorPair(
        dark: NSColor(white: 1, alpha: 0.04), light: NSColor(white: 0, alpha: 0.04)
    )
    static let sharedSegBg = ColorPair(
        dark: NSColor(white: 1, alpha: 0.06), light: NSColor(white: 0, alpha: 0.04)
    )

    static func hex(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(red: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: 1)
    }

    static let accents: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xDA, 0x77, 0x56), light: hex(0xC9, 0x64, 0x42)),
        .tokyoNight: ColorPair(dark: hex(0xF7, 0x76, 0x8E), light: hex(0x29, 0x59, 0xAA)),
        .gruvbox: ColorPair(dark: hex(0xFE, 0x80, 0x19), light: hex(0xAF, 0x3A, 0x03)),
        .nord: ColorPair(dark: hex(0xBF, 0x61, 0x6A), light: hex(0xA0, 0x35, 0x40)),
    ]

    static let permissions: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xDA, 0x77, 0x56), light: hex(0xC9, 0x64, 0x42)),
        .tokyoNight: ColorPair(dark: hex(0xF7, 0x76, 0x8E), light: hex(0x94, 0x35, 0x45)),
        .gruvbox: ColorPair(dark: hex(0xFB, 0x49, 0x34), light: hex(0x9D, 0x00, 0x06)),
        .nord: ColorPair(dark: hex(0xBF, 0x61, 0x6A), light: hex(0xA0, 0x35, 0x40)),
    ]

    static let attentions: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xD4, 0xA0, 0x50), light: hex(0xC9, 0x64, 0x42)),
        .tokyoNight: ColorPair(dark: hex(0x7A, 0xA2, 0xF7), light: hex(0x29, 0x59, 0xAA)),
        .gruvbox: ColorPair(dark: hex(0xFE, 0x80, 0x19), light: hex(0xAF, 0x3A, 0x03)),
        .nord: ColorPair(dark: hex(0xD0, 0x87, 0x70), light: hex(0xA0, 0x35, 0x40)),
    ]

    static let greens: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x7E, 0xAA, 0x6E), light: hex(0x4A, 0x82, 0x38)),
        .tokyoNight: ColorPair(dark: hex(0x9E, 0xCE, 0x6A), light: hex(0x33, 0x63, 0x5C)),
        .gruvbox: ColorPair(dark: hex(0xB8, 0xBB, 0x26), light: hex(0x42, 0x7B, 0x58)),
        .nord: ColorPair(dark: hex(0xA3, 0xBE, 0x8C), light: hex(0x4E, 0x7A, 0x35)),
    ]

    static let primaries: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xF5, 0xF0, 0xEB), light: hex(0x1F, 0x1E, 0x1D)),
        .tokyoNight: ColorPair(dark: hex(0xC0, 0xCA, 0xF5), light: hex(0x34, 0x3B, 0x59)),
        .gruvbox: ColorPair(dark: hex(0xEB, 0xDB, 0xB2), light: hex(0x3C, 0x38, 0x36)),
        .nord: ColorPair(dark: hex(0xEC, 0xEF, 0xF4), light: hex(0x2E, 0x34, 0x40)),
    ]

    static let secondaries: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xA0, 0x9A, 0x94), light: hex(0x6B, 0x5A, 0x48)),
        .tokyoNight: ColorPair(dark: hex(0x79, 0x82, 0xA9), light: hex(0x50, 0x55, 0x70)),
        .gruvbox: ColorPair(dark: hex(0xA8, 0x99, 0x84), light: hex(0x50, 0x49, 0x45)),
        .nord: ColorPair(dark: hex(0x8A, 0x91, 0x9E), light: hex(0x3B, 0x42, 0x52)),
    ]

    static let muteds: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x6B, 0x65, 0x60), light: hex(0x8A, 0x7D, 0x70)),
        .tokyoNight: ColorPair(dark: hex(0x56, 0x5F, 0x89), light: hex(0x7A, 0x7E, 0x90)),
        .gruvbox: ColorPair(dark: hex(0x7C, 0x6F, 0x64), light: hex(0x7C, 0x6F, 0x64)),
        .nord: ColorPair(dark: hex(0x61, 0x6E, 0x88), light: hex(0x4C, 0x56, 0x6A)),
    ]

    static let dimmeds: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x8A, 0x84, 0x80), light: hex(0x7E, 0x75, 0x70)),
        .tokyoNight: ColorPair(dark: hex(0x56, 0x5F, 0x89), light: hex(0x7C, 0x80, 0x92)),
        .gruvbox: ColorPair(dark: hex(0x7C, 0x6F, 0x64), light: hex(0x92, 0x83, 0x74)),
        .nord: ColorPair(dark: hex(0x61, 0x6E, 0x88), light: hex(0x6B, 0x7A, 0x92)),
    ]

    static let panels: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x1C, 0x19, 0x17), light: hex(0xFA, 0xF9, 0xF5)),
        .tokyoNight: ColorPair(dark: hex(0x1A, 0x1B, 0x26), light: hex(0xE6, 0xE7, 0xED)),
        .gruvbox: ColorPair(dark: hex(0x28, 0x28, 0x28), light: hex(0xFB, 0xF1, 0xC7)),
        .nord: ColorPair(dark: hex(0x2E, 0x34, 0x40), light: hex(0xEC, 0xEF, 0xF4)),
    ]

    static let idles: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x80, 0x80, 0x80), light: hex(0x8A, 0x7D, 0x70)),
        .tokyoNight: ColorPair(dark: hex(0x56, 0x5F, 0x89), light: hex(0x7E, 0x82, 0x92)),
        .gruvbox: ColorPair(dark: hex(0x66, 0x5C, 0x54), light: hex(0x92, 0x83, 0x74)),
        .nord: ColorPair(dark: hex(0x4C, 0x56, 0x6A), light: hex(0x75, 0x88, 0xA0)),
    ]

    static let badges: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x72, 0x16, 0xAB), light: hex(0x7A, 0x35, 0x80)),
        .tokyoNight: ColorPair(dark: hex(0xBB, 0x9A, 0xF7), light: hex(0x7B, 0x43, 0xBA)),
        .gruvbox: ColorPair(dark: hex(0xD3, 0x86, 0x9B), light: hex(0x8F, 0x3F, 0x71)),
        .nord: ColorPair(dark: hex(0xB4, 0x8E, 0xAD), light: hex(0x8B, 0x50, 0x78)),
    ]
}
