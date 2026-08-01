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

    func testNotificationActivationResolvesPermanentIDToCurrentCanonicalObservation() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        var current = Session.mock(
            id: "current-observation", cctopSessionId: cctopSessionID,
            pid: 22_222, source: Session.opencodeSource
        )
        current.lifecycle = .active

        let resolved = AppDelegate.notificationFocusSession(
            matchingUserInfo: [SessionIdentityPolicy.notificationCctopSessionIDKey: cctopSessionID],
            in: [current]
        )

        XCTAssertEqual(resolved?.sessionId, "current-observation")
        XCTAssertEqual(resolved?.pid, 22_222)
    }

    func testLegacyNotificationActivationResolvesReplacementThroughPermanentID() {
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        var current = Session.mock(
            id: "codex-thread-1", cctopSessionId: cctopSessionID,
            pid: 22_222, source: Session.codexSource
        )
        current.lifecycle = .active

        let resolved = AppDelegate.notificationFocusSession(
            matchingUserInfo: [SessionIdentityPolicy.notificationSessionIDKey: "codex-thread-1"],
            in: [current]
        )

        XCTAssertEqual(resolved?.id, "codex-thread-1")
    }

    func testNotificationActivationFailsClosedForUnknownPermanentID() {
        let current = Session.mock(
            id: "other-session",
            cctopSessionId: "22222222-2222-4222-8222-222222222222",
            pid: 22_222,
            source: Session.opencodeSource
        )
        let userInfo: [AnyHashable: Any] = [
            SessionIdentityPolicy.notificationCctopSessionIDKey: "11111111-1111-4111-8111-111111111111",
            SessionIdentityPolicy.notificationSessionIDKey: "other-session",
            SessionIdentityPolicy.notificationSessionPIDKey: "22222",
        ]

        XCTAssertNil(AppDelegate.notificationFocusSession(matchingUserInfo: userInfo, in: [current]))
        XCTAssertNil(AppDelegate.notificationFocusSession(matchingUserInfo: [:], in: [current]))
    }
}
