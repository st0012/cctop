import XCTest
@testable import CctopMenubar

/// Scenario tests that mirror the PR test plan checklist.
/// Each test traces a complete multi-step user interaction,
/// verifying both the state machine and the visual state.
final class CompactModeScenarioTests: XCTestCase {
    private var state: PanelState!
    private var compact: CompactModeController!

    override func setUp() {
        super.setUp()
        state = PanelState(mode: .hidden, compactPreference: false)
        compact = CompactModeController()
        UserDefaults.standard.removeObject(forKey: "compactMode")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "compactMode")
        compact = nil
        state = nil
        super.tearDown()
    }

    /// Simulate what AppDelegate.handleEvent does: call coordinator,
    /// apply state, sync visual state.
    @discardableResult
    private func send(_ event: PanelEvent) -> PanelCoordinator.Result {
        let result = PanelCoordinator.handle(event: event, state: state)
        state = result.state
        compact.compactMode = result.state.compactPreference
        compact.syncVisualState(result.state.mode)
        return result
    }

    // MARK: - Basic Cmd+M toggle

    /// PR: Open panel → Cmd+M → panel collapses to header-only bar with status chips
    func testOpenPanel_CmdM_collapsesToHeader() {
        send(.menubarIconClicked(appIsActive: false))
        XCTAssertEqual(state.mode, .normal)
        XCTAssertFalse(compact.isCompact, "Normal mode should not be compact")

        send(.cmdM)
        XCTAssertEqual(state.mode, .compactCollapsed)
        XCTAssertTrue(compact.isCompact, "After Cmd+M, panel should show compact header")
        XCTAssertTrue(compact.compactMode, "compactMode preference should be ON")
    }

    /// PR: Cmd+M again → panel expands back to full normal view
    func testCmdM_togglesBackToNormal() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        XCTAssertTrue(compact.isCompact)

        send(.cmdM)
        XCTAssertEqual(state.mode, .normal)
        XCTAssertFalse(compact.isCompact, "Second Cmd+M should restore normal view")
        XCTAssertFalse(compact.compactMode, "compactMode preference should be OFF")
    }

    /// PR: Repeat toggle a few times — should always work
    func testCmdM_repeatedToggle() {
        send(.menubarIconClicked(appIsActive: false))

        for i in 0..<6 {
            send(.cmdM)
            if i % 2 == 0 {
                XCTAssertTrue(compact.isCompact, "Iteration \(i): should be compact")
            } else {
                XCTAssertFalse(compact.isCompact, "Iteration \(i): should be normal")
            }
        }
    }

    // MARK: - Peeking (temporary expand)

    /// PR: In compact collapsed → click the header → panel expands to full view (peeking)
    func testCompactCollapsed_headerClick_expands() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        XCTAssertTrue(compact.isCompact)

        send(.headerClicked)
        XCTAssertEqual(state.mode, .compactExpanded)
        XCTAssertFalse(compact.isCompact, "Header click should expand to full view")
        XCTAssertTrue(compact.compactMode, "compactMode preference stays ON while peeking")
    }

    /// PR: Click away (another app) → panel auto-collapses back to header
    func testPeeking_clickAway_autoCollapses() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        send(.headerClicked)
        XCTAssertFalse(compact.isCompact, "Should be expanded (peeking)")

        send(.appLostFocus)
        XCTAssertEqual(state.mode, .compactCollapsed)
        XCTAssertTrue(compact.isCompact, "Losing focus should collapse back to header")
    }

    /// PR: In compact collapsed → trigger refocus shortcut → panel expands with number badges
    func testCompactCollapsed_refocusShortcut_expands() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        XCTAssertTrue(compact.isCompact)

        send(.refocusShortcut)
        if case .refocus(let origin) = state.mode {
            XCTAssertTrue(origin.wasCompact, "Origin should record compact state")
        } else {
            XCTFail("Expected refocus mode")
        }
        XCTAssertFalse(compact.isCompact, "Panel should expand for refocus")
        XCTAssertTrue(compact.isExpanded, "isExpanded should be true during refocus")
    }

    /// PR: Press Escape → refocus ends, panel collapses back to header
    func testCompactRefocus_escape_collapsesBackToHeader() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        send(.refocusShortcut)
        XCTAssertFalse(compact.isCompact, "Expanded for refocus")

        send(.escape)
        XCTAssertEqual(state.mode, .compactCollapsed)
        XCTAssertTrue(compact.isCompact, "After escape, panel should collapse to header")
        XCTAssertTrue(compact.compactMode, "compactMode preference preserved")
    }

    /// PR: Press a number → refocus ends, panel collapses back to header
    func testCompactRefocus_confirmed_collapsesBackToHeader() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        send(.refocusShortcut)
        XCTAssertFalse(compact.isCompact)

        send(.refocusConfirmed)
        XCTAssertEqual(state.mode, .compactCollapsed)
        XCTAssertTrue(compact.isCompact, "After confirming refocus, panel should collapse to header")
    }

    // MARK: - Cmd+M during refocus

    /// PR: In compact collapsed → trigger refocus → press Cmd+M →
    ///     refocus should end AND compact mode should toggle OFF (normal full view)
    func testCompactRefocus_CmdM_endsRefocusAndTogglesOff() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        XCTAssertTrue(compact.compactMode)

        send(.refocusShortcut)
        let r = send(.cmdM)
        XCTAssertTrue(r.actions.contains(.endRefocusMode), "Refocus should end")
        XCTAssertEqual(state.mode, .normal, "Should return to normal mode")
        XCTAssertFalse(compact.compactMode, "Compact mode should be OFF")
        XCTAssertFalse(compact.isCompact, "Should show full view")
    }

    /// PR: In normal view → trigger refocus → press Cmd+M →
    ///     refocus should end AND compact mode should toggle ON (collapses to header)
    func testNormalRefocus_CmdM_endsRefocusAndTogglesOn() {
        send(.menubarIconClicked(appIsActive: false))
        XCTAssertEqual(state.mode, .normal)
        XCTAssertFalse(compact.compactMode)

        send(.refocusShortcut)
        let r = send(.cmdM)
        XCTAssertTrue(r.actions.contains(.endRefocusMode), "Refocus should end")
        XCTAssertEqual(state.mode, .compactCollapsed, "Should enter compact mode")
        XCTAssertTrue(compact.compactMode, "Compact mode should be ON")
        XCTAssertTrue(compact.isCompact, "Should show compact header")
    }

    // MARK: - Escape focus restoration

    /// PR: Open panel → Cmd+M (collapse) → Escape → focus returns to previous app
    func testCompactEscape_activatesExternalApp() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)

        let r = send(.escape)
        XCTAssertTrue(r.actions.contains(.activateExternalApp),
                       "Escape should activate external app")
    }

    /// PR: Panel should stay visible as compact header after Escape
    func testCompactEscape_panelStaysVisible() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)

        send(.escape)
        XCTAssertEqual(state.mode, .compactInactive,
                       "Panel should be inactive, not hidden")
        XCTAssertTrue(compact.isCompact, "Should still show compact header")
    }

    /// PR: Click menubar icon → panel closes → click again → panel reopens in compact mode
    func testCloseAndReopen_remembersCompactMode() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        XCTAssertTrue(state.compactPreference)

        // Close panel
        send(.menubarIconClicked(appIsActive: true))
        XCTAssertEqual(state.mode, .hidden)
        XCTAssertTrue(state.compactPreference, "Preference preserved when closed")

        // Reopen
        send(.menubarIconClicked(appIsActive: false))
        XCTAssertEqual(state.mode, .compactCollapsed,
                       "Should reopen in compact mode")
        XCTAssertTrue(compact.isCompact)
    }

    // MARK: - Visual indicator (amber underline)

    /// PR: Amber underline appears when compact mode is ON
    func testVisualIndicator_compactModeOn() {
        send(.menubarIconClicked(appIsActive: false))
        XCTAssertFalse(compact.compactMode, "No underline in normal mode")

        send(.cmdM)
        XCTAssertTrue(compact.compactMode, "Underline should appear")
    }

    /// PR: Underline stays visible even when temporarily expanded (peeking)
    func testVisualIndicator_staysWhilePeeking() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        send(.headerClicked)
        XCTAssertEqual(state.mode, .compactExpanded)
        XCTAssertTrue(compact.compactMode, "Underline stays while peeking")
    }

    /// PR: Underline disappears when Cmd+M toggles compact mode OFF
    func testVisualIndicator_disappearsWhenToggleOff() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        XCTAssertTrue(compact.compactMode)

        send(.cmdM)
        XCTAssertFalse(compact.compactMode, "Underline should disappear")
    }

    // MARK: - Edge cases

    /// PR: Arrow keys, Tab, Return do nothing when compact collapsed
    func testCompactCollapsed_navKeysPassThrough() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)

        for action: PanelNavAction in [.down, .up, .confirm, .toggleTab] {
            let r = send(.navKey(action))
            XCTAssertFalse(r.eventConsumed,
                           "\(action) should pass through in compact collapsed")
            XCTAssertTrue(r.actions.isEmpty,
                          "\(action) should produce no actions in compact collapsed")
        }
    }

    /// PR: Quit while compact → reopen → compact mode persisted
    func testCompactPreference_persistedAcrossInstances() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        XCTAssertTrue(compact.compactMode)

        // Close panel
        send(.menubarIconClicked(appIsActive: true))

        // Simulate a fresh launch: new controller, reads from UserDefaults
        let freshController = CompactModeController()
        let freshState = PanelState(mode: .hidden, compactPreference: freshController.compactMode)
        XCTAssertTrue(freshState.compactPreference,
                       "Compact preference should survive across instances via @AppStorage")

        // Reopen with fresh state
        let r = PanelCoordinator.handle(
            event: .menubarIconClicked(appIsActive: false), state: freshState)
        XCTAssertEqual(r.state.mode, .compactCollapsed,
                       "Fresh launch should open in compact mode")
    }

    /// PR: Refocus from inactive compact → Escape collapses back
    func testCompactInactive_refocus_escape_collapses() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        send(.escape) // → inactive
        XCTAssertEqual(state.mode, .compactInactive)

        send(.refocusShortcut)
        if case .refocus(let origin) = state.mode {
            XCTAssertTrue(origin.wasCompact)
        } else {
            XCTFail("Expected refocus mode")
        }
        XCTAssertFalse(compact.isCompact, "Expanded for refocus")

        send(.escape)
        XCTAssertEqual(state.mode, .compactCollapsed)
        XCTAssertTrue(compact.isCompact, "Collapses back after refocus")
    }

    /// Regression: clicking header while inactive should expand
    func testCompactInactive_headerClick_expands() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        send(.escape) // → inactive
        XCTAssertEqual(state.mode, .compactInactive)

        send(.headerClicked)
        XCTAssertEqual(state.mode, .compactExpanded,
                       "Header click while inactive should expand")
        XCTAssertFalse(compact.isCompact, "Should show full view")
        XCTAssertTrue(compact.compactMode, "Preference stays ON")
    }

    /// PR: Refocus timeout in compact → collapses back
    func testCompactRefocus_timeout_collapsesBack() {
        send(.menubarIconClicked(appIsActive: false))
        send(.cmdM)
        send(.refocusShortcut)

        send(.refocusTimedOut)
        XCTAssertEqual(state.mode, .compactCollapsed)
        XCTAssertTrue(compact.isCompact)
    }
}
