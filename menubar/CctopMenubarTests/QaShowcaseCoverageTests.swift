import XCTest
@testable import CctopMenubar

final class QaShowcaseCoverageTests: XCTestCase {
    func testShowcaseCoversAllFourAgentBadgeVariants() {
        let badges = Set(Session.qaShowcase.map { $0.agentBadge })
        XCTAssertTrue(badges.contains(.cc), "qaShowcase should include a CC session")
        XCTAssertTrue(badges.contains(.claudeDesktop), "qaShowcase should include a Claude Desktop session")
        XCTAssertTrue(badges.contains(.codex), "qaShowcase should include a Codex CLI session")
        XCTAssertTrue(badges.contains(.codexDesktop), "qaShowcase should include a Codex Desktop session")
    }

    func testShowcaseHasMixOfStatuses() {
        let statuses = Set(Session.qaShowcase.map { $0.status })
        XCTAssertTrue(statuses.contains(.working), "qaShowcase should include a working session")
        XCTAssertTrue(statuses.contains(.idle), "qaShowcase should include an idle session")
        let hasWaiting = statuses.contains(.waitingInput)
            || statuses.contains(.waitingPermission)
            || statuses.contains(.needsAttention)
        XCTAssertTrue(hasWaiting, "qaShowcase should include at least one waiting/attention session")
    }
}
