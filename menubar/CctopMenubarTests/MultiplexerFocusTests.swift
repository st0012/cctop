import XCTest
@testable import CctopMenubar

final class MultiplexerFocusTests: XCTestCase {

    // MARK: - resolveMultiplexerFocus

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

    // MARK: - MultiplexerInfo Codable round-trip

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
        let info = MultiplexerInfo.zellij(sessionName: "dev", paneId: "1", binaryPath: nil)
        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(MultiplexerInfo.self, from: data)
        XCTAssertEqual(decoded, info)
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
        // zellij inside Ghostty — emulator strategy should still be activateByName
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "Ghostty",
                multiplexer: .zellij(sessionName: "dev", paneId: "terminal_1", binaryPath: "/usr/bin/zellij")
            )
        )
        let emulatorStrategy = resolveFocusStrategy(session: session)
        XCTAssertEqual(emulatorStrategy, .activateByName("ghostty"))

        let muxStrategy = resolveMultiplexerFocus(session: session)
        XCTAssertEqual(muxStrategy, .zellij(sessionName: "dev", paneId: "terminal_1", binaryPath: "/usr/bin/zellij"))
    }
}
