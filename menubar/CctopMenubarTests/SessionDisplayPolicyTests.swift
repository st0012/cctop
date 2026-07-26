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

    func testReconciledActiveOrderKeepsWaitingPeerOrderAcrossSameGroupUpdates() {
        let now = Date(timeIntervalSince1970: 10_000)
        var first = Session.mock(id: "first", status: .waitingInput, notificationMessage: "old")
        first.lastActivity = now.addingTimeInterval(-300)
        var second = Session.mock(id: "second", status: .needsAttention, notificationMessage: "old")
        second.lastActivity = now.addingTimeInterval(-200)
        let previous = [first, second]

        first.status = .needsAttention
        first.lastActivity = now
        first.notificationMessage = "Review failure"
        second.status = .waitingInput
        second.lastActivity = now.addingTimeInterval(-600)
        second.notificationMessage = "Continue?"

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [second, first],
            preserving: previous,
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["first", "second"])
        XCTAssertEqual(result.map(\.status), [.needsAttention, .waitingInput])
        XCTAssertEqual(result.map(\.notificationMessage), ["Review failure", "Continue?"])
    }

    func testReconciledActiveOrderKeepsWorkingAndActiveIdlePeerOrderAcrossActivityChanges() {
        let now = Date(timeIntervalSince1970: 20_000)
        var workA = Session.mock(id: "work-a", status: .working)
        var workB = Session.mock(id: "work-b", status: .working)
        var idleA = Session.mock(id: "idle-a", status: .idle)
        var idleB = Session.mock(id: "idle-b", status: .idle)
        let previous = [workA, workB, idleA, idleB]

        workA.lastActivity = now
        workB.lastActivity = now.addingTimeInterval(-600)
        idleA.lastActivity = now.addingTimeInterval(-60)
        idleB.lastActivity = now.addingTimeInterval(-1_200)

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [idleB, workB, idleA, workA],
            preserving: previous,
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["work-a", "work-b", "idle-a", "idle-b"])
    }

    func testReconciledActiveOrderMovesWorkingSessionToWaitingGroupTail() {
        let now = Date(timeIntervalSince1970: 30_000)
        let waitA = Session.mock(id: "wait-a", status: .waitingInput)
        let waitB = Session.mock(id: "wait-b", status: .needsAttention)
        var working = Session.mock(id: "working", status: .working)
        let previous = [waitA, waitB, working]

        working.status = .waitingInput

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [working, waitB, waitA],
            preserving: previous,
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["wait-a", "wait-b", "working"])
    }

    func testReconciledActiveOrderMovesWaitingSessionToWorkingGroupTail() {
        let now = Date(timeIntervalSince1970: 40_000)
        var waiting = Session.mock(id: "waiting", status: .waitingInput)
        let workA = Session.mock(id: "work-a", status: .working)
        let workB = Session.mock(id: "work-b", status: .working)
        let previous = [waiting, workA, workB]

        waiting.status = .working
        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [waiting, workB, workA],
            preserving: previous,
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["work-a", "work-b", "waiting"])
    }

    func testReconciledActiveOrderAppendsNewcomersWithinEachPriorityGroup() {
        let now = Date(timeIntervalSince1970: 50_000)
        let permission = Session.mock(id: "permission", status: .waitingPermission)
        let waiting = Session.mock(id: "waiting", status: .waitingInput)
        let working = Session.mock(id: "working", status: .working)
        let compacting = Session.mock(id: "compacting", status: .compacting)
        let idle = Session.mock(id: "idle", status: .idle)
        let newPermission = Session.mock(id: "new-permission", status: .waitingPermission)
        let newWaiting = Session.mock(id: "new-waiting", status: .waitingInput)
        let newWorking = Session.mock(id: "new-working", status: .working)
        let newCompacting = Session.mock(id: "new-compacting", status: .compacting)
        let newIdle = Session.mock(id: "new-idle", status: .idle)

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [newIdle, newCompacting, newWorking, newWaiting, newPermission, idle, compacting, working, waiting, permission],
            preserving: [permission, waiting, working, compacting, idle],
            now: now
        )

        XCTAssertEqual(
            result.map(\.id),
            [
                "permission", "new-permission", "waiting", "new-waiting", "working", "new-working",
                "compacting", "new-compacting", "idle", "new-idle",
            ]
        )
    }

    func testReconciledActiveOrderCompactsSurvivorsAndKeepsNonActiveRemainderOrder() {
        let now = Date(timeIntervalSince1970: 60_000)
        let waitA = Session.mock(id: "wait-a", status: .waitingInput)
        let waitB = Session.mock(id: "wait-b", status: .waitingInput)
        let workA = Session.mock(id: "work-a", status: .working)
        let workB = Session.mock(id: "work-b", status: .working)
        var dormant = Session.mock(id: "dormant", status: .idle)
        dormant.lifecycle = .dormant

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [workB, dormant, waitB],
            preserving: [waitA, waitB, workA, workB],
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["wait-b", "work-b", "dormant"])
        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: result, now: now).map(\.id), ["wait-b", "work-b"])
        XCTAssertEqual(SessionDisplayPolicy.idleSessions(from: result, now: now).map(\.id), ["dormant"])
    }

    func testReconciledActiveOrderUsesDeterministicCurrentInputOnInitialLoad() {
        let now = Date(timeIntervalSince1970: 70_000)
        let workA = Session.mock(id: "a-work", status: .working)
        let waiting = Session.mock(id: "b-wait", status: .waitingInput)
        let workB = Session.mock(id: "c-work", status: .working)
        let idle = Session.mock(id: "d-idle", status: .idle)

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [workA, waiting, workB, idle],
            preserving: [],
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["b-wait", "a-work", "c-work", "d-idle"])
    }

    func testReconciledActiveOrderTreatsStaleIdleReentryAsGroupEntrant() {
        let now = Date(timeIntervalSince1970: 80_000)
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
        let now = Date(timeIntervalSince1970: 90_000)
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
