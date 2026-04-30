import XCTest
@testable import CctopMenubar

final class FocusStrategyTests: XCTestCase {

    private let projectPath = "/Users/test/projects/myapp"

    private func makeSession(
        program: String,
        sessionId: String? = nil,
        bundleId: String? = nil,
        socket: String? = nil
    ) -> Session {
        Session.mock(
            id: "test",
            project: "myapp",
            terminal: TerminalInfo(
                program: program, sessionId: sessionId, tty: nil,
                bundleId: bundleId, socket: socket
            )
        )
    }

    // MARK: - Editors use openWithApp (not Process/env)

    func testVSCodeUsesOpenWithApp() {
        let session = makeSession(program: "Code")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .openWithApp(
            bundleID: "com.microsoft.VSCode",
            target: projectPath
        ))
    }

    func testCursorUsesOpenWithApp() {
        let session = makeSession(program: "Cursor")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .openWithApp(
            bundleID: "com.todesktop.230313mzl4w4u92",
            target: projectPath
        ))
    }

    func testWindsurfUsesOpenWithApp() {
        let session = makeSession(program: "Windsurf")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .openWithApp(
            bundleID: "com.codeium.windsurf",
            target: projectPath
        ))
    }

    func testZedUsesOpenWithApp() {
        let session = makeSession(program: "Zed")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .openWithApp(
            bundleID: "dev.zed.Zed",
            target: projectPath
        ))
    }

    // MARK: - Workspace file preferred over project path

    func testEditorPrefersWorkspaceFile() {
        var session = makeSession(program: "Code")
        let wsFile = projectPath + "/app.code-workspace"
        session.workspaceFile = wsFile
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .openWithApp(
            bundleID: "com.microsoft.VSCode",
            target: wsFile
        ))
    }

    // MARK: - iTerm2 uses AppleScript with GUID

    func testITerm2WithGUIDUsesScript() {
        let session = makeSession(
            program: "iTerm2",
            sessionId: "w0t0p0:ABC123-DEF-456"
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .iTerm2(guid: "ABC123-DEF-456"))
    }

    func testITerm2WithoutGUIDFallsBackToActivate() {
        let session = makeSession(program: "iTerm2")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("iterm2"))
    }

    func testITerm2WithInvalidGUIDFallsBackToActivate() {
        let session = makeSession(
            program: "iTerm2",
            sessionId: "w0t0p0:not!valid"
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("iterm2"))
    }

    // MARK: - Kitty uses remote control with socket

    func testKittyWithSocketUsesRemoteControl() {
        let session = makeSession(
            program: "kitty", sessionId: "1",
            bundleId: "net.kovidgoyal.kitty", socket: "unix:/tmp/kitty-1234"
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .kitty(socket: "unix:/tmp/kitty-1234", windowId: "1"))
    }

    func testKittyWithoutSocketFallsBackToActivate() {
        let session = makeSession(
            program: "kitty", sessionId: "1",
            bundleId: "net.kovidgoyal.kitty"
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("kitty"))
    }

    func testKittyWithoutWindowIdFallsBackToActivate() {
        let session = makeSession(
            program: "kitty",
            bundleId: "net.kovidgoyal.kitty", socket: "unix:/tmp/kitty-1234"
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("kitty"))
    }

    func testKittyDetectedByBundleIdWhenProgramDiffers() {
        let session = makeSession(
            program: "zellij", sessionId: "1",
            bundleId: "net.kovidgoyal.kitty", socket: "unix:/tmp/kitty-1234"
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .kitty(socket: "unix:/tmp/kitty-1234", windowId: "1"))
    }

    // MARK: - Other terminals use activate

    func testWarpUsesActivateByName() {
        let session = makeSession(program: "Warp")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("warp"))
    }

    func testGhosttyUsesActivateByName() {
        let session = makeSession(program: "Ghostty")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("ghostty"))
    }

    func testAppleTerminalUsesActivateByName() {
        let session = makeSession(program: "Terminal")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("terminal"))
    }

    // MARK: - No terminal info falls back to Finder

    func testNoTerminalInfoOpensInFinder() {
        let session = Session.mock(id: "test", project: "myapp", terminal: nil)
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .openInFinder(projectPath))
    }

    // MARK: - Unknown program falls back to Finder

    func testUnknownProgramOpensInFinder() {
        let session = makeSession(program: "SomeUnknownApp")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .openInFinder(projectPath))
    }

    // MARK: - extractITermGUID

    func testExtractGUIDFromSessionId() {
        XCTAssertEqual(extractITermGUID(from: "w0t0p0:ABC-123"), "ABC-123")
    }

    func testExtractGUIDFromBareId() {
        XCTAssertEqual(extractITermGUID(from: "ABC-123"), "ABC-123")
    }

    func testExtractGUIDFromNil() {
        XCTAssertNil(extractITermGUID(from: nil))
    }

    func testExtractGUIDFromEmpty() {
        XCTAssertNil(extractITermGUID(from: ""))
    }
}
