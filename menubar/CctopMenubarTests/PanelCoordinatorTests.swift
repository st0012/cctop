import XCTest
@testable import CctopMenubar

final class PanelCoordinatorTests: XCTestCase {
    typealias S = PanelState
    typealias R = PanelCoordinator.Result

    private func handle(_ event: PanelEvent, mode: PanelMode) -> R {
        PanelCoordinator.handle(event: event, state: S(mode: mode))
    }

    // MARK: - Hidden

    func testHidden_menubarClick_opensNormal() {
        let r = handle(.menubarIconClicked(appIsActive: false), mode: .hidden)
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.showPanel))
        XCTAssertTrue(r.actions.contains(.captureApps))
        XCTAssertTrue(r.actions.contains(.startNavKeyMonitor))
        XCTAssertFalse(r.actions.contains(.positionPanel))
    }

    func testHidden_navigateShortcut() {
        let r = handle(.navigateShortcut(), mode: .hidden)
        if case .navigate(let origin) = r.state.mode {
            XCTAssertTrue(origin.panelWasClosed)
        } else {
            XCTFail("Expected navigate mode")
        }
        XCTAssertTrue(r.actions.contains(.showPanel))
        XCTAssertTrue(r.actions.contains(.startNavigateMode(panelWasClosed: true)))
    }

    func testPanelOpenActionsDoNotForceCleanupRefresh() {
        XCTAssertEqual(
            handle(.menubarIconClicked(appIsActive: false), mode: .hidden).actions,
            [.captureApps, .showPanel, .activateApp, .startNavKeyMonitor, .postNavAction(.reset)]
        )
        XCTAssertEqual(
            handle(.navigateShortcut(), mode: .hidden).actions,
            [.showPanel, .activateApp, .startNavKeyMonitor, .startNavigateMode(panelWasClosed: true)]
        )
        XCTAssertEqual(
            handle(.menubarIconClicked(appIsActive: false, panelVisibleInActiveSpace: false), mode: .normal).actions,
            [.captureApps, .showPanel, .activateApp, .startNavKeyMonitor, .postNavAction(.reset)]
        )
        XCTAssertEqual(
            handle(.navigateShortcut(panelVisibleInActiveSpace: false), mode: .normal).actions,
            [.showPanel, .activateApp, .startNavKeyMonitor, .startNavigateMode(panelWasClosed: true)]
        )
    }

    func testHidden_otherEvents_noOp() {
        let r = handle(.escape, mode: .hidden)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertFalse(r.eventConsumed)
    }

    // MARK: - Normal

    func testNormal_menubarClick_appActive_hidesAndRestores() {
        let r = handle(.menubarIconClicked(appIsActive: true), mode: .normal)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.dismissPanel))
        XCTAssertTrue(r.actions.contains(.restorePreviousApp))
    }

    func testNormal_menubarClick_appNotActive_hidesWithoutRestore() {
        let r = handle(.menubarIconClicked(appIsActive: false), mode: .normal)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.dismissPanel))
        XCTAssertFalse(r.actions.contains(.restorePreviousApp))
    }

    func testNormal_menubarClickDifferentScreen_repositionsWithoutDismiss() {
        let r = handle(.menubarIconClicked(appIsActive: true, onDifferentScreen: true), mode: .normal)
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.positionPanel))
        XCTAssertTrue(r.actions.contains(.activateApp))
        XCTAssertFalse(r.actions.contains(.dismissPanel))
    }

    func testNormal_menubarClickSameScreen_dismisses() {
        let r = handle(.menubarIconClicked(appIsActive: true, onDifferentScreen: false), mode: .normal)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.dismissPanel))
    }

    func testNormal_menubarClickWhenPanelIsNotVisibleOnActiveSpace_showsInsteadOfDismissing() {
        let r = handle(
            .menubarIconClicked(
                appIsActive: false,
                onDifferentScreen: false,
                panelVisibleInActiveSpace: false
            ),
            mode: .normal
        )

        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.showPanel))
        XCTAssertTrue(r.actions.contains(.activateApp))
        XCTAssertTrue(r.actions.contains(.captureApps))
        XCTAssertFalse(r.actions.contains(.dismissPanel))
    }

    func testNormal_escape_postsEscapeAction() {
        let r = handle(.escape, mode: .normal)
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertEqual(r.actions, [.postNavAction(.escape)])
    }

    func testNormal_appLostFocus_noOp() {
        let r = handle(.appLostFocus, mode: .normal)
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.isEmpty)
    }

    func testNormal_navigateShortcut() {
        let r = handle(.navigateShortcut(), mode: .normal)
        if case .navigate(let origin) = r.state.mode {
            XCTAssertFalse(origin.panelWasClosed)
        } else {
            XCTFail("Expected navigate mode")
        }
        XCTAssertTrue(r.actions.contains(.startNavigateMode(panelWasClosed: false)))
    }

    func testNormal_navigateShortcutWhenPanelIsNotVisibleOnActiveSpace_treatsPanelAsClosed() {
        let r = handle(.navigateShortcut(panelVisibleInActiveSpace: false), mode: .normal)

        if case .navigate(let origin) = r.state.mode {
            XCTAssertTrue(origin.panelWasClosed)
        } else {
            XCTFail("Expected navigate mode")
        }

        XCTAssertTrue(r.actions.contains(.showPanel))
        XCTAssertTrue(r.actions.contains(.activateApp))
        XCTAssertTrue(r.actions.contains(.startNavKeyMonitor))
        XCTAssertTrue(r.actions.contains(.startNavigateMode(panelWasClosed: true)))
    }

    func testNormal_navKey_forwards() {
        let r = handle(.navKey(.down), mode: .normal)
        XCTAssertEqual(r.actions, [.postNavAction(.down)])
    }

    // MARK: - Navigate (panel was open)

    private let navigateOpenOrigin = NavigateOrigin(panelWasClosed: false)

    func testNavigate_menubarClick_endsNavigate() {
        let r = handle(.menubarIconClicked(appIsActive: true), mode: .navigate(origin: navigateOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endNavigateMode))
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
        XCTAssertFalse(r.actions.contains(.dismissPanel))
    }

    func testNavigate_escape_endsNavigateAndRestores() {
        let r = handle(.escape, mode: .navigate(origin: navigateOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endNavigateMode))
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    func testNavigate_confirmed_endsWithoutRestore() {
        let r = handle(.navigateConfirmed, mode: .navigate(origin: navigateOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endNavigateMode))
        XCTAssertFalse(r.actions.contains(.activateExternalApp))
    }

    func testNavigate_timedOut_endsAndRestores() {
        let r = handle(.navigateTimedOut, mode: .navigate(origin: navigateOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    func testNavigate_appLostFocus_endsWithoutRestore() {
        let r = handle(.appLostFocus, mode: .navigate(origin: navigateOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endNavigateMode))
        XCTAssertFalse(r.actions.contains(.activateExternalApp))
    }

    func testNavigate_navKey_forwards() {
        let r = handle(.navKey(.down), mode: .navigate(origin: navigateOpenOrigin))
        XCTAssertEqual(r.actions, [.postNavAction(.down)])
    }

    func testNavigate_unrecognizedKey_endsNavigate() {
        let r = handle(.unrecognizedKeyDuringNavigate, mode: .navigate(origin: navigateOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endNavigateMode))
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    // MARK: - Navigate (panel was closed)

    private let navigatePanelWasClosed = NavigateOrigin(panelWasClosed: true)

    func testNavigate_panelClosed_escape_dismissesPanel() {
        let r = handle(.escape, mode: .navigate(origin: navigatePanelWasClosed))
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.dismissPanel))
    }

    func testNavigate_panelClosed_confirmed_dismissesPanel() {
        let r = handle(.navigateConfirmed, mode: .navigate(origin: navigatePanelWasClosed))
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.dismissPanel))
    }

    func testNavigate_panelClosed_appLostFocus_dismissesPanel() {
        let r = handle(.appLostFocus, mode: .navigate(origin: navigatePanelWasClosed))
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.dismissPanel))
    }
}
