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
    }

    func testHidden_refocusShortcut() {
        let r = handle(.refocusShortcut, mode: .hidden)
        if case .refocus(let origin) = r.state.mode {
            XCTAssertTrue(origin.panelWasClosed)
        } else {
            XCTFail("Expected refocus mode")
        }
        XCTAssertTrue(r.actions.contains(.showPanel))
        XCTAssertTrue(r.actions.contains(.startRefocusMode(panelWasClosed: true)))
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

    func testNormal_refocusShortcut() {
        let r = handle(.refocusShortcut, mode: .normal)
        if case .refocus(let origin) = r.state.mode {
            XCTAssertFalse(origin.panelWasClosed)
        } else {
            XCTFail("Expected refocus mode")
        }
        XCTAssertTrue(r.actions.contains(.startRefocusMode(panelWasClosed: false)))
    }

    func testNormal_navKey_forwards() {
        let r = handle(.navKey(.down), mode: .normal)
        XCTAssertEqual(r.actions, [.postNavAction(.down)])
    }

    // MARK: - Refocus (panel was open)

    private let refocusOpenOrigin = RefocusOrigin(panelWasClosed: false)

    func testRefocus_menubarClick_endsRefocus() {
        let r = handle(.menubarIconClicked(appIsActive: true), mode: .refocus(origin: refocusOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
        XCTAssertFalse(r.actions.contains(.dismissPanel))
    }

    func testRefocus_escape_endsRefocusAndRestores() {
        let r = handle(.escape, mode: .refocus(origin: refocusOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    func testRefocus_confirmed_endsWithoutRestore() {
        let r = handle(.refocusConfirmed, mode: .refocus(origin: refocusOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertFalse(r.actions.contains(.activateExternalApp))
    }

    func testRefocus_timedOut_endsAndRestores() {
        let r = handle(.refocusTimedOut, mode: .refocus(origin: refocusOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    func testRefocus_appLostFocus_endsWithoutRestore() {
        let r = handle(.appLostFocus, mode: .refocus(origin: refocusOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertFalse(r.actions.contains(.activateExternalApp))
    }

    func testRefocus_navKey_forwards() {
        let r = handle(.navKey(.down), mode: .refocus(origin: refocusOpenOrigin))
        XCTAssertEqual(r.actions, [.postNavAction(.down)])
    }

    func testRefocus_unrecognizedKey_endsRefocus() {
        let r = handle(.unrecognizedKeyDuringRefocus, mode: .refocus(origin: refocusOpenOrigin))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    // MARK: - Refocus (panel was closed)

    private let refocusPanelWasClosed = RefocusOrigin(panelWasClosed: true)

    func testRefocus_panelClosed_escape_dismissesPanel() {
        let r = handle(.escape, mode: .refocus(origin: refocusPanelWasClosed))
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.dismissPanel))
    }

    func testRefocus_panelClosed_confirmed_dismissesPanel() {
        let r = handle(.refocusConfirmed, mode: .refocus(origin: refocusPanelWasClosed))
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.dismissPanel))
    }

    func testRefocus_panelClosed_appLostFocus_dismissesPanel() {
        let r = handle(.appLostFocus, mode: .refocus(origin: refocusPanelWasClosed))
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.dismissPanel))
    }
}
