import XCTest
@testable import CctopMenubar

final class MultiplexerFocusTests: XCTestCase {

    private let workspaceUUID = "11111111-1111-1111-1111-111111111111"
    private let surfaceUUID = "22222222-2222-2222-2222-222222222222"
    private let paneUUID = "33333333-3333-3333-3333-333333333333"

    // MARK: - resolveMultiplexerFocus

    func testCmuxUUIDSurfaceUsesNavigationURL() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "ghostty",
                multiplexer: .cmux(
                    socket: "/tmp/cmux.sock",
                    workspaceId: workspaceUUID,
                    surfaceId: surfaceUUID,
                    paneId: nil,
                    binaryPath: "/usr/local/bin/cmux"
                )
            )
        )
        let expectedURL = URL(string: "cmux://workspace/\(workspaceUUID)/surface/\(surfaceUUID)")!

        XCTAssertEqual(
            cmuxNavigationURL(multiplexer: session.terminal?.multiplexer),
            expectedURL
        )
        XCTAssertEqual(resolveFocusStrategy(session: session), .openURL(expectedURL))
        if case .openURL(_, let restoreBundleID) = resolveFocusStrategy(session: session) {
            XCTAssertNil(restoreBundleID)
        } else {
            XCTFail("Expected cmux navigation URL strategy")
        }
        XCTAssertNil(resolveMultiplexerFocus(session: session))
    }

    func testCmuxUUIDPaneUsesNavigationURL() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "ghostty",
                multiplexer: .cmux(
                    socket: "/tmp/cmux.sock",
                    workspaceId: workspaceUUID,
                    surfaceId: nil,
                    paneId: paneUUID,
                    binaryPath: "/usr/local/bin/cmux"
                )
            )
        )
        let expectedURL = URL(string: "cmux://workspace/\(workspaceUUID)/pane/\(paneUUID)")!

        XCTAssertEqual(
            cmuxNavigationURL(multiplexer: session.terminal?.multiplexer),
            expectedURL
        )
        XCTAssertEqual(resolveFocusStrategy(session: session), .openURL(expectedURL))
        XCTAssertNil(resolveMultiplexerFocus(session: session))
    }

    func testCmuxReturnsSurfaceCliFallbackForReferenceIds() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "ghostty",
                multiplexer: .cmux(
                    socket: "/tmp/cmux.sock",
                    workspaceId: "workspace:1",
                    surfaceId: "surface:2",
                    paneId: nil,
                    binaryPath: "/usr/local/bin/cmux"
                )
            )
        )

        XCTAssertNil(cmuxNavigationURL(multiplexer: session.terminal?.multiplexer))
        XCTAssertEqual(
            resolveMultiplexerFocus(session: session),
            .cmux(
                socket: "/tmp/cmux.sock",
                workspaceId: "workspace:1",
                surfaceId: "surface:2",
                paneId: nil,
                binaryPath: "/usr/local/bin/cmux"
            )
        )
    }

    func testCmuxReferencePaneWithoutSurfaceReturnsNil() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "ghostty",
                multiplexer: .cmux(
                    socket: "/tmp/cmux.sock",
                    workspaceId: "workspace:1",
                    surfaceId: nil,
                    paneId: "pane:2",
                    binaryPath: "/usr/local/bin/cmux"
                )
            )
        )
        XCTAssertNil(cmuxNavigationURL(multiplexer: session.terminal?.multiplexer))
        XCTAssertNil(resolveMultiplexerFocus(session: session))
    }

    func testLegacyCmuxSessionUsesLiveProcessEnvironmentForNavigationURL() {
        let session = Session.mock(
            project: "irb",
            pid: 5079,
            terminal: TerminalInfo(
                program: "ghostty",
                tty: "/dev/ttys010",
                bundleId: "com.cmuxterm.app"
            )
        )
        let env = [
            "CMUX_SOCKET_PATH": "/Users/test/.local/state/cmux/cmux.sock",
            "CMUX_WORKSPACE_ID": workspaceUUID,
            "CMUX_SURFACE_ID": surfaceUUID,
            "CMUX_BUNDLED_CLI_PATH": "/bin/echo"
        ]
        let multiplexer = resolveCmuxLiveMultiplexer(session: session) { pid in
            XCTAssertEqual(pid, 5079)
            return env
        }
        let expectedURL = URL(string: "cmux://workspace/\(workspaceUUID)/surface/\(surfaceUUID)")!

        XCTAssertEqual(cmuxNavigationURL(multiplexer: multiplexer), expectedURL)
        XCTAssertEqual(
            resolveFocusStrategy(session: session, multiplexerOverride: multiplexer),
            .openURL(expectedURL)
        )
        XCTAssertNil(resolveMultiplexerFocus(session: session, multiplexerOverride: multiplexer))
    }

    func testCmuxEnvironmentExtractionParsesProcessEnvironment() {
        let psOutput = """
        PID TT STAT COMMAND
        5079 s010 S+ claude CMUX_SOCKET_PATH=/Users/test/.local/state/cmux/cmux.sock \
        CMUX_WORKSPACE_ID=\(workspaceUUID) CMUX_SURFACE_ID=\(surfaceUUID) \
        CMUX_BUNDLED_CLI_PATH=/Applications/cmux.app/Contents/Resources/bin/cmux GIT_EDITOR=code --wait
        """
        let env = extractCmuxEnvironment(from: psOutput)

        XCTAssertEqual(env["CMUX_SOCKET_PATH"], "/Users/test/.local/state/cmux/cmux.sock")
        XCTAssertEqual(env["CMUX_WORKSPACE_ID"], workspaceUUID)
        XCTAssertEqual(env["CMUX_SURFACE_ID"], surfaceUUID)
        XCTAssertEqual(env["CMUX_BUNDLED_CLI_PATH"], "/Applications/cmux.app/Contents/Resources/bin/cmux")
    }

    func testZellijReturnsStrategy() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "Ghostty",
                multiplexer: .zellij(sessionName: "dev", paneId: "terminal_3", binaryPath: "/usr/bin/zellij")
            )
        )
        let strategy = resolveMultiplexerFocus(session: session)
        XCTAssertEqual(strategy, .zellij(sessionName: "dev", paneId: "terminal_3", binaryPath: "/usr/bin/zellij"))
    }

    func testTmuxReturnsStrategy() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "Ghostty",
                multiplexer: .tmux(socket: "/tmp/tmux-501/default", paneId: "%3", binaryPath: "/opt/homebrew/bin/tmux")
            )
        )
        let strategy = resolveMultiplexerFocus(session: session)
        XCTAssertEqual(
            strategy,
            .tmux(socket: "/tmp/tmux-501/default", paneId: "%3", binaryPath: "/opt/homebrew/bin/tmux")
        )
    }

    func testNoBinaryPathReturnsNil() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "Ghostty",
                multiplexer: .zellij(sessionName: "dev", paneId: "terminal_3", binaryPath: nil)
            )
        )
        let strategy = resolveMultiplexerFocus(session: session)
        XCTAssertNil(strategy)
    }

    func testCmuxWithoutSurfaceOrPaneReturnsNil() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "ghostty",
                multiplexer: .cmux(
                    socket: "/tmp/cmux.sock",
                    workspaceId: "workspace:1",
                    surfaceId: nil,
                    paneId: nil,
                    binaryPath: "/usr/local/bin/cmux"
                )
            )
        )
        let strategy = resolveMultiplexerFocus(session: session)
        XCTAssertNil(strategy)
    }

    func testNoMultiplexerReturnsNil() {
        let session = Session.mock(
            terminal: TerminalInfo(program: "Ghostty")
        )
        let strategy = resolveMultiplexerFocus(session: session)
        XCTAssertNil(strategy)
    }

    func testNoTerminalReturnsNil() {
        let session = Session.mock(terminal: nil)
        let strategy = resolveMultiplexerFocus(session: session)
        XCTAssertNil(strategy)
    }

    // MARK: - cmux CLI fallback arguments

    func testCmuxFocusArgumentsUseDocumentedSurfaceCommand() {
        XCTAssertEqual(
            cmuxFocusArguments(
                socket: "/tmp/cmux.sock",
                workspaceId: "workspace:1",
                surfaceId: "surface:2",
                paneId: nil
            ),
            [
                "--socket", "/tmp/cmux.sock",
                "focus-surface",
                "--workspace", "workspace:1",
                "--surface", "surface:2"
            ]
        )
    }

    func testCmuxFocusArgumentsRequireSurfaceId() {
        XCTAssertNil(
            cmuxFocusArguments(
                socket: "/tmp/cmux.sock",
                workspaceId: "workspace:1",
                surfaceId: nil,
                paneId: "pane:2"
            )
        )
    }

    // MARK: - MultiplexerInfo Codable round-trip

    func testCmuxCodableRoundTrip() throws {
        let info = MultiplexerInfo.cmux(
            socket: "/tmp/cmux.sock",
            workspaceId: "workspace:1",
            surfaceId: "surface:2",
            paneId: "pane:3",
            binaryPath: "/usr/local/bin/cmux"
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(MultiplexerInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testZellijCodableRoundTrip() throws {
        let info = MultiplexerInfo.zellij(sessionName: "amzn", paneId: "42", binaryPath: "/usr/bin/zellij")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(MultiplexerInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testTmuxCodableRoundTrip() throws {
        let info = MultiplexerInfo.tmux(socket: "/tmp/tmux-501/default", paneId: "%3", binaryPath: "/opt/homebrew/bin/tmux")
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(MultiplexerInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testNilBinaryPathCodableRoundTrip() throws {
        let info = MultiplexerInfo.cmux(
            socket: "/tmp/cmux.sock",
            workspaceId: "workspace:1",
            surfaceId: "surface:2",
            paneId: nil,
            binaryPath: nil
        )
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(MultiplexerInfo.self, from: data)
        XCTAssertEqual(decoded, info)
    }

    func testCmuxJSONShape() throws {
        let info = MultiplexerInfo.cmux(
            socket: "/tmp/cmux.sock",
            workspaceId: "workspace:1",
            surfaceId: "surface:2",
            paneId: "pane:3",
            binaryPath: "/usr/local/bin/cmux"
        )
        let data = try JSONEncoder().encode(info)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(json?["name"], "cmux")
        XCTAssertEqual(json?["socket"], "/tmp/cmux.sock")
        XCTAssertEqual(json?["workspace_id"], "workspace:1")
        XCTAssertEqual(json?["surface_id"], "surface:2")
        XCTAssertEqual(json?["pane_id"], "pane:3")
        XCTAssertEqual(json?["binary_path"], "/usr/local/bin/cmux")
        XCTAssertNil(json?["session_name"])
    }

    func testZellijJSONShape() throws {
        let info = MultiplexerInfo.zellij(sessionName: "dev", paneId: "terminal_1", binaryPath: "/usr/bin/zellij")
        let data = try JSONEncoder().encode(info)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(json?["name"], "zellij")
        XCTAssertEqual(json?["session_name"], "dev")
        XCTAssertEqual(json?["pane_id"], "terminal_1")
        XCTAssertEqual(json?["binary_path"], "/usr/bin/zellij")
        XCTAssertNil(json?["socket"])
    }

    func testTmuxJSONShape() throws {
        let info = MultiplexerInfo.tmux(socket: "/tmp/tmux-501/default", paneId: "%3", binaryPath: "/opt/homebrew/bin/tmux")
        let data = try JSONEncoder().encode(info)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: String]
        XCTAssertEqual(json?["name"], "tmux")
        XCTAssertEqual(json?["socket"], "/tmp/tmux-501/default")
        XCTAssertEqual(json?["pane_id"], "%3")
        XCTAssertEqual(json?["binary_path"], "/opt/homebrew/bin/tmux")
        XCTAssertNil(json?["session_name"])
    }

    func testUnknownMultiplexerFailsDecode() {
        let json = #"{"name":"screen","pane_id":"1"}"#
        let data = json.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(MultiplexerInfo.self, from: data))
    }

    // MARK: - Multiplexer focus is independent of emulator focus

    func testEmulatorStrategyUnaffectedByMultiplexer() {
        // zellij inside Ghostty — emulator strategy and multiplexer focus are
        // resolved independently from the same session.
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "Ghostty",
                multiplexer: .zellij(sessionName: "dev", paneId: "terminal_1", binaryPath: "/usr/bin/zellij")
            )
        )
        let emulatorStrategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(emulatorStrategy, .ghostty(GhosttyFocusTarget(
            tty: nil,
            matchDirectory: "/Users/test/projects/cctop",
            restoreDirectory: nil
        )))

        let muxStrategy = resolveMultiplexerFocus(session: session)
        XCTAssertEqual(muxStrategy, .zellij(sessionName: "dev", paneId: "terminal_1", binaryPath: "/usr/bin/zellij"))
    }

    func testCmuxMultiplexerResolvesCmuxHostDespiteGhosttyProgram() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "ghostty",
                multiplexer: .cmux(
                    socket: "/tmp/cmux.sock",
                    workspaceId: "workspace:1",
                    surfaceId: "surface:2",
                    paneId: nil,
                    binaryPath: "/usr/local/bin/cmux"
                )
            )
        )

        let emulatorStrategy = resolveFocusStrategy(session: session)

        XCTAssertEqual(emulatorStrategy, .activateByName("cmux"))
    }
}
