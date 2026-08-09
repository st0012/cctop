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
            .init(
                activeIDs: [SessionIdentityPolicy.logicalIdentity(for: sessions[0])],
                idleIDs: sessions[1...].map { SessionIdentityPolicy.logicalIdentity(for: $0) }
            )
        )
    }

    func testReconciledActiveOrderKeepsWaitingPeerOrderAcrossSameGroupUpdates() {
        let now = Date(timeIntervalSince1970: 10_000)
        var first = SessionData.mock(id: "first", status: .waitingInput, notificationMessage: "old")
        first.lastActivity = now.addingTimeInterval(-300)
        var second = SessionData.mock(id: "second", status: .needsAttention, notificationMessage: "old")
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
        var workA = SessionData.mock(id: "work-a", status: .working)
        var workB = SessionData.mock(id: "work-b", status: .working)
        var idleA = SessionData.mock(id: "idle-a", status: .idle)
        var idleB = SessionData.mock(id: "idle-b", status: .idle)
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
        let waitA = SessionData.mock(id: "wait-a", status: .waitingInput)
        let waitB = SessionData.mock(id: "wait-b", status: .needsAttention)
        var working = SessionData.mock(id: "working", status: .working)
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
        var waiting = SessionData.mock(id: "waiting", status: .waitingInput)
        let workA = SessionData.mock(id: "work-a", status: .working)
        let workB = SessionData.mock(id: "work-b", status: .working)
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
        let permission = SessionData.mock(id: "permission", status: .waitingPermission)
        let waiting = SessionData.mock(id: "waiting", status: .waitingInput)
        let working = SessionData.mock(id: "working", status: .working)
        let compacting = SessionData.mock(id: "compacting", status: .compacting)
        let idle = SessionData.mock(id: "idle", status: .idle)
        let newPermission = SessionData.mock(id: "new-permission", status: .waitingPermission)
        let newWaiting = SessionData.mock(id: "new-waiting", status: .waitingInput)
        let newWorking = SessionData.mock(id: "new-working", status: .working)
        let newCompacting = SessionData.mock(id: "new-compacting", status: .compacting)
        let newIdle = SessionData.mock(id: "new-idle", status: .idle)

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
        let waitA = SessionData.mock(id: "wait-a", status: .waitingInput)
        let waitB = SessionData.mock(id: "wait-b", status: .waitingInput)
        let workA = SessionData.mock(id: "work-a", status: .working)
        let workB = SessionData.mock(id: "work-b", status: .working)
        var dormant = SessionData.mock(id: "dormant", status: .idle)
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
        let workA = SessionData.mock(id: "a-work", status: .working)
        let waiting = SessionData.mock(id: "b-wait", status: .waitingInput)
        let workB = SessionData.mock(id: "c-work", status: .working)
        let idle = SessionData.mock(id: "d-idle", status: .idle)

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [workA, waiting, workB, idle],
            preserving: [],
            now: now
        )

        XCTAssertEqual(result.map(\.id), ["b-wait", "a-work", "c-work", "d-idle"])
    }

    func testReconciledActiveOrderTreatsStaleIdleReentryAsGroupEntrant() {
        let now = Date(timeIntervalSince1970: 80_000)
        let survivor = SessionData.mock(id: "survivor", status: .working)
        var returning = SessionData.mock(id: "returning", status: .idle)
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
        var desktop = SessionData.mock(
            id: "conversation",
            status: .working,
            pid: 100,
            terminal: terminal,
            source: SessionData.ccSource
        )
        let other = SessionData.mock(id: "other", status: .working, source: SessionData.codexSource)
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

    func testReconciledActiveOrderUsesPermanentIdentityAcrossRecordReplacementAndStatusMovement() {
        let now = Date(timeIntervalSince1970: 95_000)
        let sharedID = "11111111-1111-4111-8111-111111111111"
        var userSession = SessionData.mock(
            id: "old-observation", cctopSessionId: sharedID,
            status: .working, pid: 100, source: SessionData.opencodeSource
        )
        let workingPeer = SessionData.mock(id: "peer", status: .working, pid: 200, source: SessionData.opencodeSource)
        let previous = [userSession, workingPeer]

        userSession = SessionData.mock(
            id: "new-observation", cctopSessionId: sharedID,
            status: .waitingInput, pid: 300, source: SessionData.opencodeSource
        )
        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [workingPeer, userSession], preserving: previous, now: now
        )

        XCTAssertEqual(result.map(\.pid), [300, 200])
        XCTAssertEqual(
            result.map { SessionIdentityPolicy.logicalIdentity(for: $0) },
            [
                SessionIdentityPolicy.logicalIdentity(for: userSession),
                SessionIdentityPolicy.logicalIdentity(for: workingPeer),
            ]
        )
    }

    func testReconciledActiveOrderDoesNotReplayDuplicatePreviousLogicalRows() {
        let now = Date(timeIntervalSince1970: 96_000)
        let sharedID = "11111111-1111-4111-8111-111111111111"
        let previousFirst = SessionData.mock(
            id: "old-first", cctopSessionId: sharedID,
            status: .working, pid: 100, source: SessionData.opencodeSource
        )
        let previousSecond = SessionData.mock(
            id: "old-second", cctopSessionId: sharedID,
            status: .working, pid: 200, source: SessionData.opencodeSource
        )
        let current = SessionData.mock(
            id: "current", cctopSessionId: sharedID,
            status: .working, pid: 300, source: SessionData.opencodeSource
        )

        let result = SessionDisplayPolicy.reconcilingActiveOrder(
            in: [current], preserving: [previousFirst, previousSecond], now: now
        )

        XCTAssertEqual(result.map(\.pid), [300])
    }

    private func activeIdle(id: String, lastActivity: Date) -> SessionData {
        var session = SessionData.mock(id: id, status: .idle)
        session.lifecycle = .active
        session.lastActivity = lastActivity
        return session
    }

    private func activeWaiting(id: String, lastActivity: Date) -> SessionData {
        var session = SessionData.mock(id: id, status: .waitingInput)
        session.lifecycle = .active
        session.lastActivity = lastActivity
        return session
    }

    private func dormant(id: String) -> SessionData {
        var session = SessionData.mock(id: id, status: .idle)
        session.lifecycle = .dormant
        return session
    }
}
