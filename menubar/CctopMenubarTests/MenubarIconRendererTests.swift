import XCTest
@testable import CctopMenubar

final class MenubarIconRendererTests: XCTestCase {
    // MARK: - Zero sessions (template icon)

    func testZeroSessions_returnsTemplateImage() {
        let image = MenubarIconRenderer.render(
            permission: 0, attention: 0, working: 0, idle: 0, wide: true
        )
        XCTAssertTrue(image.isTemplate, "Zero-session icon should be a template image")
    }

    // MARK: - Wide mode dimensions

    func testWideModeSize() {
        let image = MenubarIconRenderer.render(
            permission: 0, attention: 0, working: 1, idle: 0, wide: true
        )
        XCTAssertEqual(image.size.width, 44, "Wide icon should be 44px wide")
        XCTAssertEqual(image.size.height, 18, "Wide icon should be 18px tall")
        XCTAssertFalse(image.isTemplate, "Active-session icon should not be template")
    }

    // MARK: - Narrow mode dimensions

    func testNarrowModeSize() {
        let image = MenubarIconRenderer.render(
            permission: 0, attention: 0, working: 1, idle: 0, wide: false
        )
        XCTAssertEqual(image.size.width, 18, "Narrow icon should be 18px wide")
        XCTAssertEqual(image.size.height, 18, "Narrow icon should be 18px tall")
    }

    // MARK: - Non-template when sessions active

    func testPermissionSession_notTemplate() {
        let image = MenubarIconRenderer.render(
            permission: 1, attention: 0, working: 0, idle: 0, wide: true
        )
        XCTAssertFalse(image.isTemplate)
    }

    func testAttentionSession_notTemplate() {
        let image = MenubarIconRenderer.render(
            permission: 0, attention: 2, working: 0, idle: 0, wide: true
        )
        XCTAssertFalse(image.isTemplate)
    }

    func testMixedSessions_notTemplate() {
        let image = MenubarIconRenderer.render(
            permission: 1, attention: 1, working: 2, idle: 3, wide: true
        )
        XCTAssertFalse(image.isTemplate)
    }

    func testIdleOnly_notTemplate() {
        let image = MenubarIconRenderer.render(
            permission: 0, attention: 0, working: 0, idle: 5, wide: true
        )
        XCTAssertFalse(image.isTemplate)
    }

    // MARK: - Valid image output

    func testRenderProducesNonEmptyImage() {
        let image = MenubarIconRenderer.render(
            permission: 1, attention: 0, working: 2, idle: 1, wide: true
        )
        XCTAssertGreaterThan(image.size.width, 0)
        XCTAssertGreaterThan(image.size.height, 0)
    }
}
