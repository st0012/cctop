import XCTest
@testable import CctopMenubar

final class MenubarIconRendererTests: XCTestCase {
    // MARK: - Zero sessions (template icon)

    func testZeroSessions_returnsTemplateImage() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 0, attention: 0, working: 0, idle: 0)
        )
        XCTAssertTrue(image.isTemplate, "Zero-session icon should be a template image")
    }

    // MARK: - Dimensions

    func testIconSize() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 0, attention: 0, working: 1, idle: 0)
        )
        XCTAssertEqual(image.size.width, 44, "Icon should be 44px wide")
        XCTAssertEqual(image.size.height, 18, "Icon should be 18px tall")
        XCTAssertFalse(image.isTemplate, "Active-session icon should not be template")
    }

    // MARK: - Non-template when sessions active

    func testPermissionSession_notTemplate() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 1, attention: 0, working: 0, idle: 0)
        )
        XCTAssertFalse(image.isTemplate)
    }

    func testAttentionSession_notTemplate() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 0, attention: 2, working: 0, idle: 0)
        )
        XCTAssertFalse(image.isTemplate)
    }

    func testMixedSessions_notTemplate() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 1, attention: 1, working: 2, idle: 3)
        )
        XCTAssertFalse(image.isTemplate)
    }

    func testIdleOnly_notTemplate() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 0, attention: 0, working: 0, idle: 5)
        )
        XCTAssertFalse(image.isTemplate)
    }

    // MARK: - Valid image output

    func testRenderProducesNonEmptyImage() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 1, attention: 0, working: 2, idle: 1)
        )
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }

    // MARK: - Single session

    func testSingleWorkingSession_correctSize() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 0, attention: 0, working: 1, idle: 0)
        )
        XCTAssertEqual(image.size.width, 44)
        XCTAssertEqual(image.size.height, 18)
        XCTAssertFalse(image.isTemplate)
    }

    func testSinglePermissionSession_correctSize() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 1, attention: 0, working: 0, idle: 0)
        )
        XCTAssertEqual(image.size.width, 44)
        XCTAssertEqual(image.size.height, 18)
        XCTAssertFalse(image.isTemplate)
    }
}
