import XCTest
@testable import CctopMenubar

@MainActor
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
        XCTAssertEqual(image.size.width, 36, "Icon should be 36px wide")
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

    func testLiveImageResolvesStatusColorForCurrentDrawingAppearance() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 0, attention: 0, working: 1, idle: 0)
        )
        let darkAppearance = NSAppearance(named: .darkAqua)!
        let lightAppearance = NSAppearance(named: .aqua)!

        let darkPixel = centerPixel(in: image, appearance: darkAppearance)
        let lightPixel = centerPixel(in: image, appearance: lightAppearance)

        assertColor(darkPixel, equals: StatusColors.color(for: .working, appearance: darkAppearance))
        assertColor(lightPixel, equals: StatusColors.color(for: .working, appearance: lightAppearance))
        XCTAssertNotEqual(sRGBComponents(darkPixel), sRGBComponents(lightPixel))
    }

    // MARK: - Single session

    func testSingleWorkingSession_correctSize() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 0, attention: 0, working: 1, idle: 0)
        )
        XCTAssertEqual(image.size.width, 36)
        XCTAssertEqual(image.size.height, 18)
        XCTAssertFalse(image.isTemplate)
    }

    func testSinglePermissionSession_correctSize() {
        let image = MenubarIconRenderer.render(
            counts: StatusCounts(permission: 1, attention: 0, working: 0, idle: 0)
        )
        XCTAssertEqual(image.size.width, 36)
        XCTAssertEqual(image.size.height, 18)
        XCTAssertFalse(image.isTemplate)
    }

    private func centerPixel(in image: NSImage, appearance: NSAppearance) -> NSColor {
        let width = Int(image.size.width)
        let height = Int(image.size.height)
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        appearance.performAsCurrentDrawingAppearance {
            image.draw(
                in: NSRect(origin: .zero, size: image.size),
                from: .zero,
                operation: .copy,
                fraction: 1
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.colorAt(x: width / 2, y: height / 2)!
    }

    private func assertColor(
        _ actual: NSColor,
        equals expected: NSColor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actualComponents = sRGBComponents(actual)
        let expectedComponents = sRGBComponents(expected)
        for index in actualComponents.indices {
            XCTAssertEqual(actualComponents[index], expectedComponents[index], accuracy: 0.001, file: file, line: line)
        }
    }

    private func sRGBComponents(_ color: NSColor) -> [CGFloat] {
        let color = color.usingColorSpace(.sRGB) ?? color
        return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
    }
}
