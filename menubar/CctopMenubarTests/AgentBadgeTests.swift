import XCTest
@testable import CctopMenubar

final class AgentBadgeTests: XCTestCase {
    func testExplicitCC_returnsCC() {
        let session = Session.mock(source: "cc")
        XCTAssertEqual(session.agentBadge, .cc)
    }

    func testLegacyNilSource_withoutDesktopBundle_returnsCC() {
        let session = Session.mock(
            terminal: TerminalInfo(program: "Code", bundleId: "com.microsoft.VSCode"),
            source: nil
        )
        XCTAssertEqual(session.agentBadge, .cc)
    }

    func testClaudeDesktopBundle_withNilSource_returnsClaudeDesktop() {
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.anthropic.claudefordesktop"),
            source: nil
        )
        XCTAssertEqual(session.agentBadge, .claudeDesktop)
    }

    func testClaudeDesktopBundle_withExplicitCCSource_returnsClaudeDesktop() {
        // Defensive: if Claude Desktop ever starts setting `source: "cc"`,
        // the bundle ID should still win and classify as Desktop.
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.anthropic.claudefordesktop"),
            source: "cc"
        )
        XCTAssertEqual(session.agentBadge, .claudeDesktop)
    }

    func testCodexSource_withTerminalBundle_returnsCodex() {
        let session = Session.mock(
            terminal: TerminalInfo(program: "iTerm", bundleId: "com.googlecode.iterm2"),
            source: "codex"
        )
        XCTAssertEqual(session.agentBadge, .codex)
    }

    func testCodexSource_withCodexDesktopBundle_returnsCodexDesktop() {
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.openai.codex"),
            source: "codex"
        )
        XCTAssertEqual(session.agentBadge, .codexDesktop)
    }

    func testCodexDesktopBundle_withNilSource_returnsCodexDesktop() {
        // Regression: previously, (nil source, isDesktop=true) was hard-coded to
        // .claudeDesktop. A Codex Desktop session whose harness_name didn't
        // make it into the hook payload would be mislabelled. The bundle ID
        // should always win.
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.openai.codex"),
            source: nil
        )
        XCTAssertEqual(session.agentBadge, .codexDesktop)
    }

    func testCodexDesktopBundle_overridesMismatchedSource() {
        // Defensive: bundle ID wins even if source disagrees. Shouldn't happen
        // in practice, but guarantees the visual classification matches the
        // host app the user actually sees on screen.
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.openai.codex"),
            source: "cc"
        )
        XCTAssertEqual(session.agentBadge, .codexDesktop)
    }

    func testClaudeDesktopBundle_overridesMismatchedSource() {
        let session = Session.mock(
            terminal: TerminalInfo(bundleId: "com.anthropic.claudefordesktop"),
            source: "codex"
        )
        XCTAssertEqual(session.agentBadge, .claudeDesktop)
    }

    func testOpencodeSource_returnsOpencode() {
        let session = Session.mock(source: "opencode")
        XCTAssertEqual(session.agentBadge, .opencode)
    }

    func testPiSource_returnsPi() {
        let session = Session.mock(source: "pi")
        XCTAssertEqual(session.agentBadge, .pi)
    }

    func testIsDesktop_onlyTrueForDesktopVariants() {
        XCTAssertFalse(AgentBadge.cc.isDesktop)
        XCTAssertTrue(AgentBadge.claudeDesktop.isDesktop)
        XCTAssertFalse(AgentBadge.codex.isDesktop)
        XCTAssertTrue(AgentBadge.codexDesktop.isDesktop)
        XCTAssertFalse(AgentBadge.opencode.isDesktop)
        XCTAssertFalse(AgentBadge.pi.isDesktop)
    }

    func testLabel_matchesUIExpectation() {
        XCTAssertEqual(AgentBadge.cc.label, "CC")
        XCTAssertEqual(AgentBadge.claudeDesktop.label, "Claude Desktop")
        XCTAssertEqual(AgentBadge.codex.label, "Codex")
        XCTAssertEqual(AgentBadge.codexDesktop.label, "Codex Desktop")
        XCTAssertEqual(AgentBadge.opencode.label, "OC")
        XCTAssertEqual(AgentBadge.pi.label, "Pi")
    }
}
