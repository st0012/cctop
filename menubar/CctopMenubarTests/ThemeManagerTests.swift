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
}
