import AppKit
import SwiftUI

enum AppChrome {
    static let cornerRadius: CGFloat = 8
    static let rowSelectionHorizontalInset: CGFloat = 6
    static let panelCornerRadius: CGFloat = 16
    static let controlCornerRadius = cornerRadius
    static let selectionCornerRadius = panelCornerRadius - rowSelectionHorizontalInset
    static let groupCornerRadius = cornerRadius
    static let settingsContentPaddingHorizontal: CGFloat = 8
    static let settingsContentPaddingTop: CGFloat = 10
    static let settingsContentPaddingBottom: CGFloat = 28
    static let settingsRowHorizontalPadding: CGFloat = 10
    static let settingsSectionHeaderHorizontalPadding = settingsRowHorizontalPadding
    static let settingsDividerLeadingPadding = settingsRowHorizontalPadding
    static let settingsSegmentSpacing: CGFloat = 1
    static let settingsSegmentedControlPadding: CGFloat = 2
    static let settingsSegmentHorizontalPadding: CGFloat = 6
    static let settingsSegmentHeight: CGFloat = 22
    static let settingsSegmentedControlHeight = settingsSegmentHeight + settingsSegmentedControlPadding * 2
    static let settingsSegmentSelectionCornerRadius = controlCornerRadius - settingsSegmentedControlPadding
    static let overlayMinimumContentHeight: CGFloat = 290
    static let overlayContentVerticalPadding: CGFloat = 8
    static let settingsOverlayVerticalPadding: CGFloat = 0
    static let settingsScrollViewportHeight = overlayMinimumContentHeight - settingsOverlayVerticalPadding * 2
    static let settingsContentPadding = EdgeInsets(
        top: settingsContentPaddingTop,
        leading: settingsContentPaddingHorizontal,
        bottom: settingsContentPaddingBottom,
        trailing: settingsContentPaddingHorizontal
    )
    static let listVerticalPadding: CGFloat = 4
}

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

    /// Text shown on accent-filled action buttons.
    static var accentButtonText: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.accentButtonText.resolve(appearance)
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

    /// Subtle material wash layered over the panel base.
    static var panelMaterialOverlay: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.panelMaterialOverlay.resolve(appearance)
        })
    }

    /// Toolbar, tabs, footer, and small chrome controls.
    static var panelControlBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.panelControlBackground.resolve(appearance)
        })
    }

    /// Hairline border for panel chrome.
    static var panelControlBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.panelControlBorder.resolve(appearance)
        })
    }

    /// Accent-tinted hairline used for Option A selected surfaces and panel rim.
    static var panelAccentBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.panelAccentBorder.resolve(appearance)
        })
    }

    /// Faint top light layered over selected controls.
    static var selectionHighlightOverlay: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.selectionHighlightOverlay.resolve(appearance)
        })
    }

    /// Rounded row and tab selection background.
    static var panelSelectionBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.panelSelectionBackground.resolve(appearance)
        })
    }

    /// Sunk background for secondary grouped views.
    static var groupedContentBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.groupedContentBackground.resolve(appearance)
        })
    }

    /// Grouped-list row background.
    static var groupedRowBackground: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.groupedRowBackground.resolve(appearance)
        })
    }

    /// Grouped-list separator and border.
    static var groupedRowBorder: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.groupedRowBorder.resolve(appearance)
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

    /// Idle status.
    static var statusIdle: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.statusIdle.resolve(appearance)
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

    /// Source badge — Claude Desktop.
    static var claudeDesktopBadge: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.claudeDesktopBadge.resolve(appearance)
        })
    }

    /// Source badge — Codex Desktop.
    static var codexDesktopBadge: Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            ThemeManager.shared.current.codexDesktopBadge.resolve(appearance)
        })
    }
}
