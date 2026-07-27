import XCTest
@testable import CctopMenubar

final class PanelToggleTests: XCTestCase {
    // MARK: - Focus restoration on panel close

    /// Regression test: closing the panel after the user switched to another app
    /// should NOT yank focus back to the app that was frontmost when the panel opened.
    func testDoesNotRestoreFocusWhenAppIsInactive() {
        let state = PanelState(mode: .normal)
        let result = PanelCoordinator.handle(event: .menubarIconClicked(appIsActive: false), state: state)
        XCTAssertEqual(result.state.mode, .hidden)
        XCTAssertFalse(result.actions.contains(.restorePreviousApp))
    }

    /// When the user opens and immediately closes the panel without switching,
    /// cctop is still active -> restore focus to the previous app.
    func testRestoresFocusWhenAppIsStillActive() {
        let state = PanelState(mode: .normal)
        let result = PanelCoordinator.handle(event: .menubarIconClicked(appIsActive: true), state: state)
        XCTAssertEqual(result.state.mode, .hidden)
        XCTAssertTrue(result.actions.contains(.restorePreviousApp))
    }

    func testCctopURLCommandParsesHostAndOpaqueForms() throws {
        XCTAssertEqual(
            AppDelegate.urlCommand(from: try XCTUnwrap(URL(string: "cctop://toggle"))),
            "toggle"
        )
        XCTAssertEqual(
            AppDelegate.urlCommand(from: try XCTUnwrap(URL(string: "cctop:toggle"))),
            "toggle"
        )
    }

    func testFocusTargetDecodesCctopSessionIdentity() throws {
        let url = try XCTUnwrap(URL(string: "cctop://focus?sid=codex%3Aabc%2Fdef%3Fghi"))
        XCTAssertEqual(AppDelegate.urlCommand(from: url), "focus")
        XCTAssertEqual(AppDelegate.focusSessionID(from: url), "codex:abc/def?ghi")
        XCTAssertNil(AppDelegate.focusSessionID(from: try XCTUnwrap(URL(string: "cctop://focus"))))
        XCTAssertNil(AppDelegate.focusSessionID(from: try XCTUnwrap(URL(string: "cctop://focus?sid="))))
    }
}
