import Darwin
import XCTest
@testable import CctopMenubar

final class SessionLifecycleTests: XCTestCase {
    // MARK: - Lifecycle derivation (Phase 1)

    private static let lifeNow = Date(timeIntervalSince1970: 1_000_000)
    private static let activeWin: TimeInterval = 300        // 5 min
    private static let retentionWin: TimeInterval = 86_400  // 24h

    private func lifeSession(
        source: String? = nil,
        agoSeconds: TimeInterval,
        disconnectedAgoSeconds: TimeInterval? = nil
    ) -> Session {
        var session = Session(sessionId: "s", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        session.source = source
        session.lastActivity = Self.lifeNow.addingTimeInterval(-agoSeconds)
        if let disconnectedAgoSeconds {
            session.disconnectedAt = Self.lifeNow.addingTimeInterval(-disconnectedAgoSeconds)
        }
        return session
    }

    private func life(
        _ session: Session,
        _ hostClass: SessionHostClass,
        alive: Bool,
        desktopAppRunning: Bool? = nil
    ) -> SessionLifecycle {
        SessionLifecyclePolicy.lifecycle(
            for: session,
            hostClass: hostClass,
            processAlive: alive,
            now: Self.lifeNow,
            windows: LifecycleWindows(active: Self.activeWin, retention: Self.retentionWin),
            desktopAppRunning: desktopAppRunning
        )
    }

    private func connection(
        _ session: Session,
        _ hostClass: SessionHostClass,
        alive: Bool,
        desktopAppRunning: Bool? = nil
    ) -> SessionConnectionState {
        SessionLifecyclePolicy.connectionState(
            for: session, hostClass: hostClass, processAlive: alive, now: Self.lifeNow,
            windows: LifecycleWindows(active: Self.activeWin, retention: Self.retentionWin),
            desktopAppRunning: desktopAppRunning
        )
    }

    func testBuildCandidatesKeepsDesktopSessionActiveWhenHostAppIsRunning() throws {
        let root = NSTemporaryDirectory() + "cctop-running-desktop-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let sessionPath = (root as NSString).appendingPathComponent("codex-stale.json")
        var session = lifeSession(source: Session.codexSource, agoSeconds: 10_000, disconnectedAgoSeconds: 10_000)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        session.pid = nil
        try session.writeToFile(path: sessionPath)

        let candidates = SessionManager.buildCandidates(
            [URL(fileURLWithPath: sessionPath)],
            now: Self.lifeNow,
            desktopAppConnectionLookup: DesktopAppConnectionLookup { bundleID in
                bundleID == HostAppBundleID.codexDesktop
            }
        )

        XCTAssertEqual(candidates.map(\.session.lifecycle), [.active])
    }

    func testBuildCandidatesBatchesDesktopAppRunningLookupByBundleID() {
        var firstCodex = codexDesktopSession(sessionId: "codex-one", projectPath: "/tmp/p")
        firstCodex.pid = nil
        var secondCodex = codexDesktopSession(sessionId: "codex-two", projectPath: "/tmp/p")
        secondCodex.pid = nil
        var claude = claudeDesktopSession(sessionId: "claude-one", projectPath: "/tmp/p")
        claude.pid = nil
        let cli = codexTerminalSession(sessionId: "codex-cli", projectPath: "/tmp/p")
        var requestedBundleIDSets: [Set<String>] = []

        _ = SessionManager.buildCandidates(
            [
                (URL(fileURLWithPath: "/tmp/codex-one.json"), firstCodex),
                (URL(fileURLWithPath: "/tmp/codex-two.json"), secondCodex),
                (URL(fileURLWithPath: "/tmp/claude-one.json"), claude),
                (URL(fileURLWithPath: "/tmp/codex-cli.json"), cli)
            ],
            now: Self.lifeNow,
            desktopAppConnectionLookup: DesktopAppConnectionLookup(runningStates: { bundleIDs in
                requestedBundleIDSets.append(bundleIDs)
                return Dictionary(uniqueKeysWithValues: bundleIDs.map { ($0, true) })
            }),
            claudeMetadata: nil,
            codexThreads: StubCodexThreadState(),
            processAlive: { _ in false }
        )

        XCTAssertEqual(requestedBundleIDSets, [[HostAppBundleID.codexDesktop, HostAppBundleID.claudeDesktop]])
    }

    func testBuildCandidatesWarmsCodexThreadLookupWithAllCodexSessionIDs() {
        var desktop = codexDesktopSession(sessionId: "codex-desktop", projectPath: "/tmp/desktop")
        desktop.pid = nil
        var cli = codexTerminalSession(sessionId: "codex-cli", projectPath: "/tmp/cli")
        cli.pid = nil
        let codexThreads = RecordingCodexThreadState(
            projectNamesByThreadID: [
                "codex-desktop": "desktop-project",
                "codex-cli": "cli-project"
            ]
        )

        let candidates = SessionManager.buildCandidates(
            [
                (URL(fileURLWithPath: "/tmp/codex-desktop.json"), desktop),
                (URL(fileURLWithPath: "/tmp/codex-cli.json"), cli)
            ],
            now: Self.lifeNow,
            desktopAppConnectionLookup: DesktopAppConnectionLookup { _ in true },
            claudeMetadata: nil,
            codexThreads: codexThreads,
            processAlive: { _ in false }
        )
        let namesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.session.sessionId, $0.session.desktopProjectName) })

        XCTAssertEqual(codexThreads.projectNameRequests, [["codex-cli", "codex-desktop"]])
        XCTAssertEqual(namesByID["codex-desktop"]!, "desktop-project")
        XCTAssertNil(namesByID["codex-cli"]!)
    }

    @MainActor
    func testSessionManagerBatchesCodexThreadLookupDuringRefresh() throws {
        let root = NSTemporaryDirectory() + "cctop-batched-codex-thread-state-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let desktopID = "codex-desktop"
        var desktop = codexDesktopSession(sessionId: desktopID, projectPath: "/tmp/desktop")
        desktop.pid = nil
        try desktop.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("codex-\(desktopID).json"))

        let cliID = "codex-cli"
        var cli = codexTerminalSession(sessionId: cliID, projectPath: "/tmp/cli")
        cli.pid = nil
        try cli.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("codex-\(cliID).json"))

        let helperID = "codex-helper"
        var helper = codexTerminalSession(sessionId: helperID, projectPath: "/tmp/helper")
        helper.pid = nil
        try helper.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("codex-\(helperID).json"))

        let codexThreads = RecordingCodexThreadState(
            internalHelpers: [helperID],
            projectNamesByThreadID: [
                desktopID: "desktop-project",
                cliID: "cli-project"
            ]
        )
        var sources = SessionDataSources.live()
        sources.sessionsDir = URL(fileURLWithPath: sessionsDir)
        sources.codexThreads = codexThreads
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }

        _ = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        XCTAssertEqual(codexThreads.stateIndexRequests, [[desktopID, cliID, helperID]])
        XCTAssertEqual(codexThreads.internalHelperRequests, [])
        XCTAssertEqual(codexThreads.projectNameRequests, [])
    }

    @MainActor
    func testSessionManagerClearsDisconnectedAtWhenDesktopHostAppIsRunning() throws {
        let root = NSTemporaryDirectory() + "cctop-desktop-reconnected-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["s"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-reconnected.json")
        var session = lifeSession(source: Session.codexSource, agoSeconds: 10_000, disconnectedAgoSeconds: 10_000)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        session.pid = nil
        // SessionManager derives lifecycle against the real clock; keep the session idle
        // but inside the retention window so the issue #155 age-cap doesn't apply here.
        session.lastActivity = Date().addingTimeInterval(-10_000)
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { bundleID in
                bundleID == HostAppBundleID.codexDesktop
            }
        )

        XCTAssertEqual(manager.sessions.map(\.lifecycle), [.active])
        XCTAssertNil(try Session.fromFile(path: sessionPath).disconnectedAt)
    }

    @MainActor
    func testSessionManagerKeepsEndedDesktopSessionDormantWhenHostAppIsRunning() throws {
        let root = NSTemporaryDirectory() + "cctop-ended-desktop-running-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["s"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-ended.json")
        var session = lifeSession(source: Session.codexSource, agoSeconds: 10_000, disconnectedAgoSeconds: 10_000)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        session.pid = nil
        // SessionManager derives lifecycle against the real clock; keep the session idle
        // but inside the retention window so the issue #155 age-cap doesn't apply here.
        session.lastActivity = Date().addingTimeInterval(-10_000)
        let disconnectedAt = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 60)
        session.endedAt = disconnectedAt.addingTimeInterval(30)
        session.disconnectedAt = disconnectedAt
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { bundleID in
                bundleID == HostAppBundleID.codexDesktop
            }
        )

        XCTAssertEqual(manager.sessions.map(\.lifecycle), [.dormant])
        XCTAssertEqual(try Session.fromFile(path: sessionPath).disconnectedAt, disconnectedAt)
    }

    // The headline issue #155 file class: a DEAD Claude Code session that inherited
    // com.openai.codex from its launcher. It used to classify as Codex Desktop and ride
    // the running app's liveness forever; it must now drain even while Codex Desktop runs.
    @MainActor
    func testSessionManagerDrainsDeadCcSessionWithLeakedCodexDesktopBundle() throws {
        let root = NSTemporaryDirectory() + "cctop-cc-ghost-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("54321.json")
        var session = Session(sessionId: "cc-ghost", projectPath: "/tmp/p", branch: "main",
                              terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop))
        session.source = "cc"
        session.pid = 999_999
        session.lastActivity = Date().addingTimeInterval(-3_600)
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { bundleID in
                bundleID == HostAppBundleID.codexDesktop   // Codex Desktop IS running
            }
        )

        XCTAssertEqual(manager.sessions.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }

    // The live variant must survive: same leaked bundle, but the session's process exists.
    @MainActor
    func testSessionManagerKeepsLiveCcSessionWithLeakedCodexDesktopBundle() throws {
        let root = NSTemporaryDirectory() + "cctop-cc-live-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        // A real child of the test runner with an unrecognized name plays the host process.
        let fakeDir = NSTemporaryDirectory() + "cctop-fakehost-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: fakeDir, withIntermediateDirectories: true)
        let bin = (fakeDir as NSString).appendingPathComponent("fakehost")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: bin)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: bin)
        process.arguments = ["30"]
        try process.run()
        addTeardownBlock {
            process.terminate()
            process.waitUntilExit()
            try? FileManager.default.removeItem(atPath: fakeDir)
        }

        let pid = UInt32(process.processIdentifier)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("\(pid).json")
        var session = Session(sessionId: "cc-live", projectPath: "/tmp/p", branch: "main",
                              terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop))
        session.source = "cc"
        session.pid = pid
        session.pidStartTime = Session.processStartTime(pid: pid)
        session.lastActivity = Date().addingTimeInterval(-60)
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { bundleID in
                bundleID == HostAppBundleID.codexDesktop
            }
        )

        XCTAssertEqual(manager.sessions.map(\.lifecycle), [.active])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
    }

    func testIdentityPolicyNamesStableGroupingRules() {
        var codex = Session(sessionId: "codex-conversation", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        codex.source = Session.codexSource
        codex.lastActivity = Self.lifeNow.addingTimeInterval(-60)
        codex.pid = 31349

        var desktop = Session(sessionId: "desktop-conversation", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        desktop.source = "cc"
        desktop.lastActivity = Self.lifeNow.addingTimeInterval(-60)
        desktop.terminal = TerminalInfo(bundleId: HostAppBundleID.claudeDesktop)
        desktop.pid = 99

        var terminal = Session(sessionId: "terminal-conversation", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        terminal.source = "cc"
        terminal.lastActivity = Self.lifeNow.addingTimeInterval(-60)
        terminal.pid = 42

        XCTAssertEqual(SessionIdentityPolicy.stableKey(for: codex), "codex:codex-conversation")
        XCTAssertEqual(SessionIdentityPolicy.stableKey(for: desktop), "desktop:desktop-conversation")
        XCTAssertEqual(SessionIdentityPolicy.stableKey(for: terminal), "active:42")
    }

    func testConnectionStateUsesEndedAtForAllHosts() {
        var session = lifeSession(agoSeconds: 60)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)

        XCTAssertEqual(connection(session, .desktop, alive: true), .disconnected)
        XCTAssertEqual(connection(session, .terminal, alive: true), .disconnected)
        XCTAssertEqual(connection(session, .ambiguous, alive: true), .disconnected)
    }

    func testLifecycleMapsSameDisconnectedStateByHostPolicy() {
        let session = lifeSession(agoSeconds: 60, disconnectedAgoSeconds: 30)

        XCTAssertEqual(life(session, .desktop, alive: false), .dormant)
        XCTAssertEqual(life(session, .terminal, alive: false), .finished)
        XCTAssertEqual(life(session, .ambiguous, alive: false), .finished)
    }

    func testLifecycleDesktopAliveIsActive() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 0), .desktop, alive: true), .active)
    }

    func testLifecycleDesktopDeadButRecentIsDormant() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 60), .desktop, alive: false), .dormant)
    }

    func testLifecycleDesktopDeadAndAgedIsFinished() {
        XCTAssertEqual(
            life(lifeSession(agoSeconds: 100_000, disconnectedAgoSeconds: 100_000), .desktop, alive: false),
            .finished
        )
    }

    func testLifecycleDesktopDeadWithoutDisconnectedAtStartsDormant() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 600), .desktop, alive: false), .dormant)
    }

    // Issue #155 P4: absolute idle age-cap. A desktop session idle past the retention
    // window is finished outright — even while its app keeps running — so stale desktop
    // cards drain without depending on disconnectedAt (which is only stamped after the
    // session manages to go dormant, a circular dependency while the app stays open).
    func testLifecycleDesktopIdlePastRetentionIsFinishedEvenWhileAppRunning() {
        XCTAssertEqual(
            life(lifeSession(agoSeconds: 100_000), .desktop, alive: true, desktopAppRunning: true),
            .finished
        )
    }

    func testLifecycleDesktopIdlePastRetentionIsFinishedDespiteRecentDisconnect() {
        XCTAssertEqual(
            life(lifeSession(agoSeconds: 100_000, disconnectedAgoSeconds: 60), .desktop, alive: false),
            .finished
        )
    }

    func testLifecycleDesktopIdleWithinRetentionKeepsDormantGrace() {
        XCTAssertEqual(
            life(lifeSession(agoSeconds: 600, disconnectedAgoSeconds: 60), .desktop, alive: false),
            .dormant
        )
    }

    // The age-cap is desktop-only: a terminal session with a live PID is active no matter
    // how long it has been idle.
    func testLifecycleTerminalIdlePastRetentionWithLivePidStaysActive() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 100_000), .terminal, alive: true), .active)
    }

    func testLifecycleClaudeDesktopUsesDesktopDormantPolicy() {
        var session = lifeSession(agoSeconds: 600, disconnectedAgoSeconds: 60)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.claudeDesktop)

        XCTAssertEqual(session.hostClass, .desktop)
        XCTAssertEqual(life(session, session.hostClass, alive: false), .dormant)
        XCTAssertEqual(life(session, session.hostClass, alive: true), .active)
    }

    func testLifecycleUnknownHostDeadIsFinishedEvenIfRecent() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 60), .ambiguous, alive: false), .finished)
    }

    func testLifecycleTerminalAliveIsActive() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 0), .terminal, alive: true), .active)
    }

    // A dead terminal session is over — no dormant, even when recent.
    func testLifecycleTerminalDeadIsFinishedEvenIfRecent() {
        XCTAssertEqual(life(lifeSession(agoSeconds: 60), .terminal, alive: false), .finished)
    }

    func testLifecycleTerminalEndedAtIsFinishedEvenIfPidStillAlive() {
        var session = lifeSession(agoSeconds: 60)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)
        XCTAssertEqual(life(session, .terminal, alive: true), .finished)
    }

    func testLifecycleDesktopEndedAtUsesDesktopDormantRules() {
        var session = lifeSession(agoSeconds: 60, disconnectedAgoSeconds: 30)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)
        XCTAssertEqual(life(session, .desktop, alive: false), .dormant)
    }

    func testLifecycleDesktopEndedAtBeatsPidLiveness() {
        var session = lifeSession(agoSeconds: 60, disconnectedAgoSeconds: 30)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)
        XCTAssertEqual(life(session, .desktop, alive: true), .dormant)
    }

    func testLifecycleDesktopEndedAtBeatsDesktopAppRunning() {
        var session = lifeSession(agoSeconds: 60, disconnectedAgoSeconds: 30)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        session.endedAt = Self.lifeNow.addingTimeInterval(-30)
        XCTAssertEqual(connection(session, .desktop, alive: false, desktopAppRunning: true), .disconnected)
        XCTAssertEqual(life(session, .desktop, alive: false, desktopAppRunning: true), .dormant)
    }

    func testLifecycleDesktopAppRunningKeepsStaleCodexSessionActive() {
        var session = lifeSession(source: "codex", agoSeconds: 600, disconnectedAgoSeconds: 60)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        XCTAssertEqual(life(session, .desktop, alive: false, desktopAppRunning: true), .active)
    }

    func testLifecycleCodexDesktopHostPidSurvivesFalseAppRunningSignal() {
        var session = lifeSession(source: "codex", agoSeconds: 600, disconnectedAgoSeconds: 60)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        XCTAssertEqual(life(session, .desktop, alive: true, desktopAppRunning: false), .active)
    }

    func testLifecycleDesktopAppStoppedMakesRecentCodexSessionDormant() {
        var session = lifeSession(source: "codex", agoSeconds: 30, disconnectedAgoSeconds: 60)
        session.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        XCTAssertEqual(life(session, .desktop, alive: false, desktopAppRunning: false), .dormant)
    }

    func testLifecycleDesktopAppSignalDoesNotAffectCodexCliTerminal() {
        XCTAssertEqual(
            life(lifeSession(source: "codex", agoSeconds: 30), .terminal, alive: false, desktopAppRunning: true),
            .finished
        )
    }

    // Codex Desktop fallback: without app-level liveness, a live SHARED host PID must not keep a
    // stale conversation active.
    func testLifecycleCodexDesktopWithoutAppLivenessFallsBackToRecencyWhenStale() {
        XCTAssertEqual(life(lifeSession(source: "codex", agoSeconds: 600), .desktop, alive: true), .dormant)
    }

    // Codex Desktop fallback: without app-level liveness, recent activity still keeps the record active.
    func testLifecycleCodexDesktopWithoutAppLivenessFallsBackToRecentActivity() {
        XCTAssertEqual(life(lifeSession(source: "codex", agoSeconds: 30), .desktop, alive: false), .active)
    }

    // Codex CLI (terminal) uses its REAL per-process PID, not recency — never remove a live silent CLI.
    func testLifecycleCodexCliTerminalUsesRealPidNotRecency() {
        XCTAssertEqual(life(lifeSession(source: "codex", agoSeconds: 600), .terminal, alive: true), .active)
    }

    // Ambiguous + Codex with a LIVE pid stays active: ambiguous is the safety bucket, and a Codex
    // CLI without a recognized bundle id still has a real per-process PID — the shared-PID recency
    // carve-out applies ONLY to Codex Desktop (hostClass == .desktop), not to ambiguous.
    func testLifecycleAmbiguousCodexWithLivePidStaysActive() {
        XCTAssertEqual(life(lifeSession(source: "codex", agoSeconds: 600), .ambiguous, alive: true), .active)
    }

    // Fallback blocker: a Codex Desktop session with source == nil (pre-harness-migration files)
    // must still get the recency carve-out via its trusted bundle id when app liveness is absent.
    func testLifecycleCodexDesktopWithoutSourceUsesRecencyFallback() {
        var stale = lifeSession(agoSeconds: 600)   // source nil, stale activity
        stale.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        // A live SHARED host PID must not keep a stale conversation active.
        XCTAssertEqual(life(stale, .desktop, alive: true), .dormant)

        var recent = lifeSession(agoSeconds: 30)   // source nil, recent activity
        recent.terminal = TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        // Recent activity means active even with a dead/irrelevant PID.
        XCTAssertEqual(life(recent, .desktop, alive: false), .active)
    }

    // MARK: - Classification filtering with stub providers (no SQLite or metadata files on disk)

    func testClassificationSnapshotFiltersArchivedSubagentExecHelperAndOrphanedSessions() {
        let archived = candidate(sessionId: "archived-thread", pid: 1, bundleId: HostAppBundleID.codexDesktop,
                                 lifecycleRank: 0, source: Session.codexSource, path: "/archived.json")
        let subagent = candidate(sessionId: "subagent-thread", pid: 2, bundleId: HostAppBundleID.codexDesktop,
                                 lifecycleRank: 0, source: Session.codexSource, path: "/subagent.json")
        let execHelper = candidate(sessionId: "exec-helper-thread", pid: 3, bundleId: HostAppBundleID.codexDesktop,
                                   lifecycleRank: 0, source: Session.codexSource, path: "/exec.json")
        let archivedClaude = candidate(sessionId: "archived-claude", pid: 4, bundleId: HostAppBundleID.claudeDesktop,
                                       lifecycleRank: 0, source: "cc", path: "/claude-archived.json")
        // Ended, with authoritative metadata that does not know the session -> orphaned, filtered.
        let orphanClaude = candidate(sessionId: "orphan-claude", pid: 5, bundleId: HostAppBundleID.claudeDesktop,
                                     lifecycleRank: 0, source: "cc",
                                     endedAt: Date(timeIntervalSince1970: 2000), path: "/claude-orphan.json")
        let visibleCodex = candidate(sessionId: "visible-thread", pid: 6, bundleId: HostAppBundleID.codexDesktop,
                                     lifecycleRank: 0, source: Session.codexSource, path: "/visible.json")
        let visibleClaude = candidate(sessionId: "visible-claude", pid: 7, bundleId: HostAppBundleID.claudeDesktop,
                                      lifecycleRank: 0, source: "cc", path: "/claude-visible.json") { session in
            session.sessionName = "Visible Claude session"
        }
        let matchedEndedClaude = candidate(sessionId: "matched-ended-claude", pid: 8, bundleId: HostAppBundleID.claudeDesktop,
                                           lifecycleRank: 0, source: "cc",
                                           endedAt: Date(timeIntervalSince1970: 2000), path: "/claude-ended.json")

        let codexThreads = StubCodexThreadState(
            archived: ["archived-thread"],
            subagents: ["subagent-thread"],
            execHelpers: ["exec-helper-thread"]
        )
        let claudeMetadata = ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: ["archived-claude", "matched-ended-claude", "visible-claude"],
            archivedSessionIDs: ["archived-claude"],
            isAuthoritative: true
        )

        let classification = SessionManager.sessionClassificationSnapshot(
            in: [archived, subagent, execHelper, archivedClaude, orphanClaude, visibleCodex, visibleClaude, matchedEndedClaude],
            claudeMetadata: claudeMetadata,
            codexThreads: codexThreads
        )

        XCTAssertEqual(
            classification.displayCandidates.map(\.session.sessionId).sorted(),
            ["matched-ended-claude", "visible-claude", "visible-thread"]
        )
        XCTAssertEqual(classification.codexInternalHelperCandidates.map(\.session.sessionId), ["subagent-thread"])
        XCTAssertEqual(classification.archivedCodexThreadIDs, ["archived-thread"])
        XCTAssertEqual(classification.codexInternalHelperThreadIDs, ["subagent-thread"])
        XCTAssertEqual(classification.codexExecHelperThreadIDs, ["exec-helper-thread"])
        XCTAssertEqual(classification.archivedClaudeSessionIDs, ["archived-claude"])
    }

    func testClassificationSnapshotEmitsCleanupSourcesForArchivedDesktopSessions() {
        let archived = candidate(sessionId: "archived-thread", pid: 1, bundleId: HostAppBundleID.codexDesktop,
                                 lifecycleRank: 0, source: Session.codexSource, path: "/archived.json") { session in
            session.sessionName = "Archived desktop work"
        }
        let visible = candidate(sessionId: "visible-thread", pid: 2, bundleId: HostAppBundleID.codexDesktop,
                                lifecycleRank: 0, source: Session.codexSource, path: "/visible.json")
        let subagent = candidate(sessionId: "subagent-thread", pid: 3, bundleId: HostAppBundleID.codexDesktop,
                                 lifecycleRank: 0, source: Session.codexSource, path: "/subagent.json")

        let state = SessionManager.sessionClassificationSnapshot(
            in: [archived, visible, subagent],
            claudeMetadata: nil,
            codexThreads: StubCodexThreadState(
                archived: ["archived-thread"],
                subagents: ["subagent-thread"]
            )
        )

        XCTAssertEqual(state.displayCandidates.map(\.session.sessionId), ["visible-thread"])
        XCTAssertEqual(state.cleanupSources.map(\.sessionId), ["archived-thread"])
        XCTAssertEqual(state.cleanupSources.map(\.projectPath), ["/tmp/p"])
        XCTAssertEqual(state.cleanupSources.map(\.sessionName), ["Archived desktop work"])
        XCTAssertEqual(state.codexInternalHelperCandidates.map(\.session.sessionId), ["subagent-thread"])
    }

    func testClassificationSnapshotMapsDispositionsToAllowedActions() {
        let archivedCodex = candidate(sessionId: "archived-thread", pid: 1, bundleId: HostAppBundleID.codexDesktop,
                                      lifecycleRank: 0, source: Session.codexSource, path: "/archived.json")
        let archivedClaude = candidate(sessionId: "archived-claude", pid: 2, bundleId: HostAppBundleID.claudeDesktop,
                                       lifecycleRank: 0, source: "cc", path: "/archived-claude.json")
        let codexSubagent = candidate(sessionId: "subagent-thread", pid: 3, bundleId: HostAppBundleID.codexDesktop,
                                      lifecycleRank: 0, source: Session.codexSource, path: "/subagent.json")
        let codexExecHelper = candidate(sessionId: "exec-helper-thread", pid: 4, bundleId: HostAppBundleID.codexDesktop,
                                        lifecycleRank: 0, source: Session.codexSource, path: "/exec-helper.json")
        let autoHidden = candidate(sessionId: "auto-hidden", pid: 5, bundleId: HostAppBundleID.codexDesktop,
                                   lifecycleRank: 0, source: Session.codexSource, path: "/auto-hidden.json") { session in
            session.isSubagentSession = true
        }
        let persistedHidden = candidate(sessionId: "persisted-hidden", pid: 6, bundleId: "com.googlecode.iterm2",
                                        lifecycleRank: 0, source: "cc", path: "/persisted-hidden.json") { session in
            session.hidden = true
        }
        let terminalFinished = candidate(sessionId: "terminal-finished", pid: 7, bundleId: "com.googlecode.iterm2",
                                         lifecycleRank: 2, source: "cc", path: "/terminal-finished.json")
        let visible = candidate(sessionId: "visible-thread", pid: 8, bundleId: HostAppBundleID.codexDesktop,
                                lifecycleRank: 0, source: Session.codexSource, path: "/visible.json")

        let state = SessionManager.sessionClassificationSnapshot(
            in: [
                archivedCodex,
                archivedClaude,
                codexSubagent,
                codexExecHelper,
                autoHidden,
                persistedHidden,
                terminalFinished,
                visible,
            ],
            claudeMetadata: ClaudeDesktopSessionMetadataSnapshot(
                matchedSessionIDs: ["archived-claude"],
                archivedSessionIDs: ["archived-claude"],
                isAuthoritative: true
            ),
            codexThreads: StubCodexThreadState(
                archived: ["archived-thread"],
                subagents: ["subagent-thread"],
                execHelpers: ["exec-helper-thread"]
            )
        )

        XCTAssertEqual(
            state.displayCandidates.map(\.session.sessionId).sorted(),
            ["terminal-finished", "visible-thread"]
        )
        XCTAssertEqual(state.finishedNonDesktopCandidates.map(\.session.sessionId), ["terminal-finished"])
        XCTAssertEqual(
            state.cleanupSources.map(\.sessionId).sorted(),
            ["archived-claude", "archived-thread"]
        )
        XCTAssertEqual(state.autoHiddenSessions.map(\.1.sessionId), ["auto-hidden"])
        XCTAssertEqual(state.codexInternalHelperCandidates.map(\.session.sessionId), ["subagent-thread"])
        XCTAssertEqual(state.protectedProjectPathsForCleanup, ["/tmp/p"])
    }

    func testRecentResumeTargetsIncludeArchivedDesktopThreadsFromClassificationSnapshot() {
        let codexID = "019e1eff-3374-74b0-8d3d-6fba94e7d75f"
        let claudeID = "39253133-4a65-48fb-af2b-844463d3b5bb"
        let codex = candidate(
            sessionId: codexID,
            pid: 1,
            bundleId: HostAppBundleID.codexDesktop,
            lifecycleRank: SessionLifecycle.dormant.rawValue,
            source: Session.codexSource,
            lastActivity: Date(timeIntervalSince1970: 3000),
            path: "/codex.json"
        ) { session in
            session.sessionName = "Can you use product design skills for the cctop logo"
            session.desktopProjectName = "cctop"
        }
        let claude = candidate(
            sessionId: claudeID,
            pid: 2,
            bundleId: HostAppBundleID.claudeDesktop,
            lifecycleRank: SessionLifecycle.dormant.rawValue,
            source: Session.ccSource,
            lastActivity: Date(timeIntervalSince1970: 2000),
            path: "/claude.json"
        ) { session in
            session.sessionName = "Run plugin node:test suites in CI"
        }
        let classification = SessionManager.sessionClassificationSnapshot(
            in: [claude, codex],
            claudeMetadata: ClaudeDesktopSessionMetadataSnapshot(
                matchedSessionIDs: [claudeID],
                archivedSessionIDs: [claudeID],
                isAuthoritative: true
            ),
            codexThreads: StubCodexThreadState(archived: [codexID])
        )

        let targets = RecentResumeTarget.build(projects: [], classification: classification)

        XCTAssertEqual(targets.map(\.title), [
            "Can you use product design skills for the cctop logo",
            "Run plugin node:test suites in CI",
        ])
        XCTAssertEqual(targets.map(\.openActionLabel), [
            "Open Codex Desktop",
            "Open Claude Desktop",
        ])
        XCTAssertEqual(targets.map(\.inlineActionLabel), [
            "Open Codex",
            "Open Claude",
        ])
        XCTAssertEqual(targets.map(\.metadataText), [
            "Archived \u{00B7} Codex \u{00B7} /tmp/p",
            "Archived \u{00B7} Claude \u{00B7} /tmp/p",
        ])
        XCTAssertFalse(targets.contains { $0.openActionLabel.contains("Thread") || ($0.inlineActionLabel?.contains("Thread") ?? false) })
        XCTAssertFalse(targets.contains { $0.showsFinderAction })
        XCTAssertFalse(targets.contains { $0.showsCopyPathAction })

        let visibleAfterHidingCodex = RecentResumeTarget.build(
            projects: [],
            classification: classification,
            excludingDesktopSessionIDs: Set([codex.session.cctopSessionId].compactMap { $0 })
        )
        XCTAssertEqual(visibleAfterHidingCodex.map(\.title), ["Run plugin node:test suites in CI"])
    }

    func testRecentResumeTargetsExcludeNonArchivedDesktopHiddenReasons() {
        let missing = candidate(
            sessionId: "missing-thread",
            pid: 1,
            bundleId: HostAppBundleID.codexDesktop,
            lifecycleRank: SessionLifecycle.dormant.rawValue,
            source: Session.codexSource,
            path: "/missing.json"
        )
        let classification = SessionManager.sessionClassificationSnapshot(
            in: [missing],
            claudeMetadata: nil,
            codexThreads: StubCodexThreadState(existing: [], archived: [])
        )

        XCTAssertTrue(RecentResumeTarget.build(projects: [], classification: classification).isEmpty)
    }

    func testRecentResumeTargetsExcludeArchivedCodexHelperThreads() {
        let visibleArchived = candidate(
            sessionId: "archived-visible",
            pid: 1,
            bundleId: HostAppBundleID.codexDesktop,
            lifecycleRank: SessionLifecycle.dormant.rawValue,
            source: Session.codexSource,
            path: "/archived-visible.json"
        ) { session in
            session.sessionName = "Visible archived thread"
        }
        let archivedSubagent = candidate(
            sessionId: "archived-subagent",
            pid: 2,
            bundleId: HostAppBundleID.codexDesktop,
            lifecycleRank: SessionLifecycle.dormant.rawValue,
            source: Session.codexSource,
            path: "/archived-subagent.json"
        ) { session in
            session.sessionName = "Archived subagent helper"
        }
        let archivedExecHelper = candidate(
            sessionId: "archived-exec-helper",
            pid: 3,
            bundleId: HostAppBundleID.codexDesktop,
            lifecycleRank: SessionLifecycle.dormant.rawValue,
            source: Session.codexSource,
            path: "/archived-exec-helper.json"
        ) { session in
            session.sessionName = "Archived exec helper"
        }
        let classification = SessionManager.sessionClassificationSnapshot(
            in: [visibleArchived, archivedSubagent, archivedExecHelper],
            codexThreads: StubCodexThreadState(
                archived: ["archived-visible", "archived-subagent", "archived-exec-helper"],
                subagents: ["archived-subagent"],
                execHelpers: ["archived-exec-helper"]
            )
        )

        let targets = RecentResumeTarget.build(projects: [], classification: classification)

        XCTAssertEqual(targets.map(\.title), ["Visible archived thread"])
    }

    @MainActor
    func testSessionManagerPublishesArchivedDesktopThreadsAsRecentTargets() throws {
        let root = NSTemporaryDirectory() + "cctop-recent-desktop-targets-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let codexID = "019e1eff-3374-74b0-8d3d-6fba94e7d75f"
        var codex = codexDesktopSession(sessionId: codexID, projectPath: "\(NSHomeDirectory())/projects/cctop")
        codex.sessionName = "Can you use product design skills for the cctop logo"
        codex.lastActivity = Date(timeIntervalSince1970: 3000)
        try codex.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("codex-\(codexID).json"))

        let claudeID = "39253133-4a65-48fb-af2b-844463d3b5bb"
        var claude = claudeDesktopSession(sessionId: claudeID, projectPath: "\(NSHomeDirectory())/projects/cctop")
        claude.sessionName = "Run plugin node:test suites in CI"
        claude.lastActivity = Date(timeIntervalSince1970: 2000)
        try claude.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("\(claudeID).json"))

        var sources = SessionDataSources.live()
        sources.sessionsDir = URL(fileURLWithPath: sessionsDir)
        sources.codexThreads = StubCodexThreadState(archived: [codexID])
        sources.claudeDesktopSessions = StubClaudeDesktopState(snapshot: ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: [claudeID],
            archivedSessionIDs: [claudeID],
            isAuthoritative: true
        ))
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }

        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(manager.recentResumeTargets.map(\.title), [
            "Can you use product design skills for the cctop logo",
            "Run plugin node:test suites in CI",
        ])
        XCTAssertEqual(manager.recentResumeTargets.map(\.openActionLabel), [
            "Open Codex Desktop",
            "Open Claude Desktop",
        ])
    }

    func testRecentResumeTargetProjectMetadataKeepsEvidenceBeforePath() {
        let project = RecentProject(
            projectPath: "/Users/dev/projects/a-very-long-parent-path/billing-api",
            projectName: "billing-api",
            lastBranch: "unknown",
            lastSessionAt: Date(),
            sessionCount: 2,
            lastEditor: "Cursor",
            lastAgent: "Codex",
            workspaceFile: nil
        )

        XCTAssertEqual(
            RecentResumeTarget.project(project).metadataText,
            "Codex \u{00B7} 2 sessions \u{00B7} /Users/dev/projects/a-very-long-parent-path/billing-api"
        )
    }

    func testRecentResumeTargetDesktopThreadOpenHelpTextUsesCautiousArchiveLanguage() {
        let target = RecentResumeTarget.desktopThread(.init(
            sessionId: "019e1eff-3374-74b0-8d3d-6fba94e7d75f",
            title: "Can you use product design skills for the cctop logo",
            projectPath: "/Users/dev/projects/cctop",
            projectName: "cctop",
            sourceApp: .codexDesktop,
            lastActiveAt: Date()
        ))

        XCTAssertEqual(
            target.openHelpText,
            "Open Codex Desktop; archived sessions may need manual lookup"
        )
        XCTAssertFalse(target.openHelpText.localizedCaseInsensitiveContains("return"))
        XCTAssertFalse(target.openHelpText.localizedCaseInsensitiveContains("resume"))
    }

    func testClassificationSnapshotDoesNotEmitCleanupSourceForArchivedDesktopWithoutKnownPath() {
        var session = Session(
            sessionId: "archived-root",
            projectPath: "/",
            branch: "main",
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        )
        session.source = Session.codexSource
        let archived = DedupCandidate(
            session: session,
            lifecycleRank: SessionLifecycle.active.rawValue,
            mtime: .distantPast,
            path: "/archived-root.json"
        )

        let state = SessionManager.sessionClassificationSnapshot(
            in: [archived],
            codexThreads: StubCodexThreadState(archived: ["archived-root"])
        )

        XCTAssertEqual(state.displayCandidates.map(\.session.sessionId), [])
        XCTAssertEqual(state.cleanupSources.map(\.sessionId), [])
    }

    func testClassificationSnapshotDoesNotEmitCleanupSourcesForNonArchivedHiddenDesktopReasons() {
        var missingCodexSession = Session(
            sessionId: "missing-codex",
            projectPath: "/Users/dev/.codex/worktrees/missing-codex",
            branch: "main",
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        )
        missingCodexSession.pid = 1
        missingCodexSession.source = Session.codexSource
        missingCodexSession.lastActivity = Date(timeIntervalSinceNow: -86_400)
        let missingCodex = DedupCandidate(
            session: missingCodexSession,
            lifecycleRank: SessionLifecycle.active.rawValue,
            mtime: .distantPast,
            path: "/missing-codex.json"
        )

        var orphanClaudeSession = Session(
            sessionId: "orphan-claude",
            projectPath: "/Users/dev/.codex/worktrees/orphan-claude",
            branch: "main",
            terminal: TerminalInfo(bundleId: HostAppBundleID.claudeDesktop)
        )
        orphanClaudeSession.pid = 2
        orphanClaudeSession.source = "cc"
        orphanClaudeSession.endedAt = Date(timeIntervalSince1970: 2000)
        let orphanClaude = DedupCandidate(
            session: orphanClaudeSession,
            lifecycleRank: SessionLifecycle.active.rawValue,
            mtime: .distantPast,
            path: "/orphan-claude.json"
        )

        var startupPlaceholderSession = Session(
            sessionId: "startup-placeholder",
            projectPath: "/Users/dev/.codex/worktrees/startup-placeholder",
            branch: "main",
            terminal: TerminalInfo(bundleId: HostAppBundleID.claudeDesktop)
        )
        startupPlaceholderSession.pid = 3
        startupPlaceholderSession.source = "cc"
        let startupPlaceholder = DedupCandidate(
            session: startupPlaceholderSession,
            lifecycleRank: SessionLifecycle.active.rawValue,
            mtime: .distantPast,
            path: "/startup-placeholder.json"
        )

        let state = SessionManager.sessionClassificationSnapshot(
            in: [missingCodex, orphanClaude, startupPlaceholder],
            claudeMetadata: ClaudeDesktopSessionMetadataSnapshot(
                matchedSessionIDs: [],
                archivedSessionIDs: [],
                isAuthoritative: true
            ),
            codexThreads: StubCodexThreadState(existing: [])
        )

        XCTAssertEqual(state.displayCandidates.map(\.session.sessionId), [String]())
        XCTAssertEqual(state.cleanupSources.map(\.sessionId), [String]())
    }

    func testClassificationSnapshotFiltersActiveNamelessIdleClaudeDesktopStartupSession() {
        let startupOnly = candidate(sessionId: "startup-only", pid: 1, bundleId: HostAppBundleID.claudeDesktop,
                                    lifecycleRank: 0, source: "cc", path: "/startup-only.json")
        let namedIdle = candidate(sessionId: "named-idle", pid: 2, bundleId: HostAppBundleID.claudeDesktop,
                                  lifecycleRank: 0, source: "cc", path: "/named-idle.json") { session in
            session.sessionName = "Real desktop session"
        }
        let promptedIdle = candidate(sessionId: "prompted-idle", pid: 3, bundleId: HostAppBundleID.claudeDesktop,
                                     lifecycleRank: 0, source: "cc", path: "/prompted-idle.json") { session in
            session.lastPrompt = "Keep me visible"
        }
        let toolIdle = candidate(sessionId: "tool-idle", pid: 4, bundleId: HostAppBundleID.claudeDesktop,
                                 lifecycleRank: 0, source: "cc", path: "/tool-idle.json") { session in
            session.lastTool = "Read"
        }
        let toolDetailIdle = candidate(sessionId: "tool-detail-idle", pid: 5, bundleId: HostAppBundleID.claudeDesktop,
                                       lifecycleRank: 0, source: "cc", path: "/tool-detail-idle.json") { session in
            session.lastToolDetail = "README.md"
        }
        let notificationIdle = candidate(sessionId: "notification-idle", pid: 6, bundleId: HostAppBundleID.claudeDesktop,
                                         lifecycleRank: 0, source: "cc", path: "/notification-idle.json") { session in
            session.notificationMessage = "Permission requested"
        }
        let subagentIdle = candidate(sessionId: "subagent-idle", pid: 7, bundleId: HostAppBundleID.claudeDesktop,
                                     lifecycleRank: 0, source: "cc", path: "/subagent-idle.json") { session in
            session.activeSubagents = [
                SubagentInfo(agentId: "agent-1", agentType: "reviewer", startedAt: Date(timeIntervalSince1970: 100))
            ]
        }

        let classification = SessionManager.sessionClassificationSnapshot(
            in: [startupOnly, namedIdle, promptedIdle, toolIdle, toolDetailIdle, notificationIdle, subagentIdle],
            codexThreads: StubCodexThreadState(),
            claudeDesktopSessions: StubClaudeDesktopState(snapshot: ClaudeDesktopSessionMetadataSnapshot())
        )

        XCTAssertEqual(
            classification.displayCandidates.map(\.session.sessionId).sorted(),
            ["named-idle", "notification-idle", "prompted-idle", "subagent-idle", "tool-detail-idle", "tool-idle"]
        )
    }

    // The display path never deletes files, so unreadable external stores must fail OPEN: the
    // sessions stay visible for the pass rather than vanishing on lookup uncertainty.
    func testClassificationSnapshotFailsOpenWhenExternalStoresAreUnreadable() {
        let codexThread = candidate(sessionId: "maybe-archived", pid: 1, bundleId: HostAppBundleID.codexDesktop,
                                    lifecycleRank: 0, source: Session.codexSource, path: "/maybe.json")
        let claudeSession = candidate(sessionId: "maybe-orphaned", pid: 2, bundleId: HostAppBundleID.claudeDesktop,
                                      lifecycleRank: 0, source: "cc",
                                      endedAt: Date(timeIntervalSince1970: 2000), path: "/claude-maybe.json")
        let claudeStartupOnly = candidate(sessionId: "maybe-startup-only", pid: 3, bundleId: HostAppBundleID.claudeDesktop,
                                          lifecycleRank: 0, source: "cc", path: "/claude-startup-maybe.json")

        let classification = SessionManager.sessionClassificationSnapshot(
            in: [codexThread, claudeSession, claudeStartupOnly],
            codexThreads: StubCodexThreadState(archived: nil, subagents: nil, execHelpers: nil),
            claudeDesktopSessions: StubClaudeDesktopState(snapshot: nil)
        )

        XCTAssertEqual(
            classification.displayCandidates.map(\.session.sessionId).sorted(),
            ["maybe-archived", "maybe-orphaned", "maybe-startup-only"]
        )
        XCTAssertEqual(classification.codexInternalHelperCandidates.map(\.session.sessionId), [])
        XCTAssertEqual(classification.cleanupSources.map(\.sessionId), [])
    }

    @MainActor
    func testCodexClassificationDoesNotOscillateAcrossTransientUnreadableSnapshot() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-classification-retention-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let initialIDs = Set(["archived", "missing", "internal", "exec-helper", "visible"])
        var initial = CodexThreadStateIndex()
        initial.existingThreadIDs = initialIDs.subtracting(["missing"])
        initial.archivedThreadIDs = ["archived"]
        initial.internalHelperThreadIDs = ["internal"]
        initial.execHelperThreadIDs = ["exec-helper"]

        let changedIDs = initialIDs.union(["new"])
        var changed = CodexThreadStateIndex()
        changed.existingThreadIDs = changedIDs

        let codexState = SequencedCodexClassificationState(
            snapshots: [.available(initial), .unreadable, .available(changed)]
        )
        var sources = SessionDataSources.live()
        sources.sessionsDir = URL(fileURLWithPath: sessionsDir)
        sources.codexThreads = codexState
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in true }
        sources.processAlive = { _ in true }
        sources.now = { now }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        func record(_ sessionID: String, desktop: Bool = true) -> (url: URL, session: Session) {
            var session = desktop
                ? codexDesktopSession(sessionId: sessionID, projectPath: "/tmp/\(sessionID)")
                : codexTerminalSession(sessionId: sessionID, projectPath: "/tmp/\(sessionID)")
            session.lastActivity = now.addingTimeInterval(-SessionManager.codexMissingThreadGraceSeconds - 1)
            return (
                URL(fileURLWithPath: (sessionsDir as NSString).appendingPathComponent("codex-\(sessionID).json")),
                session
            )
        }

        let initialRecords = [
            record("archived"),
            record("missing"),
            record("internal", desktop: false),
            record("exec-helper"),
            record("visible"),
        ]
        let first = manager.deriveSessionClassification(from: initialRecords)
        XCTAssertEqual(first.displayCandidates.map(\.session.sessionId), ["visible"])

        let second = manager.deriveSessionClassification(from: initialRecords + [record("new")])
        XCTAssertEqual(second.displayCandidates.map(\.session.sessionId), ["visible", "new"])
        XCTAssertEqual(second.archivedCodexThreadIDs, ["archived"])
        XCTAssertEqual(second.missingCodexDesktopThreadIDs, ["missing"])
        XCTAssertEqual(second.codexInternalHelperThreadIDs, ["internal"])
        XCTAssertEqual(second.codexExecHelperThreadIDs, ["exec-helper"])

        let third = manager.deriveSessionClassification(from: initialRecords + [record("new")])
        XCTAssertEqual(
            third.displayCandidates.map(\.session.sessionId),
            ["archived", "missing", "internal", "exec-helper", "visible", "new"]
        )
        XCTAssertEqual(third.archivedCodexThreadIDs, [])
        XCTAssertEqual(third.missingCodexDesktopThreadIDs, [])
        XCTAssertEqual(third.codexInternalHelperThreadIDs, [])
        XCTAssertEqual(third.codexExecHelperThreadIDs, [])
        XCTAssertEqual(codexState.requests, [initialIDs, changedIDs, changedIDs])
    }

    func testCodexClassificationMemoryCarriesOnlyUnknownIDsAndClearsOnMissing() throws {
        let initialIDs = Set(["changed", "retained", "known-missing"])
        var initial = CodexThreadStateIndex()
        initial.existingThreadIDs = ["changed", "retained"]
        initial.archivedThreadIDs = ["changed"]
        initial.internalHelperThreadIDs = ["retained"]

        var memory = CodexThreadClassificationMemory()
        _ = memory.effectiveIndex(from: .available(initial), matching: initialIDs)

        let partialIDs = initialIDs.union(["new"])
        var partial = CodexThreadStateIndex()
        partial.existingThreadIDs = ["changed"]
        partial.unknownThreadIDs = ["retained", "known-missing", "new"]
        let effective = try XCTUnwrap(memory.effectiveIndex(from: .available(partial), matching: partialIDs))

        XCTAssertEqual(effective.existingThreadIDs, ["changed", "retained"])
        XCTAssertEqual(effective.archivedThreadIDs, [])
        XCTAssertEqual(effective.internalHelperThreadIDs, ["retained"])
        XCTAssertEqual(effective.unknownThreadIDs, ["new"])

        XCTAssertNil(memory.effectiveIndex(from: .missing, matching: partialIDs))
        let afterMissing = try XCTUnwrap(memory.effectiveIndex(from: .unreadable, matching: partialIDs))
        XCTAssertEqual(afterMissing.existingThreadIDs, [])
        XCTAssertEqual(afterMissing.internalHelperThreadIDs, [])
        XCTAssertEqual(afterMissing.unknownThreadIDs, partialIDs)
    }

    // MARK: - Lifecycle derivation via injected process liveness

    // Lifecycle used to be testable only by fabricating PIDs that could not exist; with liveness
    // injected, the same session flips between finished and active purely by the injected answer.
    func testBuildCandidatesDerivesLifecycleFromInjectedProcessAlive() {
        var session = Session(
            sessionId: "terminal-session", projectPath: "/tmp/p", branch: "main",
            terminal: TerminalInfo(program: "zsh", bundleId: "com.googlecode.iterm2")
        )
        session.source = "cc"
        session.pid = 12345
        session.lastActivity = Self.lifeNow.addingTimeInterval(-60)
        let files = [(url: URL(fileURLWithPath: "/nonexistent/12345.json"), session: session)]
        let noDesktopApps = DesktopAppConnectionLookup { _ in false }

        let dead = SessionManager.buildCandidates(
            files, now: Self.lifeNow,
            desktopAppConnectionLookup: noDesktopApps,
            claudeMetadata: nil,
            codexThreads: StubCodexThreadState(),
            processAlive: { _ in false }
        )
        XCTAssertEqual(dead.map(\.session.lifecycle), [.finished])

        let alive = SessionManager.buildCandidates(
            files, now: Self.lifeNow,
            desktopAppConnectionLookup: noDesktopApps,
            claudeMetadata: nil,
            codexThreads: StubCodexThreadState(),
            processAlive: { _ in true }
        )
        XCTAssertEqual(alive.map(\.session.lifecycle), [.active])
    }

    func testChildProcessProbeTreatsProcListChildPidsResultAsPIDCount() {
        XCTAssertEqual(ProcessChildPIDProbe.capacity(fromReportedCount: 1), 1)
        XCTAssertEqual(ProcessChildPIDProbe.bufferSize(forCapacity: 1), Int32(MemoryLayout<pid_t>.size))
        XCTAssertEqual(ProcessChildPIDProbe.returnedCount(1, capacity: 1), 1)
    }

    // MARK: - Idle timeout with an injected clock

    func testAdjustIdleTimeoutUsesInjectedNow() {
        var session = Session(sessionId: "s", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo())
        session.status = .waitingInput
        session.lastActivity = Date(timeIntervalSince1970: 1_000_000)

        let justUnderTimeout = session.lastActivity.addingTimeInterval(3_599)
        XCTAssertEqual(SessionManager.adjustIdleTimeout(session, now: justUnderTimeout).status, .waitingInput)

        let pastTimeout = session.lastActivity.addingTimeInterval(3_601)
        XCTAssertEqual(SessionManager.adjustIdleTimeout(session, now: pastTimeout).status, .idle)

        // Only waitingInput times out; other statuses pass through untouched.
        var working = session
        working.status = .working
        XCTAssertEqual(SessionManager.adjustIdleTimeout(working, now: pastTimeout).status, .working)
    }
}

private final class SequencedCodexClassificationState: CodexThreadStateProviding {
    private var snapshots: [CodexThreadStateSnapshot]
    private(set) var requests: [Set<String>] = []

    init(snapshots: [CodexThreadStateSnapshot]) {
        self.snapshots = snapshots
    }

    func stateSnapshot(matching threadIDs: Set<String>) -> CodexThreadStateSnapshot {
        guard !threadIDs.isEmpty else { return .available(CodexThreadStateIndex()) }
        requests.append(threadIDs)
        return snapshots.removeFirst()
    }

    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex? {
        nil
    }

    func existingThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        nil
    }

    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        nil
    }

    func internalHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        nil
    }

    func execHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        nil
    }

    func projectNames(matching threadIDs: Set<String>) -> [String: String]? {
        nil
    }
}

private final class RecordingCodexThreadState: CodexThreadStateProviding {
    private let internalHelpers: Set<String>
    private let projectNamesByThreadID: [String: String]
    private(set) var stateIndexRequests: [Set<String>] = []
    private(set) var internalHelperRequests: [Set<String>] = []
    private(set) var projectNameRequests: [Set<String>] = []

    init(internalHelpers: Set<String> = [], projectNamesByThreadID: [String: String]) {
        self.internalHelpers = internalHelpers
        self.projectNamesByThreadID = projectNamesByThreadID
    }

    func stateIndex(matching threadIDs: Set<String>) -> CodexThreadStateIndex? {
        stateIndexRequests.append(threadIDs)
        var index = CodexThreadStateIndex()
        index.existingThreadIDs = threadIDs
        index.internalHelperThreadIDs = internalHelpers.intersection(threadIDs)
        index.projectNamesByThreadID = projectNamesByThreadID.filter { threadIDs.contains($0.key) }
        return index
    }

    func existingThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        threadIDs
    }

    func archivedThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        []
    }

    func internalHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        internalHelperRequests.append(threadIDs)
        return internalHelpers.intersection(threadIDs)
    }

    func execHelperThreadIDs(matching threadIDs: Set<String>) -> Set<String>? {
        []
    }

    func projectNames(matching threadIDs: Set<String>) -> [String: String]? {
        projectNameRequests.append(threadIDs)
        return projectNamesByThreadID.filter { threadIDs.contains($0.key) }
    }
}
