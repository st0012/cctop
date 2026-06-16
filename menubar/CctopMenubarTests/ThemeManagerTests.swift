import AppKit
import XCTest
@testable import CctopMenubar

@MainActor
final class ThemeManagerTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "ThemeManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        UserDefaults.standard.removeSuite(named: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultThemeIsClaude() {
        let manager = ThemeManager(defaults: defaults)
        XCTAssertEqual(manager.current, .claude)
    }

    func testSetThemeUpdatesCurrentValue() {
        let manager = ThemeManager(defaults: defaults)
        manager.setTheme(.nord)
        XCTAssertEqual(manager.current, .nord)
    }

    func testSetThemePersistsImmediately() {
        let manager = ThemeManager(defaults: defaults)
        manager.setTheme(.gruvbox)

        // Read directly from the same defaults to verify it was written
        let stored = defaults.string(forKey: ThemeManager.defaultsKey)
        XCTAssertEqual(stored, "gruvbox")
    }

    func testPersistedThemeSurvivesReinitialization() {
        let manager = ThemeManager(defaults: defaults)
        manager.setTheme(.tokyoNight)

        // Create a new manager reading from the same defaults — simulates app relaunch
        let manager2 = ThemeManager(defaults: defaults)
        XCTAssertEqual(manager2.current, .tokyoNight)
    }

    func testUnknownStoredValueFallsToClaude() {
        defaults.set("nonexistent", forKey: ThemeManager.defaultsKey)
        let manager = ThemeManager(defaults: defaults)
        XCTAssertEqual(manager.current, .claude)
    }

    func testMacOSRefinementChromeRolesResolveForEveryThemeAndAppearance() {
        let appearances: [NSAppearance] = [
            NSAppearance(named: .darkAqua)!,
            NSAppearance(named: .aqua)!,
        ]

        for theme in AppTheme.allCases {
            for appearance in appearances {
                let panel = theme.panelMaterialOverlay.resolve(appearance)
                    .flattened(over: theme.panelBackground.resolve(appearance))
                let primary = theme.textPrimary.resolve(appearance)
                let secondary = theme.textSecondary.resolve(appearance)
                let muted = theme.textMuted.resolve(appearance)
                let dimmed = theme.textDimmed.resolve(appearance)
                let idle = theme.statusIdle.resolve(appearance)

                XCTAssertGreaterThanOrEqual(
                    primary.contrastRatio(against: panel), 4.5,
                    "\(theme.displayName) primary text should stay readable in \(appearance.name.rawValue)"
                )
                XCTAssertGreaterThanOrEqual(
                    secondary.contrastRatio(against: panel), 4.5,
                    "\(theme.displayName) secondary text should stay readable in \(appearance.name.rawValue)"
                )
                XCTAssertGreaterThanOrEqual(
                    muted.contrastRatio(against: panel), 3.0,
                    "\(theme.displayName) muted text should stay usable in \(appearance.name.rawValue)"
                )
                XCTAssertGreaterThanOrEqual(
                    dimmed.contrastRatio(against: panel), 3.0,
                    "\(theme.displayName) dimmed text should stay usable in \(appearance.name.rawValue)"
                )
                XCTAssertGreaterThanOrEqual(
                    idle.contrastRatio(against: panel), 3.0,
                    "\(theme.displayName) idle status should stay usable in \(appearance.name.rawValue)"
                )

                let chromeRoles = [
                    theme.panelMaterialOverlay,
                    theme.panelControlBackground,
                    theme.panelControlBorder,
                    theme.panelAccentBorder,
                    theme.selectionHighlightOverlay,
                    theme.panelSelectionBackground,
                    theme.groupedContentBackground,
                    theme.groupedRowBackground,
                    theme.groupedRowBorder,
                ]
                for role in chromeRoles {
                    XCTAssertGreaterThanOrEqual(role.resolve(appearance).alphaComponent, 0)
                    XCTAssertLessThanOrEqual(role.resolve(appearance).alphaComponent, 1)
                }
            }
        }
    }

    func testAccentButtonTextStaysReadableInEveryThemeAndAppearance() {
        let appearances: [NSAppearance] = [
            NSAppearance(named: .darkAqua)!,
            NSAppearance(named: .aqua)!,
        ]

        for theme in AppTheme.allCases {
            for appearance in appearances {
                XCTAssertGreaterThanOrEqual(
                    theme.accentButtonText.resolve(appearance).contrastRatio(against: theme.accent.resolve(appearance)),
                    4.5,
                    "\(theme.displayName) accent button text should stay readable in \(appearance.name.rawValue)"
                )
            }
        }
    }

    func testAppChromeKeepsRoundedElementsOnOneRadiusAndSettingsAwayFromFooter() {
        XCTAssertEqual(AppChrome.panelCornerRadius, 16)
        XCTAssertEqual(AppChrome.selectionCornerRadius, AppChrome.panelCornerRadius - AppChrome.rowSelectionHorizontalInset)
        XCTAssertEqual(AppChrome.selectionCornerRadius, 10)
        XCTAssertEqual(AppChrome.controlCornerRadius, AppChrome.cornerRadius)
        XCTAssertEqual(AppChrome.groupCornerRadius, AppChrome.cornerRadius)
        XCTAssertEqual(AppChrome.settingsSectionHeaderHorizontalPadding, AppChrome.settingsRowHorizontalPadding)
        XCTAssertEqual(AppChrome.settingsDividerLeadingPadding, AppChrome.settingsRowHorizontalPadding)
        XCTAssertEqual(
            AppChrome.settingsSegmentedControlHeight,
            AppChrome.settingsSegmentHeight + AppChrome.settingsSegmentedControlPadding * 2
        )
        XCTAssertEqual(
            AppChrome.settingsSegmentSelectionCornerRadius,
            AppChrome.controlCornerRadius - AppChrome.settingsSegmentedControlPadding
        )
        XCTAssertLessThanOrEqual(AppChrome.settingsSegmentHorizontalPadding, 6)
        XCTAssertLessThanOrEqual(AppChrome.settingsSegmentSpacing, AppChrome.settingsSegmentedControlPadding)
        XCTAssertGreaterThanOrEqual(AppChrome.settingsContentPaddingBottom, AppChrome.cornerRadius * 3)
        XCTAssertGreaterThan(AppChrome.overlayMinimumContentHeight, 0)
        XCTAssertLessThan(AppChrome.overlayMinimumContentHeight, CGFloat.infinity)
        XCTAssertEqual(AppChrome.settingsOverlayVerticalPadding, 0)
        XCTAssertEqual(
            AppChrome.settingsScrollViewportHeight + AppChrome.settingsOverlayVerticalPadding * 2,
            AppChrome.overlayMinimumContentHeight
        )
    }
}

private extension NSColor {
    func contrastRatio(against background: NSColor) -> CGFloat {
        let foreground = flattened(over: background)
        let bg = background.usingColorSpace(.sRGB) ?? background
        let lighter = max(foreground.relativeLuminance, bg.relativeLuminance)
        let darker = min(foreground.relativeLuminance, bg.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    func flattened(over background: NSColor) -> NSColor {
        let fg = usingColorSpace(.sRGB) ?? self
        let bg = background.usingColorSpace(.sRGB) ?? background
        guard fg.alphaComponent < 1 else { return fg }
        let alpha = fg.alphaComponent
        return NSColor(
            red: fg.redComponent * alpha + bg.redComponent * (1 - alpha),
            green: fg.greenComponent * alpha + bg.greenComponent * (1 - alpha),
            blue: fg.blueComponent * alpha + bg.blueComponent * (1 - alpha),
            alpha: 1
        )
    }

    var relativeLuminance: CGFloat {
        let color = usingColorSpace(.sRGB) ?? self
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }
}
