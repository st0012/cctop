import XCTest
@testable import CctopMenubar

final class FocusStrategyTests: XCTestCase {

    private let projectPath = "/Users/test/projects/myapp"

    private func makeSession(
        program: String,
        sessionId: String? = nil,
        tty: String? = nil,
        bundleId: String? = nil,
        socket: String? = nil,
        binaryPaths: [String: String]? = nil,
        sessionUuid: String = "test"
    ) -> Session {
        Session.mock(
            id: sessionUuid,
            project: "myapp",
            terminal: TerminalInfo(
                program: program, sessionId: sessionId, tty: tty,
                bundleId: bundleId, socket: socket,
                binaryPaths: binaryPaths
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
            bundleId: "net.kovidgoyal.kitty", socket: "unix:/tmp/kitty-1234",
            binaryPaths: ["kitty": "/opt/homebrew/bin/kitty"]
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .kitty(
            socket: "unix:/tmp/kitty-1234", windowId: "1", binaryPath: "/opt/homebrew/bin/kitty"
        ))
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
            bundleId: "net.kovidgoyal.kitty", socket: "unix:/tmp/kitty-1234",
            binaryPaths: ["kitty": "/opt/homebrew/bin/kitty"]
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("kitty"))
    }

    func testKittyWithoutBinaryPathFallsBackToActivate() {
        let session = makeSession(
            program: "kitty", sessionId: "1",
            bundleId: "net.kovidgoyal.kitty", socket: "unix:/tmp/kitty-1234"
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("kitty"))
    }

    func testKittyDetectedByBundleIdWhenProgramDiffers() {
        let session = makeSession(
            program: "zellij", sessionId: "1",
            bundleId: "net.kovidgoyal.kitty", socket: "unix:/tmp/kitty-1234",
            binaryPaths: ["kitty": "/opt/homebrew/bin/kitty"]
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .kitty(
            socket: "unix:/tmp/kitty-1234", windowId: "1", binaryPath: "/opt/homebrew/bin/kitty"
        ))
    }

    // MARK: - Other terminals use activate

    func testWarpUsesActivateByName() {
        let session = makeSession(program: "Warp")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("warp"))
    }

    func testGhosttyUsesAppleScriptWithWorkingDirectory() {
        let session = makeSession(program: "Ghostty")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .ghostty(workingDirectory: projectPath))
    }

    func testGhosttyDetectedByBundleIdWhenProgramDiffers() {
        // User runs a multiplexer (e.g. tmux) inside Ghostty — TERM_PROGRAM may not
        // say "ghostty", but __CFBundleIdentifier still does.
        let session = makeSession(program: "tmux", bundleId: "com.mitchellh.ghostty")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .ghostty(workingDirectory: projectPath))
    }

    // MARK: - AppleScript path escaping

    func testGhosttyEscapesQuotesInPath() {
        XCTAssertEqual(
            escapeAppleScriptString(#"/Users/test/has"quote"#),
            #"/Users/test/has\"quote"#
        )
    }

    func testGhosttyEscapesBackslashesInPath() {
        XCTAssertEqual(
            escapeAppleScriptString(#"/Users/test/back\slash"#),
            #"/Users/test/back\\slash"#
        )
    }

    func testGhosttyEscapesBackslashesBeforeQuotes() {
        // Backslashes must be escaped first; otherwise the second pass would
        // re-escape the backslashes we just inserted to escape quotes.
        XCTAssertEqual(
            escapeAppleScriptString(#"a\b"c"#),
            #"a\\b\"c"#
        )
    }

    // MARK: - Apple Terminal uses AppleScript with tty

    func testAppleTerminalWithTTYUsesScript() {
        let session = makeSession(program: "Apple_Terminal", tty: "/dev/ttys003")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .appleTerminal(tty: "/dev/ttys003"))
    }

    func testAppleTerminalDetectedByBundleIdWhenProgramDiffers() {
        // User runs a multiplexer (e.g. tmux) inside Terminal — TERM_PROGRAM may not
        // say "Apple_Terminal", but __CFBundleIdentifier still does.
        let session = makeSession(program: "tmux", tty: "/dev/ttys007", bundleId: "com.apple.Terminal")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .appleTerminal(tty: "/dev/ttys007"))
    }

    func testAppleTerminalWithoutTTYFallsBackToActivate() {
        let session = makeSession(program: "Terminal")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("terminal"))
    }

    func testAppleTerminalWithInvalidTTYFallsBackToActivate() {
        // Anything not matching /dev/ttys\d+ is rejected to keep AppleScript interpolation safe.
        let session = makeSession(program: "Terminal", tty: "/dev/cu.usb\"oops")
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByName("terminal"))
    }

    // MARK: - Desktop AI apps

    func testClaudeDesktopUsesActivateByBundleID() {
        // Claude Desktop has a claude://resume?session=... URL but it FORKS the
        // conversation instead of focusing it — destructive, so we deliberately
        // fall through to plain bundle-ID activation. See HostApp.sessionDeepLink.
        let bundleID = HostApp.claudeDesktop.bundleID!
        let session = makeSession(
            program: "", bundleId: bundleID,
            sessionUuid: "002fb6fa-eae0-4631-94bd-84071dbd21d8"
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByBundleID(bundleID))
    }

    func testCodexDesktopUsesDeepLinkWhenSessionIdIsUUID() {
        // Codex's URL handler routes codex://threads/<uuid> to the conversation
        // and rejects anything that's not a canonical UUID — we mirror that check.
        let uuid = "019e1eff-3374-74b0-8d3d-6fba94e7d75f"
        let session = makeSession(
            program: "", bundleId: HostApp.codexDesktop.bundleID!, sessionUuid: uuid
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .openURL(URL(string: "codex://threads/\(uuid)")!))
    }

    func testCodexDesktopFallsBackToActivateWhenSessionIdNotUUID() {
        // Legacy or test sessions may not have UUID IDs — we should still focus
        // the app rather than build a URL the handler will reject.
        let bundleID = HostApp.codexDesktop.bundleID!
        let session = makeSession(
            program: "", bundleId: bundleID, sessionUuid: "not-a-uuid"
        )
        let strategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(strategy, .activateByBundleID(bundleID))
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

    // MARK: - OSC 7 builder

    func testBuildOSC7WrapsPathInEscBELFrame() {
        let osc = buildOSC7CWD(host: "machine.local", workingDirectory: "/Users/me/code")
        XCTAssertEqual(osc, "\u{1B}]7;file://machine.local/Users/me/code\u{07}")
    }

    func testBuildOSC7URLEncodesSpaces() {
        let osc = buildOSC7CWD(host: "h", workingDirectory: "/Users/me/My Code")
        XCTAssertEqual(osc, "\u{1B}]7;file://h/Users/me/My%20Code\u{07}")
    }

    func testBuildOSC7PreservesPathSeparators() {
        // Path separators must not be percent-encoded — Ghostty parses this as a URI.
        let osc = buildOSC7CWD(host: "h", workingDirectory: "/a/b/c")
        XCTAssertEqual(osc, "\u{1B}]7;file://h/a/b/c\u{07}")
    }

    func testBuildOSC7EmptyHostAllowed() {
        // file:///path is valid (empty authority). Some terminals only care about path.
        let osc = buildOSC7CWD(host: "", workingDirectory: "/x")
        XCTAssertEqual(osc, "\u{1B}]7;file:///x\u{07}")
    }
}
