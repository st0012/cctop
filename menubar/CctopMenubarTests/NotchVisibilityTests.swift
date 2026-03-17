import XCTest
@testable import CctopMenubar

final class NotchVisibilityTests: XCTestCase {

    // MARK: - No notch or no built-in screen → tearDown

    func testNoNotchTearDown() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: false, hasBuiltinScreen: true,
            appIsActive: false, pillExists: false, statusItemOccluded: true
        )
        XCTAssertEqual(action, .tearDown)
    }

    func testNoBuiltinScreenTearDown() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: false,
            appIsActive: false, pillExists: false, statusItemOccluded: true
        )
        XCTAssertEqual(action, .tearDown)
    }

    // MARK: - Normal (app not active) — occlusion drives show/tearDown

    func testOccludedShowsPill() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: false, pillExists: false, statusItemOccluded: true
        )
        XCTAssertEqual(action, .show)
    }

    func testNotOccludedTearsDown() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: false, pillExists: true, statusItemOccluded: false
        )
        XCTAssertEqual(action, .tearDown)
    }

    func testNotOccludedNoPillTearsDown() {
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: false, pillExists: false, statusItemOccluded: false
        )
        XCTAssertEqual(action, .tearDown)
    }

    // MARK: - App active with existing pill → keep (the fix)

    func testActiveWithPillKeeps() {
        // Core fix: don't tear down the pill while cctop is active.
        // The menubar is minimal and isStatusItemOccluded is unreliable.
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: true, pillExists: true, statusItemOccluded: false
        )
        XCTAssertEqual(action, .keep)
    }

    func testActiveWithPillKeepsEvenIfOccluded() {
        // Active + pill exists → always keep, regardless of occlusion
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: true, pillExists: true, statusItemOccluded: true
        )
        XCTAssertEqual(action, .keep)
    }

    // MARK: - App active without existing pill → normal check

    func testActiveNoPillOccludedShows() {
        // No pill yet but occluded → show it
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: true, pillExists: false, statusItemOccluded: true
        )
        XCTAssertEqual(action, .show)
    }

    func testActiveNoPillNotOccludedTearsDown() {
        // No pill and not occluded → don't create one
        let action = NotchStatusController.resolveVisibility(
            hasNotch: true, hasBuiltinScreen: true,
            appIsActive: true, pillExists: false, statusItemOccluded: false
        )
        XCTAssertEqual(action, .tearDown)
    }
}
