import AppKit
import SwiftUI

extension Color {
    /// Accent color — the primary brand color, themed per color scheme.
    static var amber: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.accent.resolve(appearance)
        })
    }

    /// Segmented control background.
    static var segmentBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.segmentBackground.resolve(appearance)
        })
    }

    /// Segmented control inactive text.
    static var segmentText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.segmentText.resolve(appearance)
        })
    }

    /// Active segment text.
    static var segmentActiveText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.segmentActiveText.resolve(appearance)
        })
    }

    /// Settings section background.
    static var settingsBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.settingsBackground.resolve(appearance)
        })
    }

    /// Settings section border.
    static var settingsBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.settingsBorder.resolve(appearance)
        })
    }

    /// Panel background.
    static var panelBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.panelBackground.resolve(appearance)
        })
    }

    /// Card background.
    static var cardBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.cardBackground.resolve(appearance)
        })
    }

    /// Card border.
    static var cardBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.cardBorder.resolve(appearance)
        })
    }

    /// Attention/waiting status (less urgent than permission).
    static var statusAttention: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.statusAttention.resolve(appearance)
        })
    }

    /// Permission status (urgent, needs approval).
    static var statusPermission: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.statusPermission.resolve(appearance)
        })
    }

    /// Working status green.
    static var statusGreen: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.statusGreen.resolve(appearance)
        })
    }

    /// Secondary text — branch, meta, working status.
    static var textSecondary: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.textSecondary.resolve(appearance)
        })
    }

    /// Muted text — timestamps, idle status, footer.
    static var textMuted: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.textMuted.resolve(appearance)
        })
    }

    /// Dimmed primary — idle project names.
    static var textDimmed: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.textDimmed.resolve(appearance)
        })
    }

    /// Primary text.
    static var textPrimary: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.textPrimary.resolve(appearance)
        })
    }

    /// Agent badge color.
    static var agentBadge: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.agentBadge.resolve(appearance)
        })
    }

    /// Source badge — opencode.
    static var opencodeBadge: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.opencodeBadge.resolve(appearance)
        })
    }

    /// Source badge — pi.
    static var piBadge: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.piBadge.resolve(appearance)
        })
    }

    /// Source badge — codex.
    static var codexBadge: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.codexBadge.resolve(appearance)
        })
    }
}
