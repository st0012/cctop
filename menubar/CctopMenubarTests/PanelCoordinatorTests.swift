import XCTest
@testable import CctopMenubar

final class PanelCoordinatorTests: XCTestCase {
    typealias S = PanelState
    typealias R = PanelCoordinator.Result

    private func handle(_ event: PanelEvent, mode: PanelMode, compact: Bool = false) -> R {
        PanelCoordinator.handle(event: event, state: S(mode: mode, compactPreference: compact))
    }

    // MARK: - Hidden

    func testHidden_menubarClick_compactOff_opensNormal() {
        let r = handle(.menubarIconClicked(appIsActive: false), mode: .hidden, compact: false)
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.showPanel))
        XCTAssertTrue(r.actions.contains(.captureApps))
        XCTAssertTrue(r.actions.contains(.startNavKeyMonitor))
    }

    func testHidden_menubarClick_compactOn_opensCompact() {
        let r = handle(.menubarIconClicked(appIsActive: false), mode: .hidden, compact: true)
        XCTAssertEqual(r.state.mode, .compactCollapsed)
        XCTAssertTrue(r.actions.contains(.showPanel))
    }

    func testHidden_refocusShortcut_compactOff() {
        let r = handle(.refocusShortcut, mode: .hidden, compact: false)
        if case .refocus(let origin) = r.state.mode {
            XCTAssertTrue(origin.panelWasClosed)
            XCTAssertFalse(origin.wasCompact)
        } else {
            XCTFail("Expected refocus mode")
        }
        XCTAssertTrue(r.actions.contains(.showPanel))
        XCTAssertTrue(r.actions.contains(.startRefocusMode(panelWasClosed: true)))
        XCTAssertTrue(r.actions.contains(.startRefocusTimeout))
    }

    func testHidden_refocusShortcut_compactOn() {
        let r = handle(.refocusShortcut, mode: .hidden, compact: true)
        if case .refocus(let origin) = r.state.mode {
            XCTAssertTrue(origin.panelWasClosed)
            XCTAssertTrue(origin.wasCompact)
        } else {
            XCTFail("Expected refocus mode")
        }
    }

    func testHidden_otherEvents_noOp() {
        let r = handle(.cmdM, mode: .hidden)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.isEmpty)
        XCTAssertFalse(r.eventConsumed)
    }

    // MARK: - Normal

    func testNormal_menubarClick_appActive_hidesAndRestores() {
        let r = handle(.menubarIconClicked(appIsActive: true), mode: .normal)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.hidePanel))
        XCTAssertTrue(r.actions.contains(.stopNavKeyMonitor))
        XCTAssertTrue(r.actions.contains(.restorePreviousApp))
    }

    func testNormal_menubarClick_appNotActive_hidesWithoutRestore() {
        let r = handle(.menubarIconClicked(appIsActive: false), mode: .normal)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.hidePanel))
        XCTAssertFalse(r.actions.contains(.restorePreviousApp))
    }

    func testNormal_cmdM_enablesCompact() {
        let r = handle(.cmdM, mode: .normal)
        XCTAssertEqual(r.state.mode, .compactCollapsed)
        XCTAssertTrue(r.state.compactPreference)
        XCTAssertTrue(r.actions.contains(.persistCompactMode(true)))
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
            XCTAssertFalse(origin.wasCompact)
        } else {
            XCTFail("Expected refocus mode")
        }
        XCTAssertTrue(r.actions.contains(.startRefocusMode(panelWasClosed: false)))
    }

    func testNormal_navKey_forwards() {
        let r = handle(.navKey(.down), mode: .normal)
        XCTAssertEqual(r.actions, [.postNavAction(.down)])
    }

    func testNormal_headerClick_noOp() {
        let r = handle(.headerClicked, mode: .normal)
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.isEmpty)
    }

    // MARK: - Compact Collapsed

    func testCompactCollapsed_menubarClick_hides() {
        let r = handle(.menubarIconClicked(appIsActive: true), mode: .compactCollapsed, compact: true)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.hidePanel))
    }

    func testCompactCollapsed_cmdM_disablesCompact() {
        let r = handle(.cmdM, mode: .compactCollapsed, compact: true)
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertFalse(r.state.compactPreference)
        XCTAssertTrue(r.actions.contains(.persistCompactMode(false)))
    }

    func testCompactCollapsed_escape_backgrounds() {
        let r = handle(.escape, mode: .compactCollapsed, compact: true)
        XCTAssertEqual(r.state.mode, .compactBackgrounded)
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    func testCompactCollapsed_headerClick_expands() {
        let r = handle(.headerClicked, mode: .compactCollapsed, compact: true)
        XCTAssertEqual(r.state.mode, .compactExpanded)
    }

    func testCompactCollapsed_appLostFocus_backgrounds() {
        let r = handle(.appLostFocus, mode: .compactCollapsed, compact: true)
        XCTAssertEqual(r.state.mode, .compactBackgrounded)
    }

    func testCompactCollapsed_refocusShortcut() {
        let r = handle(.refocusShortcut, mode: .compactCollapsed, compact: true)
        if case .refocus(let origin) = r.state.mode {
            XCTAssertFalse(origin.panelWasClosed)
            XCTAssertTrue(origin.wasCompact)
        } else {
            XCTFail("Expected refocus mode")
        }
    }

    func testCompactCollapsed_navKey_passThrough() {
        let r = handle(.navKey(.down), mode: .compactCollapsed, compact: true)
        XCTAssertFalse(r.eventConsumed)
        XCTAssertTrue(r.actions.isEmpty)
    }

    // MARK: - Compact Backgrounded

    func testCompactBackgrounded_menubarClick_refocuses() {
        let r = handle(.menubarIconClicked(appIsActive: false), mode: .compactBackgrounded, compact: true)
        XCTAssertEqual(r.state.mode, .compactCollapsed)
        XCTAssertTrue(r.actions.contains(.refocusPanel))
        XCTAssertTrue(r.actions.contains(.startNavKeyMonitor))
    }

    func testCompactBackgrounded_cmdM_disablesAndRefocuses() {
        let r = handle(.cmdM, mode: .compactBackgrounded, compact: true)
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertFalse(r.state.compactPreference)
        XCTAssertTrue(r.actions.contains(.persistCompactMode(false)))
        XCTAssertTrue(r.actions.contains(.refocusPanel))
    }

    func testCompactBackgrounded_refocusShortcut() {
        let r = handle(.refocusShortcut, mode: .compactBackgrounded, compact: true)
        if case .refocus(let origin) = r.state.mode {
            XCTAssertFalse(origin.panelWasClosed)
            XCTAssertTrue(origin.wasCompact)
        } else {
            XCTFail("Expected refocus mode")
        }
        XCTAssertTrue(r.actions.contains(.refocusPanel))
    }

    func testCompactBackgrounded_headerClick_expands() {
        let r = handle(.headerClicked, mode: .compactBackgrounded, compact: true)
        XCTAssertEqual(r.state.mode, .compactExpanded)
        XCTAssertTrue(r.actions.contains(.activateApp))
        XCTAssertTrue(r.actions.contains(.startNavKeyMonitor))
    }

    func testCompactBackgrounded_appLostFocus_noOp() {
        let r = handle(.appLostFocus, mode: .compactBackgrounded, compact: true)
        XCTAssertEqual(r.state.mode, .compactBackgrounded)
        XCTAssertTrue(r.actions.isEmpty)
    }

    func testCompactBackgrounded_escape_notConsumed() {
        let r = handle(.escape, mode: .compactBackgrounded, compact: true)
        XCTAssertFalse(r.eventConsumed)
    }

    // MARK: - Compact Expanded

    func testCompactExpanded_menubarClick_hides() {
        let r = handle(.menubarIconClicked(appIsActive: true), mode: .compactExpanded, compact: true)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.hidePanel))
    }

    func testCompactExpanded_cmdM_disablesCompact() {
        let r = handle(.cmdM, mode: .compactExpanded, compact: true)
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertFalse(r.state.compactPreference)
    }

    func testCompactExpanded_escape_backgrounds() {
        let r = handle(.escape, mode: .compactExpanded, compact: true)
        XCTAssertEqual(r.state.mode, .compactBackgrounded)
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    func testCompactExpanded_headerClick_noOp() {
        let r = handle(.headerClicked, mode: .compactExpanded, compact: true)
        XCTAssertEqual(r.state.mode, .compactExpanded)
        XCTAssertTrue(r.actions.isEmpty)
    }

    func testCompactExpanded_appLostFocus_collapses() {
        let r = handle(.appLostFocus, mode: .compactExpanded, compact: true)
        XCTAssertEqual(r.state.mode, .compactCollapsed)
    }

    func testCompactExpanded_refocusShortcut() {
        let r = handle(.refocusShortcut, mode: .compactExpanded, compact: true)
        if case .refocus(let origin) = r.state.mode {
            XCTAssertFalse(origin.panelWasClosed)
            XCTAssertTrue(origin.wasCompact)
        } else {
            XCTFail("Expected refocus mode")
        }
    }

    func testCompactExpanded_navKey_forwards() {
        let r = handle(.navKey(.up), mode: .compactExpanded, compact: true)
        XCTAssertEqual(r.actions, [.postNavAction(.up)])
        XCTAssertTrue(r.eventConsumed)
    }

    // MARK: - Refocus (panel was open, non-compact)

    private let refocusOpenNonCompact = RefocusOrigin(panelWasClosed: false, wasCompact: false)

    func testRefocus_menubarClick_endsRefocus() {
        let r = handle(.menubarIconClicked(appIsActive: true), mode: .refocus(origin: refocusOpenNonCompact))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
        XCTAssertFalse(r.actions.contains(.hidePanel))
    }

    func testRefocus_escape_endsRefocusAndRestores() {
        let r = handle(.escape, mode: .refocus(origin: refocusOpenNonCompact))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    func testRefocus_confirmed_endsWithoutRestore() {
        let r = handle(.refocusConfirmed, mode: .refocus(origin: refocusOpenNonCompact))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertFalse(r.actions.contains(.activateExternalApp))
    }

    func testRefocus_timedOut_endsAndRestores() {
        let r = handle(.refocusTimedOut, mode: .refocus(origin: refocusOpenNonCompact))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    func testRefocus_appLostFocus_endsWithoutRestore() {
        let r = handle(.appLostFocus, mode: .refocus(origin: refocusOpenNonCompact))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertFalse(r.actions.contains(.activateExternalApp))
    }

    func testRefocus_navKey_forwards() {
        let r = handle(.navKey(.down), mode: .refocus(origin: refocusOpenNonCompact))
        XCTAssertEqual(r.actions, [.postNavAction(.down)])
    }

    func testRefocus_unrecognizedKey_endsRefocus() {
        let r = handle(.unrecognizedKeyDuringRefocus, mode: .refocus(origin: refocusOpenNonCompact))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertTrue(r.actions.contains(.activateExternalApp))
    }

    // MARK: - Refocus (panel was closed)

    private let refocusPanelWasClosed = RefocusOrigin(panelWasClosed: true, wasCompact: false)

    func testRefocus_panelClosed_escape_hidesPanel() {
        let r = handle(.escape, mode: .refocus(origin: refocusPanelWasClosed))
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.hidePanel))
        XCTAssertTrue(r.actions.contains(.stopNavKeyMonitor))
    }

    func testRefocus_panelClosed_confirmed_hidesPanel() {
        let r = handle(.refocusConfirmed, mode: .refocus(origin: refocusPanelWasClosed))
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.actions.contains(.hidePanel))
    }

    // MARK: - Refocus (was compact)

    private let refocusWasCompact = RefocusOrigin(panelWasClosed: false, wasCompact: true)

    func testRefocus_wasCompact_escape_returnsToCompactCollapsed() {
        let r = handle(.escape, mode: .refocus(origin: refocusWasCompact), compact: true)
        XCTAssertEqual(r.state.mode, .compactCollapsed)
    }

    func testRefocus_wasCompact_confirmed_returnsToCompactCollapsed() {
        let r = handle(.refocusConfirmed, mode: .refocus(origin: refocusWasCompact), compact: true)
        XCTAssertEqual(r.state.mode, .compactCollapsed)
    }

    // MARK: - Regression: Cmd+M during refocus

    func testCmdM_duringRefocus_panelWasClosed_hidesPanel() {
        let origin = RefocusOrigin(panelWasClosed: true, wasCompact: false)
        let state = S(mode: .refocus(origin: origin), compactPreference: false)
        let r = PanelCoordinator.handle(event: .cmdM, state: state)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertTrue(r.actions.contains(.hidePanel))
        XCTAssertTrue(r.actions.contains(.stopNavKeyMonitor))
        XCTAssertTrue(r.actions.contains(.persistCompactMode(true)))
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.state.compactPreference)
    }

    func testCmdM_duringRefocus_panelWasOpen_togglesCompact() {
        let origin = RefocusOrigin(panelWasClosed: false, wasCompact: false)
        let state = S(mode: .refocus(origin: origin), compactPreference: false)
        let r = PanelCoordinator.handle(event: .cmdM, state: state)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertFalse(r.actions.contains(.hidePanel))
        XCTAssertEqual(r.state.mode, .compactCollapsed)
        XCTAssertTrue(r.state.compactPreference)
    }

    func testCmdM_duringRefocus_wasCompact_togglesOff() {
        let origin = RefocusOrigin(panelWasClosed: false, wasCompact: true)
        let state = S(mode: .refocus(origin: origin), compactPreference: true)
        let r = PanelCoordinator.handle(event: .cmdM, state: state)
        XCTAssertTrue(r.actions.contains(.endRefocusMode))
        XCTAssertEqual(r.state.mode, .normal)
        XCTAssertFalse(r.state.compactPreference)
    }

    // MARK: - Compact preference preservation

    func testCompactPreference_preserved_through_normal_close() {
        let r = handle(.menubarIconClicked(appIsActive: true), mode: .normal, compact: true)
        XCTAssertEqual(r.state.mode, .hidden)
        XCTAssertTrue(r.state.compactPreference, "compactPreference should be preserved")
    }

    func testCompactPreference_preserved_through_refocus_end() {
        let origin = RefocusOrigin(panelWasClosed: false, wasCompact: true)
        let r = handle(.escape, mode: .refocus(origin: origin), compact: true)
        XCTAssertTrue(r.state.compactPreference)
    }
}
