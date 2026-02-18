import XCTest
@testable import CctopMenubar

final class PanelToggleTests: XCTestCase {
    // MARK: - Focus restoration on panel close

    /// Regression test: closing the panel after the user switched to another app
    /// should NOT yank focus back to the app that was frontmost when the panel opened.
    func testDoesNotRestoreFocusWhenAppIsInactive() {
        // User opened panel, then switched to Safari → cctop is no longer active
        XCTAssertFalse(AppDelegate.shouldRestoreFocus(appIsActive: false))
    }

    /// When the user opens and immediately closes the panel without switching,
    /// cctop is still active → restore focus to the previous app.
    func testRestoresFocusWhenAppIsStillActive() {
        XCTAssertTrue(AppDelegate.shouldRestoreFocus(appIsActive: true))
    }
}
