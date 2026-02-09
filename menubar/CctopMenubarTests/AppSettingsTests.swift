import XCTest
@testable import CctopMenubar

final class AppSettingsTests: XCTestCase {
    func testAppearanceModeRawValues() {
        XCTAssertEqual(AppearanceMode.system.rawValue, "system")
        XCTAssertEqual(AppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppearanceMode.dark.rawValue, "dark")
    }

    func testAppearanceModeLabels() {
        XCTAssertEqual(AppearanceMode.system.label, "System")
        XCTAssertEqual(AppearanceMode.light.label, "Light")
        XCTAssertEqual(AppearanceMode.dark.label, "Dark")
    }

    func testAllCasesOrder() {
        let cases = AppearanceMode.allCases
        XCTAssertEqual(cases, [.system, .light, .dark])
    }
}
