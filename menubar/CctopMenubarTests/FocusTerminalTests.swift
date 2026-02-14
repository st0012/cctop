import XCTest
@testable import CctopMenubar

final class FocusTerminalTests: XCTestCase {

    // MARK: - GUID extraction: standard format

    func testGUIDExtractionStandardFormat() {
        let result = extractITermGUID(from: "w0t0p0:2A4B6C8D-1234-5678-9ABC-DEF012345678")
        XCTAssertEqual(result, "2A4B6C8D-1234-5678-9ABC-DEF012345678")
    }

    func testGUIDExtractionDifferentWindowTabPane() {
        let result = extractITermGUID(from: "w3t1p2:SOME-GUID-HERE")
        XCTAssertEqual(result, "SOME-GUID-HERE")
    }

    // MARK: - GUID extraction: edge cases

    func testGUIDExtractionNoColon() {
        let result = extractITermGUID(from: "just-a-plain-guid")
        XCTAssertEqual(result, "just-a-plain-guid")
    }

    func testGUIDExtractionNilInput() {
        let result = extractITermGUID(from: nil)
        XCTAssertNil(result)
    }

    func testGUIDExtractionEmptyString() {
        let result = extractITermGUID(from: "")
        XCTAssertNil(result)
    }

    func testGUIDExtractionMultipleColons() {
        // split(separator: ":").last gives the part after the last colon
        let result = extractITermGUID(from: "w0t0p0:some:complex:id")
        XCTAssertEqual(result, "id")
    }

    // MARK: - Session.mock() terminal parameter

    func testMockDefaultTerminalIsCode() {
        let session = Session.mock()
        XCTAssertEqual(session.terminal?.program, "Code")
        XCTAssertNil(session.terminal?.sessionId)
    }

    func testMockWithITerm2Terminal() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "iTerm.app",
                sessionId: "w0t0p0:TEST-GUID",
                tty: "/dev/ttys001"
            )
        )
        XCTAssertEqual(session.terminal?.program, "iTerm.app")
        XCTAssertEqual(session.terminal?.sessionId, "w0t0p0:TEST-GUID")
        XCTAssertEqual(session.terminal?.tty, "/dev/ttys001")
    }

    func testMockWithNilTerminal() {
        let session = Session.mock(terminal: nil)
        XCTAssertNil(session.terminal)
    }
}
