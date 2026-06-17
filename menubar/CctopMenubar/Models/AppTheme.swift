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
    var opencodeBadge: ColorPair { Self.opencodeBadges[self]! }
    var piBadge: ColorPair { Self.piBadges[self]! }
    var codexBadge: ColorPair { Self.codexBadges[self]! }
    var claudeDesktopBadge: ColorPair { Self.claudeDesktopBadges[self]! }
    var codexDesktopBadge: ColorPair { Self.codexDesktopBadges[self]! }

    var segmentText: ColorPair { textMuted }
    var segmentActiveText: ColorPair { textPrimary }
    var accentButtonText: ColorPair { Self.accentButtonTexts[self]! }
    var statusPermission: ColorPair { Self.permissions[self]! }
    var statusAttention: ColorPair { Self.attentions[self]! }
    var statusWorking: ColorPair { statusGreen }

    // Shared across all themes
    var cardBackground: ColorPair { Self.sharedCard }
    var cardBorder: ColorPair { Self.sharedBorder }
    var segmentBackground: ColorPair { Self.sharedSegBg }
    var settingsBackground: ColorPair { Self.sharedCard }
    var settingsBorder: ColorPair { Self.sharedBorder }
    var panelMaterialOverlay: ColorPair { Self.sharedPanelMaterialOverlay }
    var panelControlBackground: ColorPair { Self.sharedPanelControlBackground }
    var panelControlBorder: ColorPair { Self.sharedPanelControlBorder }
    var panelAccentBorder: ColorPair { Self.accentBorders[self]! }
    var panelSelectionBackground: ColorPair { Self.selectionBackgrounds[self]! }
    var groupedContentBackground: ColorPair { Self.sharedGroupedContentBackground }
    var groupedRowBackground: ColorPair { Self.sharedGroupedRowBackground }
    var groupedRowBorder: ColorPair { Self.sharedGroupedRowBorder }
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
    static let sharedPanelMaterialOverlay = ColorPair(
        dark: NSColor(white: 1, alpha: 0.04), light: NSColor(white: 1, alpha: 0.18)
    )
    static let sharedPanelControlBackground = ColorPair(
        dark: NSColor(white: 1, alpha: 0.035), light: NSColor(white: 0, alpha: 0.026)
    )
    static let sharedPanelControlBorder = ColorPair(
        dark: NSColor(white: 1, alpha: 0.09), light: NSColor(white: 0, alpha: 0.085)
    )
    static let sharedGroupedContentBackground = ColorPair(
        dark: NSColor(white: 0, alpha: 0.08), light: NSColor(white: 0, alpha: 0.026)
    )
    static let sharedGroupedRowBackground = ColorPair(
        dark: NSColor(white: 1, alpha: 0.035), light: NSColor(white: 1, alpha: 0.34)
    )
    static let sharedGroupedRowBorder = ColorPair(
        dark: NSColor(white: 1, alpha: 0.085), light: NSColor(white: 0, alpha: 0.085)
    )

    static func hex(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, alpha: CGFloat = 1) -> NSColor {
        NSColor(red: red / 255.0, green: green / 255.0, blue: blue / 255.0, alpha: alpha)
    }

    // Brand accent — source badges, header bar
    static let accents: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xC1, 0x5F, 0x3C), light: hex(0xC1, 0x5F, 0x3C)),
        .tokyoNight: ColorPair(dark: hex(0xF7, 0x76, 0x8E), light: hex(0x29, 0x59, 0xAA)),
        .gruvbox: ColorPair(dark: hex(0xFE, 0x80, 0x19), light: hex(0xAF, 0x3A, 0x03)),
        .nord: ColorPair(dark: hex(0xBF, 0x61, 0x6A), light: hex(0xBF, 0x61, 0x6A)),
    ]

    static let accentButtonTexts: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x00, 0x00, 0x00), light: hex(0x00, 0x00, 0x00)),
        .tokyoNight: ColorPair(dark: hex(0x1A, 0x1B, 0x26), light: hex(0xFF, 0xFF, 0xFF)),
        .gruvbox: ColorPair(dark: hex(0x28, 0x28, 0x28), light: hex(0xFB, 0xF1, 0xC7)),
        .nord: ColorPair(dark: hex(0x11, 0x11, 0x11), light: hex(0x11, 0x11, 0x11)),
    ]

    // Permission = error/red — urgent, needs approval
    static let permissions: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xDD, 0x53, 0x53), light: hex(0xDD, 0x53, 0x53)),
        .tokyoNight: ColorPair(dark: hex(0xF7, 0x76, 0x8E), light: hex(0x8C, 0x43, 0x51)),
        .gruvbox: ColorPair(dark: hex(0xFB, 0x49, 0x34), light: hex(0x9D, 0x00, 0x06)),
        .nord: ColorPair(dark: hex(0xBF, 0x61, 0x6A), light: hex(0xBF, 0x61, 0x6A)),
    ]

    // Attention = warning/orange — waiting for input
    static let attentions: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xC1, 0x5F, 0x3C), light: hex(0xC1, 0x5F, 0x3C)),
        .tokyoNight: ColorPair(dark: hex(0xFF, 0x9E, 0x64), light: hex(0x96, 0x50, 0x27)),
        .gruvbox: ColorPair(dark: hex(0xFA, 0xBD, 0x2F), light: hex(0xB5, 0x76, 0x14)),
        .nord: ColorPair(dark: hex(0xD0, 0x87, 0x70), light: hex(0xD0, 0x87, 0x70)),
    ]

    // Working status green
    static let greens: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x7E, 0xAA, 0x6E), light: hex(0x4A, 0x82, 0x38)),
        .tokyoNight: ColorPair(dark: hex(0x9E, 0xCE, 0x6A), light: hex(0x33, 0x63, 0x5C)),
        .gruvbox: ColorPair(dark: hex(0xB8, 0xBB, 0x26), light: hex(0x42, 0x7B, 0x58)),
        .nord: ColorPair(dark: hex(0xA3, 0xBE, 0x8C), light: hex(0x4E, 0x7A, 0x35)),
    ]

    static let primaries: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xF4, 0xF3, 0xEE), light: hex(0x14, 0x14, 0x13)),
        .tokyoNight: ColorPair(dark: hex(0xC0, 0xCA, 0xF5), light: hex(0x34, 0x3B, 0x59)),
        .gruvbox: ColorPair(dark: hex(0xEB, 0xDB, 0xB2), light: hex(0x3C, 0x38, 0x36)),
        .nord: ColorPair(dark: hex(0xEC, 0xEF, 0xF4), light: hex(0x2E, 0x34, 0x40)),
    ]

    static let secondaries: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xB1, 0xAD, 0xA1), light: hex(0x30, 0x30, 0x2E)),
        .tokyoNight: ColorPair(dark: hex(0x8E, 0x94, 0xAD), light: hex(0x36, 0x3C, 0x4D)),
        .gruvbox: ColorPair(dark: hex(0xA8, 0x99, 0x84), light: hex(0x50, 0x49, 0x45)),
        .nord: ColorPair(dark: hex(0xD8, 0xDE, 0xE9), light: hex(0x3B, 0x42, 0x52)),
    ]

    static let muteds: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x93, 0x8F, 0x84), light: hex(0x68, 0x64, 0x5D)),
        .tokyoNight: ColorPair(dark: hex(0x70, 0x78, 0x95), light: hex(0x70, 0x72, 0x80)),
        .gruvbox: ColorPair(dark: hex(0x92, 0x83, 0x74), light: hex(0x7C, 0x6F, 0x64)),
        .nord: ColorPair(dark: hex(0x83, 0x90, 0xA8), light: hex(0x4C, 0x56, 0x6A)),
    ]

    static let dimmeds: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x93, 0x8F, 0x84), light: hex(0x68, 0x64, 0x5D)),
        .tokyoNight: ColorPair(dark: hex(0x69, 0x71, 0x8E), light: hex(0x83, 0x87, 0x92)),
        .gruvbox: ColorPair(dark: hex(0x88, 0x7A, 0x6E), light: hex(0x92, 0x83, 0x74)),
        .nord: ColorPair(dark: hex(0x7F, 0x8A, 0xA2), light: hex(0x4C, 0x56, 0x6A)),
    ]

    static let panels: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x26, 0x26, 0x24), light: hex(0xF4, 0xF3, 0xEE)),
        .tokyoNight: ColorPair(dark: hex(0x1A, 0x1B, 0x26), light: hex(0xE6, 0xE7, 0xED)),
        .gruvbox: ColorPair(dark: hex(0x28, 0x28, 0x28), light: hex(0xFB, 0xF1, 0xC7)),
        .nord: ColorPair(dark: hex(0x2E, 0x34, 0x40), light: hex(0xEC, 0xEF, 0xF4)),
    ]

    static let selectionBackgrounds: [AppTheme: ColorPair] = [
        .claude: ColorPair(
            dark: hex(0x33, 0x32, 0x30), light: hex(0xEC, 0xEA, 0xE3)
        ),
        .tokyoNight: ColorPair(
            dark: hex(0x33, 0x32, 0x30), light: hex(0xEC, 0xEA, 0xE3)
        ),
        .gruvbox: ColorPair(
            dark: hex(0x33, 0x32, 0x30), light: hex(0xEC, 0xEA, 0xE3)
        ),
        .nord: ColorPair(
            dark: hex(0x33, 0x32, 0x30), light: hex(0xEC, 0xEA, 0xE3)
        ),
    ]

    static let accentBorders: [AppTheme: ColorPair] = [
        .claude: ColorPair(
            dark: hex(0x4B, 0x48, 0x43), light: hex(0xD0, 0xCC, 0xC1)
        ),
        .tokyoNight: ColorPair(
            dark: hex(0x4B, 0x48, 0x43), light: hex(0xD0, 0xCC, 0xC1)
        ),
        .gruvbox: ColorPair(
            dark: hex(0x4B, 0x48, 0x43), light: hex(0xD0, 0xCC, 0xC1)
        ),
        .nord: ColorPair(
            dark: hex(0x4B, 0x48, 0x43), light: hex(0xD0, 0xCC, 0xC1)
        ),
    ]

    static let idles: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xB1, 0xAD, 0xA1), light: hex(0x68, 0x64, 0x5D)),
        .tokyoNight: ColorPair(dark: hex(0x69, 0x71, 0x8E), light: hex(0x70, 0x72, 0x80)),
        .gruvbox: ColorPair(dark: hex(0x88, 0x7A, 0x6E), light: hex(0x92, 0x83, 0x74)),
        .nord: ColorPair(dark: hex(0x7F, 0x8A, 0xA2), light: hex(0x4C, 0x56, 0x6A)),
    ]

    // Subagent count badge. Claude dark was #7216AB (~3.1:1 contrast, fails AA at 9pt)
    // and Nord light was #B48EAD (~3.4:1) — both lightened/darkened to clear 4.5:1.
    static let badges: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xA2, 0x56, 0xC8), light: hex(0x7A, 0x35, 0x80)),
        .tokyoNight: ColorPair(dark: hex(0xBB, 0x9A, 0xF7), light: hex(0x7B, 0x43, 0xBA)),
        .gruvbox: ColorPair(dark: hex(0xD3, 0x86, 0x9B), light: hex(0x8F, 0x3F, 0x71)),
        .nord: ColorPair(dark: hex(0xB4, 0x8E, 0xAD), light: hex(0x8B, 0x6A, 0x86)),
    ]

    // Source badges — themed per-palette so the source row matches the rest of the
    // app's color system instead of using raw SwiftUI system colors. Each source
    // uses the same hue family across themes (opencode → blue, pi → teal, codex →
    // yellow/gold) so users build a consistent mental model.
    static let opencodeBadges: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x5C, 0x8A, 0xB8), light: hex(0x2D, 0x5A, 0x82)),
        .tokyoNight: ColorPair(dark: hex(0x7A, 0xA2, 0xF7), light: hex(0x3A, 0x5B, 0xA0)),
        .gruvbox: ColorPair(dark: hex(0x83, 0xA5, 0x98), light: hex(0x07, 0x66, 0x78)),
        .nord: ColorPair(dark: hex(0x81, 0xA1, 0xC1), light: hex(0x5E, 0x81, 0xAC)),
    ]

    static let piBadges: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0x6E, 0xAE, 0xA8), light: hex(0x34, 0x6B, 0x66)),
        .tokyoNight: ColorPair(dark: hex(0x5D, 0xBF, 0xB1), light: hex(0x1F, 0x6B, 0x5D)),
        .gruvbox: ColorPair(dark: hex(0x8E, 0xC0, 0x7C), light: hex(0x42, 0x7B, 0x58)),
        .nord: ColorPair(dark: hex(0x8F, 0xBC, 0xBB), light: hex(0x4C, 0x72, 0x71)),
    ]

    // Gruvbox codex is bronze rather than yellow because Gruvbox's attention status
    // already owns `#FABD2F` / `#B57614` (pure yellow). Bronze keeps it warm and
    // distinguishable.
    static let codexBadges: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xD4, 0xA8, 0x4A), light: hex(0x8B, 0x69, 0x14)),
        .tokyoNight: ColorPair(dark: hex(0xE0, 0xAF, 0x68), light: hex(0x7B, 0x5A, 0x1F)),
        .gruvbox: ColorPair(dark: hex(0xC5, 0x89, 0x40), light: hex(0x7A, 0x4F, 0x0E)),
        .nord: ColorPair(dark: hex(0xEB, 0xCB, 0x8B), light: hex(0x8B, 0x69, 0x14)),
    ]

    // Claude Desktop — same warm family as the accent (CC) but shifted darker
    // so the Desktop chip background tints distinctly from CLI bare text.
    static let claudeDesktopBadges: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xB0, 0x60, 0x36), light: hex(0xA8, 0x4A, 0x1F)),
        .tokyoNight: ColorPair(dark: hex(0xE0, 0x5A, 0x70), light: hex(0xB0, 0x3A, 0x55)),
        .gruvbox: ColorPair(dark: hex(0xC2, 0x57, 0x00), light: hex(0x82, 0x2B, 0x00)),
        .nord: ColorPair(dark: hex(0xA3, 0x51, 0x58), light: hex(0x8A, 0x3F, 0x46)),
    ]

    // Codex Desktop — deeper variant of the CLI codex bronze.
    static let codexDesktopBadges: [AppTheme: ColorPair] = [
        .claude: ColorPair(dark: hex(0xB8, 0x8A, 0x2E), light: hex(0x6B, 0x4E, 0x0A)),
        .tokyoNight: ColorPair(dark: hex(0xC2, 0x8F, 0x4B), light: hex(0x5C, 0x42, 0x14)),
        .gruvbox: ColorPair(dark: hex(0xA8, 0x6E, 0x2C), light: hex(0x5C, 0x39, 0x06)),
        .nord: ColorPair(dark: hex(0xCD, 0xAE, 0x6D), light: hex(0x6B, 0x4E, 0x0A)),
    ]
}
