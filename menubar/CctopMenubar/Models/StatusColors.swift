import AppKit
import SwiftUI

/// Shared status-bar colors used by the menubar item and notch pill.
@MainActor
enum StatusColors {
    /// Resolve the current theme's semantic color for the target appearance.
    static func color(for kind: StatusCounts.SegmentKind, appearance: NSAppearance) -> NSColor {
        colorPair(for: kind).resolve(appearance)
    }

    /// The notch is always drawn on a black pill, so its live colors use the
    /// selected theme's dark palette even when the app itself is in light mode.
    static func notchColor(for kind: StatusCounts.SegmentKind) -> Color {
        Color(nsColor: colorPair(for: kind).dark)
    }

    private static func colorPair(for kind: StatusCounts.SegmentKind) -> AppTheme.ColorPair {
        let theme = ThemeManager.shared.current
        switch kind {
        case .permission: return theme.statusPermission
        case .attention: return theme.statusAttention
        case .working: return theme.statusWorking
        case .idle: return theme.statusIdle
        }
    }
}
