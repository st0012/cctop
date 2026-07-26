import XCTest
@testable import CctopMenubar

final class SessionDisplayPolicyTests: XCTestCase {
    func testActiveSessionsExcludesDormantAndStaleActiveIdle() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval + 60)),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
            dormant(id: "dormant"),
            activeWaiting(id: "waiting", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
        ]

        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: sessions, now: now).map(\.id), ["fresh", "waiting"])
    }

    func testIdleSessionsIncludesDormantAndStaleActiveIdleOnly() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval + 60)),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
            dormant(id: "dormant"),
            activeWaiting(id: "waiting", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
        ]

        XCTAssertEqual(SessionDisplayPolicy.idleSessions(from: sessions, now: now).map(\.id), ["stale", "dormant"])
    }

    func testSignatureTracksDisplayBuckets() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval + 60)),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
            dormant(id: "dormant"),
        ]

        XCTAssertEqual(
            SessionDisplayPolicy.signature(for: sessions, now: now),
            .init(activeIDs: ["fresh"], idleIDs: ["stale", "dormant"])
        )
    }

    func testReconciledActiveOrderPreservesExistingPositionsAcrossPayloadUpdates() {
        let now = Date(timeIntervalSince1970: 10_000)
        var alpha = Session.mock(id: "alpha", status: .working, lastTool: "Read", lastToolDetail: "old")
        alpha.lastActivity = now.addingTimeInterval(-300)
        var beta = Session.mock(id: "beta", status: .waitingInput, notificationMessage: "old")
        beta.lastActivity = now.addingTimeInterval(-200)
        let previous = [beta, alpha]

        alpha.status = .waitingPermission
        alpha.lastActivity = now
        alpha.notificationMessage = "Approve command"
        beta.status = .working
        beta.lastActivity = now.addingTimeInterval(-1)
        beta.lastTool = "Bash"
        beta.lastToolDetail = "make test"

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [alpha, beta],
            preserving: previous,
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["beta", "alpha"])
        XCTAssertEqual(result.map(\.status), [.working, .waitingPermission])
        XCTAssertEqual(result.first?.lastToolDetail, "make test")
        XCTAssertEqual(result.last?.notificationMessage, "Approve command")
    }

    func testReconciledActiveOrderAppendsNewcomersInDeterministicLegacyOrder() {
        let now = Date(timeIntervalSince1970: 20_000)
        var survivor = Session.mock(id: "survivor", status: .idle)
        survivor.lastActivity = now.addingTimeInterval(-60)
        var permission = Session.mock(id: "permission", status: .waitingPermission)
        permission.lastActivity = now.addingTimeInterval(-30)
        var tieB = Session.mock(id: "b", status: .working)
        tieB.lastActivity = now
        var tieA = Session.mock(id: "a", status: .working)
        tieA.lastActivity = now

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [tieB, survivor, tieA, permission],
            preserving: [survivor],
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["survivor", "permission", "a", "b"])
    }

    func testReconciledActiveOrderCompactsSurvivorsAndKeepsNonActiveRemainderOrder() {
        let now = Date(timeIntervalSince1970: 30_000)
        let alpha = Session.mock(id: "alpha", status: .working)
        var beta = Session.mock(id: "beta", status: .idle)
        let charlie = Session.mock(id: "charlie", status: .working)
        var dormant = Session.mock(id: "dormant", status: .idle)
        beta.lifecycle = .dormant
        dormant.lifecycle = .dormant

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [beta, dormant, alpha],
            preserving: [alpha, beta, charlie],
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["alpha", "beta", "dormant"])
        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: result, now: now).map(\.id), ["alpha"])
        XCTAssertEqual(SessionDisplayPolicy.idleSessions(from: result, now: now).map(\.id), ["beta", "dormant"])
    }

    func testReconciledActiveOrderTreatsStaleIdleReentryAsNewcomer() {
        let now = Date(timeIntervalSince1970: 40_000)
        let survivor = Session.mock(id: "survivor", status: .working)
        var returning = Session.mock(id: "returning", status: .idle)
        returning.lastActivity = now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 1)
        let previous = [returning, survivor]

        returning.status = .working
        returning.lastActivity = now
        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [returning, survivor],
            preserving: previous,
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["survivor", "returning"])
    }

    func testReconciledActiveOrderUsesStableConversationIdentityAcrossDesktopPIDChange() {
        let now = Date(timeIntervalSince1970: 50_000)
        let terminal = TerminalInfo(program: "Claude", bundleId: HostAppBundleID.claudeDesktop)
        var desktop = Session.mock(
            id: "conversation",
            status: .working,
            pid: 100,
            terminal: terminal,
            source: Session.ccSource
        )
        let other = Session.mock(id: "other", status: .working, source: Session.codexSource)
        let previous = [desktop, other]

        desktop.pid = 200
        desktop.lastActivity = now
        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [other, desktop],
            preserving: previous,
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["200", "other"])
        XCTAssertEqual(
            SessionIdentityPolicy.stableKey(for: previous[0]),
            SessionIdentityPolicy.stableKey(for: result[0])
        )
    }

    private func activeIdle(id: String, lastActivity: Date) -> Session {
        var session = Session.mock(id: id, status: .idle)
        session.lifecycle = .active
        session.lastActivity = lastActivity
        return session
    }

    private func activeWaiting(id: String, lastActivity: Date) -> Session {
        var session = Session.mock(id: id, status: .waitingInput)
        session.lifecycle = .active
        session.lastActivity = lastActivity
        return session
    }

    private func dormant(id: String) -> Session {
        var session = Session.mock(id: id, status: .idle)
        session.lifecycle = .dormant
        return session
    }
}
