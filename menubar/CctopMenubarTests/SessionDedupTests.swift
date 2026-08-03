import XCTest
@testable import CctopMenubar

final class SessionDedupTests: XCTestCase {
    // MARK: - Shared-PID identity

    /// Codex multiplexes every conversation onto one host PID, so identifying a session
    /// by PID collapses them. Two Codex conversations sharing a host PID must get
    /// distinct ids (by session_id); non-codex sources keep PID-based identity.
    func testCodexSessionsWithSharedPIDHaveDistinctIDs() {
        var a = Session(sessionId: "conv-a", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        a.source = "codex"; a.pid = 31349
        var b = Session(sessionId: "conv-b", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        b.source = "codex"; b.pid = 31349

        XCTAssertEqual(a.id, "conv-a")
        XCTAssertEqual(b.id, "conv-b")
        XCTAssertNotEqual(a.id, b.id)

        // Non-codex still identified by PID.
        var cc = Session(sessionId: "conv-c", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        cc.source = "cc"; cc.pid = 31349
        XCTAssertEqual(cc.id, "31349")
    }

    func testLogicalIdentityPrefersPermanentIDAndFallsBackForLegacyRecords() {
        let sharedID = "11111111-1111-4111-8111-111111111111"
        let first = Session.mock(id: "first", cctopSessionId: sharedID, pid: 100, source: Session.opencodeSource)
        let replacement = Session.mock(id: "replacement", cctopSessionId: sharedID, pid: 200, source: Session.opencodeSource)
        var legacy = Session.mock(id: "legacy", pid: 300, source: Session.opencodeSource)
        legacy.cctopSessionId = nil
        var invalid = legacy
        invalid.cctopSessionId = "not-a-uuid"

        XCTAssertEqual(
            SessionIdentityPolicy.logicalIdentity(for: first),
            SessionIdentityPolicy.logicalIdentity(for: replacement)
        )
        XCTAssertEqual(
            SessionIdentityPolicy.logicalIdentity(for: legacy),
            SessionIdentityPolicy.logicalIdentity(for: invalid)
        )
        XCTAssertNotEqual(
            SessionIdentityPolicy.logicalIdentity(for: first),
            SessionIdentityPolicy.logicalIdentity(for: legacy)
        )
    }

    func testLogicalDedupKeepsFirstRowPositionAndPreferredObservation() {
        let sharedID = "11111111-1111-4111-8111-111111111111"
        let old = candidate(
            sessionId: "old", pid: 100, bundleId: nil, lifecycleRank: 1,
            lastActivity: Date(timeIntervalSince1970: 10), path: "/old.json"
        ) { $0.cctopSessionId = sharedID }
        let other = candidate(
            sessionId: "other", pid: 200, bundleId: nil, lifecycleRank: 0,
            path: "/other.json"
        )
        let current = candidate(
            sessionId: "current", pid: 300, bundleId: nil, lifecycleRank: 0,
            lastActivity: Date(timeIntervalSince1970: 20), path: "/current.json"
        ) { $0.cctopSessionId = sharedID }

        let result = SessionIdentityPolicy.dedupedCandidatesByLogicalIdentity([old, other, current])

        XCTAssertEqual(result.map(\.session.pid), [300, 200])
    }

    // MARK: - Desktop dedup by session_id (Phase 1, total order)

    private static let desktopBundle = "com.anthropic.claudefordesktop"

    private func deduped(_ candidates: [DedupCandidate]) -> [Session] {
        SessionIdentityPolicy.dedupedCandidatesByStableKey(candidates).map(\.session)
    }

    func testDedupDesktopCollapsesSameSessionIdDifferentPid() {
        let dead = candidate(sessionId: "conv-a", pid: 100, bundleId: Self.desktopBundle, lifecycleRank: 1)
        let live = candidate(sessionId: "conv-a", pid: 200, bundleId: Self.desktopBundle, lifecycleRank: 0)
        let result = deduped([dead, live])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pid, 200) // live (rank 0) wins, NOT the dead/newer-file one
    }

    func testDedupLiveBeatsDormantEvenIfDormantNewer() {
        let dormantNewer = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                                     lifecycleRank: 1, lastActivity: Date(timeIntervalSince1970: 9999))
        let liveOlder = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                                  lifecycleRank: 0, lastActivity: Date(timeIntervalSince1970: 1))
        let result = deduped([dormantNewer, liveOlder])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pid, 2) // lifecycle rank dominates lastActivity
    }

    func testDedupDormantBeatsFinished() {
        let finished = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle, lifecycleRank: 2)
        let dormant = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle, lifecycleRank: 1)
        XCTAssertEqual(deduped([finished, dormant]).first?.pid, 2)
    }

    func testDedupSameRankNewerLastActivityWins() {
        let older = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                              lifecycleRank: 1, lastActivity: Date(timeIntervalSince1970: 1))
        let newer = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                              lifecycleRank: 1, lastActivity: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(deduped([older, newer]).first?.pid, 2)
    }

    func testDedupTieBreaksByEffectiveEndDate() {
        let t = Date(timeIntervalSince1970: 5)
        let a = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                          lifecycleRank: 1, lastActivity: t, endedAt: Date(timeIntervalSince1970: 10))
        let b = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                          lifecycleRank: 1, lastActivity: t, endedAt: Date(timeIntervalSince1970: 20))
        XCTAssertEqual(deduped([a, b]).first?.pid, 2) // newer effectiveEndDate
    }

    func testDedupFinalTieBreakByPathIsDeterministic() {
        let t = Date(timeIntervalSince1970: 5)
        let a = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                          lifecycleRank: 1, lastActivity: t, mtime: t, path: "/a.json")
        let b = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                          lifecycleRank: 1, lastActivity: t, mtime: t, path: "/b.json")
        // Smaller path wins, regardless of input order (total, stable).
        XCTAssertEqual(deduped([b, a]).first?.pid, 1)
        XCTAssertEqual(deduped([a, b]).first?.pid, 1)
    }

    func testDedupMissingMtimeLosesToRealMtime() {
        let t = Date(timeIntervalSince1970: 5)
        let noMtime = candidate(sessionId: "c", pid: 1, bundleId: Self.desktopBundle,
                                lifecycleRank: 1, lastActivity: t, mtime: .distantPast)
        let realMtime = candidate(sessionId: "c", pid: 2, bundleId: Self.desktopBundle,
                                  lifecycleRank: 1, lastActivity: t, mtime: t)
        XCTAssertEqual(deduped([noMtime, realMtime]).first?.pid, 2)
    }

    func testDedupTerminalKeepsPidIdentityEvenWithSameSessionId() {
        let oldPid = candidate(sessionId: "shared", pid: 100, bundleId: "com.googlecode.iterm2", lifecycleRank: 0)
        let newPid = candidate(sessionId: "shared", pid: 200, bundleId: "com.googlecode.iterm2", lifecycleRank: 0)
        let result = deduped([oldPid, newPid])
        XCTAssertEqual(result.compactMap(\.pid).sorted(), [100, 200])
    }

    func testDedupUnknownHostKeepsPidIdentityEvenWithSameSessionId() {
        let oldPid = candidate(sessionId: "shared", pid: 100, bundleId: nil, lifecycleRank: 0)
        let newPid = candidate(sessionId: "shared", pid: 200, bundleId: nil, lifecycleRank: 0)
        let result = deduped([oldPid, newPid])
        XCTAssertEqual(result.compactMap(\.pid).sorted(), [100, 200])
    }

    func testDedupOpencodeKeepsSamePIDConversationsAndCrossPIDObservationsSeparate() {
        let main = candidate(
            sessionId: "ses-main", pid: 100, bundleId: nil, lifecycleRank: 0,
            source: Session.opencodeSource, path: "/opencode-100-ses-main.json"
        )
        let other = candidate(
            sessionId: "ses-other", pid: 100, bundleId: nil, lifecycleRank: 0,
            source: Session.opencodeSource, path: "/opencode-100-ses-other.json"
        )
        let resumedElsewhere = candidate(
            sessionId: "ses-main", pid: 200, bundleId: nil, lifecycleRank: 0,
            source: Session.opencodeSource, path: "/opencode-200-ses-main.json"
        )

        let result = deduped([main, other, resumedElsewhere])

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(
            Set(result.map { "\($0.pid ?? 0):\($0.sessionId)" }),
            ["100:ses-main", "100:ses-other", "200:ses-main"]
        )
    }

    func testDedupMigratedCodexSessionUsesStableConversationIdAcrossHostClass() {
        let oldPidKeyed = candidate(
            sessionId: "conv-a", pid: 100, bundleId: nil, lifecycleRank: 2,
            source: Session.codexSource, path: "/100.json"
        )
        let desktopKeyed = candidate(
            sessionId: "conv-a", pid: 200, bundleId: HostAppBundleID.codexDesktop,
            lifecycleRank: 0, source: Session.codexSource, path: "/codex-conv-a.json"
        )

        let result = deduped([oldPidKeyed, desktopKeyed])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.pid, 200)
    }

    // Distinct conversations never collapse.
    func testDedupDifferentSessionIdsStaySeparate() {
        let one = candidate(sessionId: "conv-1", pid: 1, bundleId: Self.desktopBundle, lifecycleRank: 0)
        let two = candidate(sessionId: "conv-2", pid: 2, bundleId: Self.desktopBundle, lifecycleRank: 0)
        XCTAssertEqual(deduped([one, two]).count, 2)
    }
}
