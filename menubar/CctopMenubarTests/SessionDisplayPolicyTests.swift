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
        let userSessions = userSessions(fromDataFixtures: sessions)

        XCTAssertEqual(
            SessionDisplayPolicy.activeSessions(from: userSessions, now: now).map(\.displayRecord.data.id),
            ["fresh", "waiting"]
        )
    }

    func testIdleSessionsIncludesDormantAndStaleActiveIdleOnly() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval + 60)),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
            dormant(id: "dormant"),
            activeWaiting(id: "waiting", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
        ]
        let userSessions = sessions.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }

        XCTAssertEqual(
            SessionDisplayPolicy.idleSessions(from: userSessions, now: now).map(\.displayRecord.data.id),
            ["stale", "dormant"]
        )
    }

    func testReconciledOrderOwnsIdleRecencyOrder() {
        let now = Date(timeIntervalSince1970: 5_000)
        var older = dormant(id: "a-older")
        older.lastActivity = now.addingTimeInterval(-300)
        var newer = dormant(id: "z-newer")
        newer.lastActivity = now.addingTimeInterval(-10)

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [older, newer]),
            preserving: [],
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["z-newer", "a-older"])
        XCTAssertEqual(
            SessionDisplayPolicy.idleSessions(from: result, now: now).map(\.identity),
            result.map(\.identity)
        )
    }

    func testSignatureTracksDisplayBuckets() {
        let now = Date()
        let sessions = [
            activeIdle(id: "fresh", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval + 60)),
            activeIdle(id: "stale", lastActivity: now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 60)),
            dormant(id: "dormant"),
        ]
        let userSessions = sessions.map {
            userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
        }

        XCTAssertEqual(
            SessionDisplayPolicy.signature(for: userSessions, now: now),
            .init(
                activeIDs: [userSessions[0].identity],
                idleIDs: Array(userSessions[1...]).map(\.identity)
            )
        )
    }

    func testReconciledOrderKeepsWaitingPeerOrderAcrossSameGroupUpdates() {
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

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [second, first]),
            preserving: userSessions(fromDataFixtures: previous),
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["first", "second"])
        XCTAssertEqual(result.map(\.status), [.needsAttention, .waitingInput])
        XCTAssertEqual(result.map(\.displayRecord.data.notificationMessage), ["Review failure", "Continue?"])
    }

    func testReconciledOrderKeepsWorkingAndActiveIdlePeerOrderAcrossActivityChanges() {
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

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [idleB, workB, idleA, workA]),
            preserving: userSessions(fromDataFixtures: previous),
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["work-a", "work-b", "idle-a", "idle-b"])
    }

    func testReconciledOrderMovesWorkingSessionToWaitingGroupTail() {
        let now = Date(timeIntervalSince1970: 30_000)
        let waitA = SessionData.mock(id: "wait-a", status: .waitingInput)
        let waitB = SessionData.mock(id: "wait-b", status: .needsAttention)
        var working = SessionData.mock(id: "working", status: .working)
        let previous = [waitA, waitB, working]

        working.status = .waitingInput

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [working, waitB, waitA]),
            preserving: userSessions(fromDataFixtures: previous),
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["wait-a", "wait-b", "working"])
    }

    func testReconciledOrderMovesWaitingSessionToWorkingGroupTail() {
        let now = Date(timeIntervalSince1970: 40_000)
        var waiting = SessionData.mock(id: "waiting", status: .waitingInput)
        let workA = SessionData.mock(id: "work-a", status: .working)
        let workB = SessionData.mock(id: "work-b", status: .working)
        let previous = [waiting, workA, workB]

        waiting.status = .working
        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [waiting, workB, workA]),
            preserving: userSessions(fromDataFixtures: previous),
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["work-a", "work-b", "waiting"])
    }

    func testReconciledOrderAppendsNewcomersWithinEachPriorityGroup() {
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

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [
                newIdle, newCompacting, newWorking, newWaiting, newPermission,
                idle, compacting, working, waiting, permission,
            ]),
            preserving: userSessions(fromDataFixtures: [permission, waiting, working, compacting, idle]),
            now: now
        )

        XCTAssertEqual(
            result.map(\.displayRecord.data.id),
            [
                "permission", "new-permission", "waiting", "new-waiting", "working", "new-working",
                "compacting", "new-compacting", "idle", "new-idle",
            ]
        )
    }

    func testReconciledOrderCompactsActiveSurvivorsAndAppendsCanonicalIdleRows() {
        let now = Date(timeIntervalSince1970: 60_000)
        let waitA = SessionData.mock(id: "wait-a", status: .waitingInput)
        let waitB = SessionData.mock(id: "wait-b", status: .waitingInput)
        let workA = SessionData.mock(id: "work-a", status: .working)
        let workB = SessionData.mock(id: "work-b", status: .working)
        var dormant = SessionData.mock(id: "dormant", status: .idle)
        dormant.lifecycle = .dormant

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [workB, dormant, waitB]),
            preserving: userSessions(fromDataFixtures: [waitA, waitB, workA, workB]),
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["wait-b", "work-b", "dormant"])
        XCTAssertEqual(
            SessionDisplayPolicy.activeSessions(from: result, now: now).map(\.displayRecord.data.id),
            ["wait-b", "work-b"]
        )
        XCTAssertEqual(
            SessionDisplayPolicy.idleSessions(from: result, now: now).map(\.displayRecord.data.id),
            ["dormant"]
        )
    }

    func testReconciledOrderUsesDeterministicCurrentInputOnInitialLoad() {
        let now = Date(timeIntervalSince1970: 70_000)
        let workA = SessionData.mock(id: "a-work", status: .working)
        let waiting = SessionData.mock(id: "b-wait", status: .waitingInput)
        let workB = SessionData.mock(id: "c-work", status: .working)
        let idle = SessionData.mock(id: "d-idle", status: .idle)

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [workA, waiting, workB, idle]),
            preserving: [],
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["b-wait", "a-work", "c-work", "d-idle"])
    }

    func testReconciledOrderTreatsStaleIdleReentryAsGroupEntrant() {
        let now = Date(timeIntervalSince1970: 80_000)
        let survivor = SessionData.mock(id: "survivor", status: .working)
        var returning = SessionData.mock(id: "returning", status: .idle)
        returning.lastActivity = now.addingTimeInterval(-SessionDisplayPolicy.staleIdleInterval - 1)
        let previous = [returning, survivor]

        returning.status = .working
        returning.lastActivity = now
        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [returning, survivor]),
            preserving: userSessions(fromDataFixtures: previous),
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["survivor", "returning"])
    }

    func testReconciledOrderUsesStableConversationIdentityAcrossDesktopPIDChange() {
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
        let result = SessionDisplayPolicy.reconcilingOrder(
            in: [other, desktop].map {
                userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
            },
            preserving: previous.map {
                userSession(identity: SessionIdentityPolicy.logicalIdentity(for: $0), display: $0, records: [$0])
            },
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.id), ["200", "other"])
        XCTAssertEqual(
            SessionIdentityPolicy.stableKey(for: previous[0]),
            SessionIdentityPolicy.stableKey(for: result[0].displayRecord.data)
        )
    }

    func testReconciledOrderUsesPermanentIdentityAcrossRecordReplacementAndStatusMovement() {
        let now = Date(timeIntervalSince1970: 95_000)
        let sharedID = "11111111-1111-4111-8111-111111111111"
        var userSession = SessionData.mock(
            id: "old-record", cctopSessionId: sharedID,
            status: .working, pid: 100, source: SessionData.opencodeSource
        )
        let workingPeer = SessionData.mock(id: "peer", status: .working, pid: 200, source: SessionData.opencodeSource)
        let previous = [userSession, workingPeer]

        userSession = SessionData.mock(
            id: "new-record", cctopSessionId: sharedID,
            status: .waitingInput, pid: 300, source: SessionData.opencodeSource
        )
        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [workingPeer, userSession]),
            preserving: userSessions(fromDataFixtures: previous),
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.pid), [300, 200])
        XCTAssertEqual(
            result.map(\.identity),
            [
                SessionIdentityPolicy.logicalIdentity(for: userSession),
                SessionIdentityPolicy.logicalIdentity(for: workingPeer),
            ]
        )
    }

    func testReconciledOrderKeepsLegacySlotAfterPermanentIDStamp() {
        let now = Date(timeIntervalSince1970: 95_500)
        let sharedID = "11111111-1111-4111-8111-111111111111"
        var legacy = SessionData.mock(
            id: "same-record", status: .working, pid: 100, source: SessionData.opencodeSource
        )
        legacy.cctopSessionId = nil
        var stamped = legacy
        stamped.cctopSessionId = sharedID
        let peer = SessionData.mock(
            id: "peer", cctopSessionId: "22222222-2222-4222-8222-222222222222",
            status: .working, pid: 200, source: SessionData.opencodeSource
        )

        let result = SessionDisplayPolicy.reconcilingOrder(
            in: userSessions(fromDataFixtures: [peer, stamped]),
            preserving: userSessions(fromDataFixtures: [legacy, peer]),
            now: now
        )

        XCTAssertEqual(result.map(\.displayRecord.data.pid), [100, 200])
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
