import Darwin
import XCTest
@testable import CctopMenubar

final class SessionManagerVisibilityTests: XCTestCase {
    private func codexTitleGenerationPrompt(for userPrompt: String = "Why do I have several memories sessions?") -> String {
        """
        You are a helpful assistant. You will be presented with a user prompt, and your job is to provide a short title for a task that will be created from that prompt.
        The tasks typically have to do with coding-related tasks, for example requests for bug fixes or questions about a codebase. The title you generate will be shown in the UI to represent the prompt.
        Generate a concise UI title (up to 36 characters) for this task.
        Fill the structured title field with plain text.

        User prompt:
        \(userPrompt)
        """
    }

    // MARK: - Manual session visibility

    @MainActor
    func testManualHideIsImmediatePersistentAndLeavesTrackingIntact() throws {
        let root = NSTemporaryDirectory() + "cctop-manual-hide-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let suiteName = "cctop-manual-hide-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)

        for pid in 4_201...4_203 {
            var session = Session(
                sessionId: "session-\(pid)",
                projectPath: (root as NSString).appendingPathComponent("worktrees/\(pid)"),
                branch: "main",
                terminal: TerminalInfo(program: "zsh")
            )
            session.pid = UInt32(pid)
            session.status = .working
            try session.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("\(pid).json"))
        }

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { _ in true },
            manualSessionVisibility: visibility
        )
        let originalOrder = manager.sessions.map { SessionIdentityPolicy.stableKey(for: $0) }
        let hidden = try XCTUnwrap(manager.sessions.dropFirst().first)
        let hiddenStableKey = SessionIdentityPolicy.stableKey(for: hidden)
        let hiddenSessionID = try XCTUnwrap(hidden.cctopSessionId)

        manager.hideSession(hidden)

        XCTAssertEqual(
            manager.sessions.map { SessionIdentityPolicy.stableKey(for: $0) },
            originalOrder.filter { $0 != hiddenStableKey }
        )
        XCTAssertEqual(StatusCounts(sessions: manager.sessions).total, 2)
        XCTAssertEqual(
            DisplayStateWriter.snapshot(
                sessions: manager.sessions,
                theme: .claude,
                appRunning: true,
                appIdentity: nil,
                now: Date()
            ).sessions.count,
            2
        )
        XCTAssertTrue(manager.cleanupActiveProjectPaths.contains(hidden.projectPath))
        let hiddenPath = (sessionsDir as NSString).appendingPathComponent("\(hidden.pid!).json")
        XCTAssertFalse(try Session.fromFile(path: hiddenPath).hidden)

        manager.loadSessions()
        XCTAssertEqual(
            manager.sessions.map { SessionIdentityPolicy.stableKey(for: $0) },
            originalOrder.filter { $0 != hiddenStableKey }
        )
        XCTAssertTrue(manager.cleanupActiveProjectPaths.contains(hidden.projectPath))

        let reloaded = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { _ in true },
            manualSessionVisibility: visibility
        )
        XCTAssertFalse(reloaded.sessions.contains { $0.cctopSessionId == hiddenSessionID })

        try FileManager.default.removeItem(atPath: hiddenPath)
        reloaded.loadSessions()
        XCTAssertFalse(visibility.hiddenSessionIDs.contains(hiddenSessionID))
    }

    @MainActor
    func testLegacyCodexManualHideMigratesBeforePublishingAndSurvivesReloads() throws {
        let root = NSTemporaryDirectory() + "cctop-legacy-manual-hide-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let identityBlockerPath = (root as NSString).appendingPathComponent("session-identities")
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: identityBlockerPath))
        let threadID = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let currentObservationID = "current-observation"
        let conflictingObservationID = "conflicting-observation"
        let cctopSessionID = "11111111-1111-4111-8111-111111111111"
        let conflictingCctopSessionID = "22222222-2222-4222-8222-222222222222"
        var session = Session(
            sessionId: threadID,
            projectPath: "/tmp/legacy-hidden",
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        session.cctopSessionId = nil
        session.harnessSessionId = threadID
        session.source = Session.codexSource
        session.pid = 4_204
        session.status = .waitingInput
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-\(threadID).json")
        try session.writeToFile(path: sessionPath)
        var current = Session(
            sessionId: currentObservationID,
            projectPath: "/tmp/legacy-hidden",
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        current.cctopSessionId = cctopSessionID
        current.harnessSessionId = threadID
        current.source = Session.codexSource
        current.pid = 4_205
        current.status = .waitingInput
        try current.writeToFile(
            path: (sessionsDir as NSString).appendingPathComponent("codex-\(currentObservationID).json")
        )
        var conflicting = current
        conflicting.sessionId = conflictingObservationID
        conflicting.cctopSessionId = conflictingCctopSessionID
        let conflictingPath = (sessionsDir as NSString).appendingPathComponent("codex-\(conflictingObservationID).json")
        try conflicting.writeToFile(path: conflictingPath)

        let suiteName = "cctop-legacy-manual-hide-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["codex:\(threadID)"], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        let visibility = ManualSessionVisibilityStore(defaults: defaults)

        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), manualSessionVisibility: visibility)
        sources.codexThreads = StubCodexThreadState(
            existing: [threadID, currentObservationID, conflictingObservationID],
            archived: []
        )
        sources.processAlive = { _ in true }
        var postedNotificationIDs: [String] = []
        sources.notificationsEnabled = { true }
        sources.notificationClient = SessionNotificationClient(
            add: { request, completion in
                postedNotificationIDs.append(request.identifier)
                completion(nil)
            },
            removePending: { _ in },
            removeDelivered: { _ in }
        )
        let historyManager = HistoryManager(historyDir: URL(fileURLWithPath: historyDir))
        let manager = SessionManager(historyManager: historyManager, dataSources: sources, startMonitoring: false)

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(postedNotificationIDs.isEmpty)
        XCTAssertTrue(visibility.hiddenSessionIDs.isEmpty)
        XCTAssertNil(try Session.fromFile(path: sessionPath).cctopSessionId)
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )

        try FileManager.default.removeItem(atPath: conflictingPath)
        manager.loadSessions()

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(postedNotificationIDs.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [cctopSessionID])
        XCTAssertNil(try Session.fromFile(path: sessionPath).cctopSessionId)
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )

        try FileManager.default.removeItem(atPath: identityBlockerPath)
        manager.loadSessions()

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [cctopSessionID])
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )
        XCTAssertTrue(postedNotificationIDs.isEmpty)
        waitForIdentityMigrationQueue(manager)

        manager.loadSessions()
        XCTAssertNil(defaults.object(forKey: ManualSessionVisibilityStore.legacyDefaultsKey))
        manager.loadSessions()
        XCTAssertTrue(manager.sessions.isEmpty)

        let reloaded = SessionManager(historyManager: historyManager, dataSources: sources, startMonitoring: false)
        XCTAssertTrue(reloaded.sessions.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [cctopSessionID])
        XCTAssertTrue(postedNotificationIDs.isEmpty)
    }

    @MainActor
    func testUnresolvedArchivedCodexLegacyHideKeepsCleanupAvailable() throws {
        let root = NSTemporaryDirectory() + "cctop-unresolved-legacy-archived-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let identityBlockerPath = (root as NSString).appendingPathComponent("session-identities")
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: identityBlockerPath))
        let threadID = "bbbbbbbb-cccc-4ddd-8eee-ffffffffffff"
        let projectPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        var session = codexDesktopSession(sessionId: threadID, projectPath: projectPath)
        session.cctopSessionId = nil
        session.harnessSessionId = threadID
        session.endedAt = Date(timeIntervalSince1970: 2_100)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-\(threadID).json")
        try session.writeToFile(path: sessionPath)
        let unrelatedThreadID = "cccccccc-dddd-4eee-8fff-000000000001"
        let unrelatedProjectPath = (root as NSString).appendingPathComponent("unrelated-project")
        try FileManager.default.createDirectory(atPath: unrelatedProjectPath, withIntermediateDirectories: true)
        var previous = Session(
            sessionId: "previous-hidden-project",
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        previous.endedAt = Date(timeIntervalSince1970: 2_000)
        try previous.writeToFile(path: (historyDir as NSString).appendingPathComponent("previous-hidden-project.json"))
        let unrelated = codexDesktopSession(
            sessionId: unrelatedThreadID,
            projectPath: unrelatedProjectPath
        )
        let unrelatedCctopSessionID = try XCTUnwrap(unrelated.cctopSessionId)
        try unrelated.writeToFile(
            path: (sessionsDir as NSString).appendingPathComponent("codex-\(unrelatedThreadID).json")
        )

        let suiteName = "cctop-unresolved-legacy-archived-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["codex:\(threadID)"], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        let visibility = ManualSessionVisibilityStore(defaults: defaults)

        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), manualSessionVisibility: visibility)
        sources.codexThreads = StubCodexThreadState(
            existing: [threadID, unrelatedThreadID],
            archived: [threadID, unrelatedThreadID]
        )
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in true }
        sources.processAlive = { _ in true }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(
            manager.cleanupSources.filter { $0.sessionId == threadID }.map(\.projectPath),
            [projectPath]
        )
        XCTAssertEqual(
            manager.cleanupSources.filter { $0.sessionId == unrelatedThreadID }.map(\.projectPath),
            [unrelatedProjectPath]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertTrue(visibility.hiddenSessionIDs.isEmpty)
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )

        let brokenPath = (sessionsDir as NSString).appendingPathComponent("broken.json")
        try FileManager.default.removeItem(atPath: identityBlockerPath)
        try Data("not valid session json".utf8).write(to: URL(fileURLWithPath: brokenPath))
        manager.loadSessions()

        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(manager.cleanupSources.filter { $0.sessionId == threadID }.count, 1)
        XCTAssertEqual(manager.cleanupSources.filter { $0.sessionId == unrelatedThreadID }.count, 1)
        XCTAssertEqual(visibility.hiddenSessionIDs.count, 1)
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )
        waitForIdentityMigrationQueue(manager)

        try FileManager.default.removeItem(atPath: brokenPath)
        manager.loadSessions()

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertNil(defaults.object(forKey: ManualSessionVisibilityStore.legacyDefaultsKey))
        XCTAssertEqual(manager.cleanupSources.filter { $0.sessionId == threadID }.count, 1)
        XCTAssertEqual(manager.cleanupSources.filter { $0.sessionId == unrelatedThreadID }.count, 1)
        XCTAssertEqual(manager.recentResumeTargets.compactMap(\.cctopSessionId), [unrelatedCctopSessionID])
        XCTAssertEqual(manager.recentResumeTargets.map(\.projectPath), [unrelatedProjectPath])
    }

    @MainActor
    func testProcessScopedLegacyKeyDoesNotFreezeArchivedProjectionsDuringPartialInventory() throws {
        let root = NSTemporaryDirectory() + "cctop-process-key-partial-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let threadID = "dddddddd-eeee-4fff-8000-111111111111"
        let projectPath = (root as NSString).appendingPathComponent("project")
        let session = codexDesktopSession(sessionId: threadID, projectPath: projectPath)
        try session.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("codex-\(threadID).json"))
        try Data("not valid session json".utf8).write(
            to: URL(fileURLWithPath: (sessionsDir as NSString).appendingPathComponent("broken.json"))
        )

        let suiteName = "cctop-process-key-partial-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["active:42"], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        let visibility = ManualSessionVisibilityStore(defaults: defaults)

        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), manualSessionVisibility: visibility)
        sources.codexThreads = StubCodexThreadState(existing: [threadID], archived: [threadID])
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in true }
        sources.processAlive = { _ in true }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(manager.recentResumeTargets.compactMap(\.cctopSessionId), [session.cctopSessionId])
        XCTAssertEqual(manager.cleanupSources.filter { $0.sessionId == threadID }.map(\.projectPath), [projectPath])
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["active:42"]
        )
    }

    @MainActor
    func testUnresolvedLegacyFinishedSessionKeepsEvidenceAndRecentFrozen() throws {
        let root = NSTemporaryDirectory() + "cctop-unresolved-legacy-finished-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let identityBlockerPath = (root as NSString).appendingPathComponent("session-identities")
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: identityBlockerPath))
        let projectPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        var history = Session(
            sessionId: "previous-finished-project",
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        history.endedAt = Date(timeIntervalSince1970: 2_000)
        try history.writeToFile(path: (historyDir as NSString).appendingPathComponent("history.json"))

        let threadID = "11111111-2222-4333-8444-555555555555"
        var finished = Session(
            sessionId: threadID,
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        finished.cctopSessionId = nil
        finished.harnessSessionId = threadID
        finished.source = Session.codexSource
        finished.pid = 4_205
        finished.status = .working
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-\(threadID).json")
        try finished.writeToFile(path: sessionPath)
        let fastPeerID = "finished-peer-fast"
        var fastPeer = finished
        fastPeer.sessionId = fastPeerID
        fastPeer.cctopSessionId = "00000000-0000-4000-8000-000000000001"
        fastPeer.pid = 4_206
        let fastPeerPath = (sessionsDir as NSString).appendingPathComponent("codex-\(fastPeerID).json")
        try fastPeer.writeToFile(path: fastPeerPath)

        let desktopPeerID = "finished-peer-desktop"
        let desktopPeerProjectPath = (root as NSString).appendingPathComponent("desktop-peer-project")
        try FileManager.default.createDirectory(atPath: desktopPeerProjectPath, withIntermediateDirectories: true)
        var desktopPeer = codexDesktopSession(sessionId: desktopPeerID, projectPath: desktopPeerProjectPath)
        desktopPeer.cctopSessionId = "00000000-0000-4000-8000-000000000002"
        desktopPeer.harnessSessionId = threadID
        desktopPeer.lastActivity = Date(timeIntervalSince1970: 2_100)
        desktopPeer.disconnectedAt = Date(timeIntervalSince1970: 2_100)
        desktopPeer.endedAt = Date(timeIntervalSince1970: 2_100)
        let desktopPeerPath = (sessionsDir as NSString).appendingPathComponent("codex-\(desktopPeerID).json")
        try desktopPeer.writeToFile(path: desktopPeerPath)

        let legacyPeerID = "finished-peer-legacy"
        var legacyPeer = codexDesktopSession(sessionId: legacyPeerID, projectPath: projectPath)
        legacyPeer.cctopSessionId = "00000000-0000-4000-8000-000000000003"
        legacyPeer.harnessSessionId = threadID
        legacyPeer.lastActivity = Date(timeIntervalSince1970: 2_100)
        legacyPeer.disconnectedAt = Date(timeIntervalSince1970: 2_100)
        legacyPeer.endedAt = Date(timeIntervalSince1970: 2_100)
        let legacyPeerPath = (sessionsDir as NSString).appendingPathComponent(
            "33333333-3333-4333-8333-333333333333.json"
        )
        try legacyPeer.writeToFile(path: legacyPeerPath)
        let finishedPeerIDs = [fastPeerID, desktopPeerID, legacyPeerID]
        let finishedPeerPaths = [fastPeerPath, desktopPeerPath, legacyPeerPath]

        let suiteName = "cctop-unresolved-legacy-finished-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["codex:\(threadID)"], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        let visibility = ManualSessionVisibilityStore(defaults: defaults)

        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), manualSessionVisibility: visibility)
        sources.codexThreads = StubCodexThreadState(existing: Set([threadID] + finishedPeerIDs), archived: [])
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertTrue(manager.cleanupSources.contains { $0.projectPath == projectPath })
        XCTAssertEqual(
            manager.cleanupSources.filter { $0.sessionId == desktopPeerID }.map(\.projectPath),
            [desktopPeerProjectPath]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertTrue(finishedPeerPaths.allSatisfy(FileManager.default.fileExists(atPath:)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir), ["history.json"])
        XCTAssertTrue(visibility.hiddenSessionIDs.isEmpty)
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )

        manager.garbageCollectFinished()
        XCTAssertTrue(finishedPeerPaths.allSatisfy(FileManager.default.fileExists(atPath:)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir), ["history.json"])
        try finishedPeerPaths.forEach { try FileManager.default.removeItem(atPath: $0) }

        manager.loadSessions()
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(manager.cleanupSources.filter { $0.sessionId == threadID }.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir), ["history.json"])

        let readyPath = (root as NSString).appendingPathComponent("identity-lock-ready")
        let lockHolder = try startSessionLockHolder(
            lockPath: sessionPath + ".lock",
            readyPath: readyPath,
            holdSeconds: 10
        )
        defer { terminateProcess(lockHolder) }

        try FileManager.default.removeItem(atPath: identityBlockerPath)
        manager.loadSessions()
        XCTAssertNil(manager.sessionFileCache[sessionPath]?.session.cctopSessionId)
        waitForIdentityMigrationQueue(manager)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        let migratedSessionIDs = visibility.hiddenSessionIDs
        XCTAssertEqual(migratedSessionIDs.count, 1)
        XCTAssertNil(try Session.fromFile(path: sessionPath).cctopSessionId)
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(manager.cleanupSources.filter { $0.sessionId == threadID }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir), ["history.json"])

        manager.loadSessions()
        waitForIdentityMigrationQueue(manager)

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertEqual(visibility.hiddenSessionIDs, migratedSessionIDs)
        XCTAssertNil(try Session.fromFile(path: sessionPath).cctopSessionId)
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(manager.cleanupSources.filter { $0.sessionId == threadID }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir), ["history.json"])

        terminateProcess(lockHolder)
        manager.loadSessions()
        waitForIdentityMigrationQueue(manager)
        XCTAssertEqual(try Session.fromFile(path: sessionPath).cctopSessionId, migratedSessionIDs.first)

        manager.loadSessions()

        XCTAssertNil(defaults.object(forKey: ManualSessionVisibilityStore.legacyDefaultsKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertEqual(visibility.hiddenSessionIDs, migratedSessionIDs)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(manager.cleanupSources.filter { $0.sessionId == threadID }.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir), ["history.json"])

        defaults.removeObject(forKey: ManualSessionVisibilityStore.defaultsKey)
        defaults.set(["codex:\(threadID)"], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        try FileManager.default.removeItem(atPath: sessionPath)
        try fastPeer.writeToFile(path: fastPeerPath)
        try desktopPeer.writeToFile(path: desktopPeerPath)
        try legacyPeer.writeToFile(path: legacyPeerPath)

        manager.loadSessions()

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertTrue(visibility.hiddenSessionIDs.isEmpty)
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )
        XCTAssertTrue(finishedPeerPaths.allSatisfy(FileManager.default.fileExists(atPath:)))
        XCTAssertEqual(
            manager.cleanupSources.filter { $0.sessionId == desktopPeerID }.map(\.projectPath),
            [desktopPeerProjectPath]
        )
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir), ["history.json"])

        try FileManager.default.removeItem(atPath: desktopPeerPath)
        try FileManager.default.removeItem(atPath: legacyPeerPath)
        manager.loadSessions()

        XCTAssertEqual(visibility.hiddenSessionIDs, [try XCTUnwrap(fastPeer.cctopSessionId)])
        XCTAssertNil(defaults.object(forKey: ManualSessionVisibilityStore.legacyDefaultsKey))
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fastPeerPath))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: historyDir), ["history.json"])
    }

    @MainActor
    func testUnresolvedLegacyHideKeepsNewlyArchivedCleanupSourceWhileRecentIsFrozen() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-unresolved-legacy-new-archive-\(UUID().uuidString)", isDirectory: true)
        let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = root.appendingPathComponent("history", isDirectory: true)
        let finishedProjectURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let identityBlockerURL = root.appendingPathComponent("session-identities")
        try Data("not a directory".utf8).write(to: identityBlockerURL)
        let hiddenThreadID = "11111111-2222-4333-8444-555555555555"
        var hidden = codexTerminalSession(sessionId: hiddenThreadID, projectPath: root.path)
        hidden.cctopSessionId = nil
        hidden.harnessSessionId = hiddenThreadID
        let hiddenURL = sessionsURL.appendingPathComponent("codex-\(hiddenThreadID).json")
        try hidden.writeToFile(path: hiddenURL.path)

        var finished = Session(
            sessionId: "unrelated-finished",
            projectPath: finishedProjectURL.path,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        finished.cctopSessionId = "22222222-2222-4222-8222-222222222222"
        finished.source = Session.opencodeSource
        finished.pid = 4_208
        finished.status = .working
        let finishedURL = sessionsURL.appendingPathComponent("unrelated-finished.json")
        try finished.writeToFile(path: finishedURL.path)

        let suiteName = "cctop-unresolved-legacy-new-archive-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["codex:\(hiddenThreadID)"], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)

        var sources = isolatedSessionDataSources(
            sessionsDir: sessionsURL,
            manualSessionVisibility: ManualSessionVisibilityStore(defaults: defaults)
        )
        sources.codexThreads = StubCodexThreadState(existing: [hiddenThreadID], archived: [])
        sources.processAlive = { $0.sessionId == hiddenThreadID }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: historyURL),
            dataSources: sources,
            startMonitoring: false
        )

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedURL.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(at: historyURL, includingPropertiesForKeys: nil).count, 1)
        XCTAssertEqual(
            manager.cleanupSources.filter { $0.sessionId == finished.sessionId }.map(\.projectPath),
            [finishedProjectURL.path]
        )
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(hiddenThreadID)"]
        )
    }

    @MainActor
    func testManualHideImmediatelyRemovesEveryProjectionSharingPermanentIdentity() throws {
        let root = NSTemporaryDirectory() + "cctop-manual-hide-shared-id-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let suiteName = "cctop-manual-hide-shared-id-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        let sharedID = "22222222-2222-4222-8222-222222222222"
        let durableConversationID = "39253133-4a65-48fb-af2b-844463d3b5bb"
        var live = Session(
            sessionId: "live-terminal",
            projectPath: "/tmp/live-terminal",
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        live.cctopSessionId = sharedID
        live.harnessSessionId = durableConversationID
        live.source = Session.ccSource
        live.pid = 4_204
        live.status = .working
        try live.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("live-terminal.json"))

        var archived = claudeDesktopSession(
            sessionId: durableConversationID,
            projectPath: "/tmp/archived-desktop"
        )
        archived.cctopSessionId = nil
        archived.harnessSessionId = durableConversationID
        archived.sessionName = "Archived desktop observation"
        archived.lastActivity = Date(timeIntervalSince1970: 2_000)
        try archived.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("archived-desktop.json"))
        try Data("not valid session json".utf8).write(
            to: URL(fileURLWithPath: (sessionsDir as NSString).appendingPathComponent("unrelated-broken.json"))
        )

        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), manualSessionVisibility: visibility)
        sources.claudeDesktopSessions = StubClaudeDesktopState(snapshot: ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: [durableConversationID],
            archivedSessionIDs: [durableConversationID],
            isAuthoritative: true
        ))
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in true }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )
        let hidden = try XCTUnwrap(manager.sessions.first { $0.sessionId == live.sessionId })
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)

        manager.hideSession(hidden)

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [sharedID])

        try FileManager.default.removeItem(
            atPath: (sessionsDir as NSString).appendingPathComponent("unrelated-broken.json")
        )
        manager.loadSessions()

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [sharedID])
    }

    @MainActor
    func testPublishedSessionSuppressesArchivedRecentTargetUntilObservationEnds() throws {
        let root = NSTemporaryDirectory() + "cctop-recent-live-suppression-\(UUID().uuidString)"
        let sessionsURL = URL(fileURLWithPath: root).appendingPathComponent("sessions", isDirectory: true)
        let historyURL = URL(fileURLWithPath: root).appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let sharedID = "33333333-3333-4333-8333-333333333333"
        let durableConversationID = "59253133-4a65-48fb-af2b-844463d3b5bb"
        var live = Session(
            sessionId: "live-terminal-observation",
            projectPath: "/tmp/live-terminal",
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        live.cctopSessionId = sharedID
        live.harnessSessionId = durableConversationID
        live.source = Session.ccSource
        live.pid = 4_205
        live.status = .working
        let liveURL = sessionsURL.appendingPathComponent("live-terminal.json")
        try live.writeToFile(path: liveURL.path)

        var archived = claudeDesktopSession(
            sessionId: durableConversationID,
            projectPath: "/tmp/archived-desktop"
        )
        archived.cctopSessionId = sharedID
        archived.harnessSessionId = durableConversationID
        archived.sessionName = "Archived desktop observation"
        archived.lastActivity = Date(timeIntervalSince1970: 2_000)
        try archived.writeToFile(path: sessionsURL.appendingPathComponent("archived-desktop.json").path)

        var sources = isolatedSessionDataSources(sessionsDir: sessionsURL, visibilityPrefix: "cctop-recent-live-suppression")
        sources.claudeDesktopSessions = StubClaudeDesktopState(snapshot: ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: [durableConversationID],
            archivedSessionIDs: [durableConversationID],
            isAuthoritative: true
        ))
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { $0.sessionId == live.sessionId }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: historyURL),
            dataSources: sources,
            startMonitoring: false
        )

        XCTAssertEqual(manager.sessions.map(\.cctopSessionId), [sharedID])
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)

        try FileManager.default.removeItem(at: liveURL)
        manager.loadSessions()

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(manager.recentResumeTargets.map(\.id), ["desktop:\(sharedID)"])
        XCTAssertEqual(manager.recentResumeTargets.map(\.title), ["Archived desktop observation"])
    }

    @MainActor
    func testManualHideKeySurvivesArchivedOnlyIdentityResolution() throws {
        let root = NSTemporaryDirectory() + "cctop-manual-hide-archived-only-\(UUID().uuidString)"
        let sessionsURL = URL(fileURLWithPath: root).appendingPathComponent("sessions", isDirectory: true)
        let historyURL = URL(fileURLWithPath: root).appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let suiteName = "cctop-manual-hide-archived-only-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        let sharedID = "33333333-3333-4333-8333-333333333333"
        let durableConversationID = "49253133-4a65-48fb-af2b-844463d3b5bb"
        _ = try CctopSessionIdentityStore(sessionsDir: sessionsURL).resolve(
            source: Session.ccSource,
            harnessSessionId: durableConversationID,
            legacySessionId: durableConversationID,
            knownExistingIDs: [sharedID]
        )

        var hidden = claudeDesktopSession(sessionId: durableConversationID, projectPath: "/tmp/archived-only")
        hidden.cctopSessionId = sharedID
        visibility.hide(hidden)
        hidden.cctopSessionId = nil
        hidden.harnessSessionId = durableConversationID
        hidden.sessionName = "Archived-only observation"
        try hidden.writeToFile(path: sessionsURL.appendingPathComponent("archived-only.json").path)

        var sources = isolatedSessionDataSources(sessionsDir: sessionsURL, manualSessionVisibility: visibility)
        sources.claudeDesktopSessions = StubClaudeDesktopState(snapshot: ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: [durableConversationID],
            archivedSessionIDs: [durableConversationID],
            isAuthoritative: true
        ))
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: historyURL),
            dataSources: sources,
            startMonitoring: false
        )

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [sharedID])

        manager.sessionFileCache.removeAll()
        manager.loadSessions()

        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [sharedID])
    }

    @MainActor
    func testManualHideRetainsFinishedMappedRecordsUntilBusyIdentityStampsRetry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-manual-hide-busy-stamp-\(UUID().uuidString)", isDirectory: true)
        let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "cctop-manual-hide-busy-stamp-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        let durableSessionID = "59253133-4a65-48fb-af2b-844463d3b5bb"
        let terminalObservationID = "busy-terminal-observation"
        let desktopObservationID = "busy-desktop-observation"
        let projectPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let initialNow = Date(timeIntervalSince1970: 2_000_000_000)

        var terminal = Session(
            sessionId: terminalObservationID,
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        terminal.cctopSessionId = nil
        terminal.harnessSessionId = durableSessionID
        terminal.source = Session.codexSource
        terminal.pid = 4_207
        terminal.status = .waitingInput
        terminal.lastActivity = initialNow
        let terminalURL = sessionsURL.appendingPathComponent("codex-\(terminalObservationID).json")
        try terminal.writeToFile(path: terminalURL.path)

        var desktop = codexDesktopSession(sessionId: desktopObservationID, projectPath: projectPath)
        desktop.cctopSessionId = nil
        desktop.harnessSessionId = durableSessionID
        desktop.lastActivity = initialNow
        let desktopURL = sessionsURL.appendingPathComponent("\(durableSessionID).json")
        try desktop.writeToFile(path: desktopURL.path)

        let terminalLock = try startSessionLockHolder(
            lockPath: terminalURL.path + ".lock",
            readyPath: root.appendingPathComponent("terminal-lock-ready").path,
            holdSeconds: 20
        )
        defer { terminateProcess(terminalLock) }
        let desktopLock = try startSessionLockHolder(
            lockPath: desktopURL.path + ".lock",
            readyPath: root.appendingPathComponent("desktop-lock-ready").path,
            holdSeconds: 20
        )
        defer { terminateProcess(desktopLock) }

        var processAlive = true
        var now = initialNow
        var postedNotificationIDs: [String] = []
        var sources = isolatedSessionDataSources(sessionsDir: sessionsURL, manualSessionVisibility: visibility)
        sources.codexThreads = StubCodexThreadState(
            existing: [terminalObservationID, desktopObservationID],
            archived: []
        )
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in processAlive }
        sources.notificationsEnabled = { true }
        sources.notificationClient = SessionNotificationClient(
            add: { request, completion in
                postedNotificationIDs.append(request.identifier)
                completion(nil)
            },
            removePending: { _ in },
            removeDelivered: { _ in }
        )
        sources.now = { now }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: historyURL),
            dataSources: sources,
            startMonitoring: false
        )
        waitForIdentityMigrationQueue(manager)

        let hidden = try XCTUnwrap(manager.sessions.first)
        let hiddenID = try XCTUnwrap(hidden.cctopSessionId)
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertNil(try Session.fromFile(path: terminalURL.path).cctopSessionId)
        XCTAssertNil(try Session.fromFile(path: desktopURL.path).cctopSessionId)

        manager.hideSession(hidden)
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [hiddenID])

        processAlive = false
        now = initialNow.addingTimeInterval(SessionManager.lifecycleWindows.retention + 1)
        manager.loadSessions()
        waitForIdentityMigrationQueue(manager)

        XCTAssertTrue(FileManager.default.fileExists(atPath: terminalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktopURL.path))
        XCTAssertEqual(visibility.hiddenSessionIDs, [hiddenID])
        XCTAssertEqual(
            Set(manager.cleanupSources.map(\.sessionId)),
            [terminalObservationID, desktopObservationID]
        )
        XCTAssertTrue(manager.historyManager.recentProjects.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(at: historyURL, includingPropertiesForKeys: nil)).isEmpty)
        XCTAssertTrue(postedNotificationIDs.isEmpty)

        terminateProcess(terminalLock)
        terminateProcess(desktopLock)
        manager.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: terminalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktopURL.path))

        manager.loadSessions()
        waitForIdentityMigrationQueue(manager)
        XCTAssertEqual(try Session.fromFile(path: terminalURL.path).cctopSessionId, hiddenID)
        XCTAssertEqual(try Session.fromFile(path: desktopURL.path).cctopSessionId, hiddenID)

        processAlive = true
        now = initialNow
        manager.loadSessions()
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [hiddenID])
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertTrue(postedNotificationIDs.isEmpty)
    }

    @MainActor
    func testMappedManualHideSurvivesMissingCodexDesktopMetadataBeforeIdentityStamp() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-mapped-hide-missing-codex-metadata-\(UUID().uuidString)", isDirectory: true)
        let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = root.appendingPathComponent("history", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let durableSessionID = "69253133-4a65-48fb-af2b-844463d3b5bb"
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var session = codexDesktopSession(sessionId: durableSessionID, projectPath: root.path)
        session.cctopSessionId = nil
        session.harnessSessionId = durableSessionID
        session.lastActivity = now.addingTimeInterval(-60)
        let sessionURL = sessionsURL.appendingPathComponent("codex-\(durableSessionID).json")
        try session.writeToFile(path: sessionURL.path)

        let mappedID = try CctopSessionIdentityStore(sessionsDir: sessionsURL).resolve(
            source: session.source,
            harnessSessionId: session.harnessSessionId,
            legacySessionId: session.sessionId,
            knownExistingIDs: []
        )
        let suiteName = "cctop-mapped-hide-missing-codex-metadata-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        var hiddenSnapshot = session
        hiddenSnapshot.cctopSessionId = mappedID
        visibility.hide(hiddenSnapshot)

        var missingSources = isolatedSessionDataSources(sessionsDir: sessionsURL, manualSessionVisibility: visibility)
        missingSources.codexThreads = StubCodexThreadState(existing: [], archived: [])
        missingSources.desktopAppConnection = DesktopAppConnectionLookup { _ in true }
        missingSources.processAlive = { _ in true }
        missingSources.now = { now }
        let missingManager = SessionManager(
            historyManager: HistoryManager(historyDir: historyURL),
            dataSources: missingSources,
            startMonitoring: false
        )
        waitForIdentityMigrationQueue(missingManager)

        XCTAssertTrue(missingManager.sessions.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [mappedID])
        XCTAssertEqual(try Session.fromFile(path: sessionURL.path).cctopSessionId, mappedID)

        var restoredSources = missingSources
        restoredSources.codexThreads = StubCodexThreadState(existing: [durableSessionID], archived: [])
        let restoredManager = SessionManager(
            historyManager: HistoryManager(historyDir: historyURL),
            dataSources: restoredSources,
            startMonitoring: false
        )

        XCTAssertTrue(restoredManager.sessions.isEmpty)
        XCTAssertEqual(visibility.hiddenSessionIDs, [mappedID])
    }

    @MainActor
    func testManualHideKeepsFinishedProjectOutOfRecentWhenArchiveFails() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-manual-hide-archive-failure-\(UUID().uuidString)", isDirectory: true)
        let sessionsURL = root.appendingPathComponent("sessions", isDirectory: true)
        let historyURL = root.appendingPathComponent("history", isDirectory: true)
        let projectPath = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
        try FileManager.default.createDirectory(at: sessionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: historyURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: historyURL.path)
            try? FileManager.default.removeItem(at: root)
        }

        let suiteName = "cctop-manual-hide-archive-failure-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        let hiddenID = "44444444-4444-4444-8444-444444444444"

        var previous = Session(
            sessionId: "previous",
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        previous.endedAt = Date().addingTimeInterval(-3_600)
        try previous.writeToFile(path: historyURL.appendingPathComponent("previous.json").path)
        let historyManager = HistoryManager(historyDir: historyURL)
        XCTAssertEqual(historyManager.recentProjects.map(\.projectPath), [projectPath])

        var finished = Session(
            sessionId: "hidden-finished",
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        finished.cctopSessionId = hiddenID
        finished.pid = 44_444
        finished.status = .working
        let finishedURL = sessionsURL.appendingPathComponent("hidden-finished.json")
        try finished.writeToFile(path: finishedURL.path)
        visibility.hide(finished)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: historyURL.path)

        var sources = isolatedSessionDataSources(sessionsDir: sessionsURL, manualSessionVisibility: visibility)
        sources.processAlive = { _ in false }
        let manager = SessionManager(historyManager: historyManager, dataSources: sources, startMonitoring: false)

        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finishedURL.path))
        XCTAssertEqual(visibility.hiddenSessionIDs, [hiddenID])
        XCTAssertFalse(manager.cleanupActiveProjectPaths.contains(projectPath))
        XCTAssertTrue(manager.cleanupSources.contains { $0.projectPath == projectPath })
    }

    @MainActor
    func testManualHideKeySurvivesIncompleteSessionInventory() throws {
        let root = NSTemporaryDirectory() + "cctop-manual-hide-partial-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let suiteName = "cctop-manual-hide-partial-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        let hidden = Session.mock(id: "hidden-thread", source: Session.codexSource)
        visibility.hide(hidden)
        try Data("not valid session json".utf8).write(
            to: URL(fileURLWithPath: (sessionsDir as NSString).appendingPathComponent("broken.json"))
        )

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            manualSessionVisibility: visibility
        )

        XCTAssertTrue(visibility.isHidden(hidden))
        try FileManager.default.removeItem(atPath: (sessionsDir as NSString).appendingPathComponent("broken.json"))
        manager.loadSessions()
        XCTAssertFalse(visibility.isHidden(hidden))
    }

    @MainActor
    func testManualHidePreservesRecentAndMergesCleanupProtectionWhenInventoryBecomesIncomplete() throws {
        let root = NSTemporaryDirectory() + "cctop-manual-hide-recent-partial-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let projectPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        var hidden = Session(
            sessionId: "hidden-live-project",
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.source = Session.codexSource
        hidden.pid = 4_204
        hidden.status = .working
        let hiddenURL = URL(fileURLWithPath: sessionsDir).appendingPathComponent("codex-hidden-live-project.json")
        try hidden.writeToFile(path: hiddenURL.path)

        var history = hidden
        history.sessionId = "ended-hidden-project"
        history.pid = 4_205
        history.endedAt = Date(timeIntervalSince1970: 2_000)
        try history.writeToFile(path: (historyDir as NSString).appendingPathComponent("history.json"))

        let suiteName = "cctop-manual-hide-recent-partial-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        visibility.hide(hidden)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { _ in true },
            manualSessionVisibility: visibility
        )
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertTrue(manager.cleanupActiveProjectPaths.contains(projectPath))
        let cleanupSourceIDs = manager.cleanupSources.map(\.sessionId)
        var refreshedActivePaths: Set<String>?
        manager.cleanupRefreshHandler = { _, activePaths in
            refreshedActivePaths = activePaths
        }

        try Data("not valid session json".utf8).write(to: hiddenURL)
        let newActivePath = (root as NSString).appendingPathComponent("worktrees/new-active")
        var newActive = Session(
            sessionId: "new-active-during-partial-read",
            projectPath: newActivePath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        newActive.pid = 4_206
        newActive.status = .working
        try newActive.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("4206.json"))
        manager.loadSessions()

        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [projectPath, newActivePath])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), cleanupSourceIDs)
        XCTAssertEqual(refreshedActivePaths, [projectPath, newActivePath])
        XCTAssertTrue(visibility.isHidden(hidden))

        let snapshot = manager.cleanupSnapshotForRemoval()
        XCTAssertEqual(snapshot.activeProjectPaths, [projectPath, newActivePath])

        try FileManager.default.removeItem(at: hiddenURL)
        manager.loadSessions()
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [newActivePath])
    }

    @MainActor
    func testManualHideRemovesFrozenRecentProjectDuringIncompleteInventory() throws {
        let root = NSTemporaryDirectory() + "cctop-manual-hide-frozen-recent-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let hiddenProjectPath = (root as NSString).appendingPathComponent("worktrees/hidden")
        let repositoryRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        let targetProjectPath = (repositoryRoot as NSString).appendingPathComponent("menubar")
        let targetProjectAlias = (repositoryRoot as NSString).appendingPathComponent("menubar/../menubar")
        let unrelatedProjectPath = (repositoryRoot as NSString).appendingPathComponent("plugins")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        var hidden = Session(
            sessionId: "already-hidden",
            projectPath: hiddenProjectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.cctopSessionId = "11111111-1111-4111-8111-111111111111"
        hidden.pid = 4_201
        hidden.status = .working
        let hiddenURL = URL(fileURLWithPath: sessionsDir).appendingPathComponent("4201.json")
        try hidden.writeToFile(path: hiddenURL.path)

        for (sessionID, projectPath) in [
            ("target-history", targetProjectPath),
            ("unrelated-history", unrelatedProjectPath),
        ] {
            var history = Session(
                sessionId: sessionID,
                projectPath: projectPath,
                branch: "main",
                terminal: TerminalInfo(program: "zsh")
            )
            history.endedAt = Date().addingTimeInterval(sessionID == "target-history" ? -3_600 : -7_200)
            try history.writeToFile(path: (historyDir as NSString).appendingPathComponent("\(sessionID).json"))
        }

        let suiteName = "cctop-manual-hide-frozen-recent-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        visibility.hide(hidden)
        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { _ in true },
            manualSessionVisibility: visibility
        )
        XCTAssertEqual(Set(manager.recentResumeTargets.map(\.projectPath)), [targetProjectPath, unrelatedProjectPath])

        try Data("not valid session json".utf8).write(to: hiddenURL)
        var live = Session(
            sessionId: "live-target",
            projectPath: targetProjectAlias,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        live.cctopSessionId = "22222222-2222-4222-8222-222222222222"
        live.pid = 4_202
        live.status = .working
        try live.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("4202.json"))
        manager.loadSessions()

        let visible = try XCTUnwrap(manager.sessions.first { $0.cctopSessionId == live.cctopSessionId })
        XCTAssertEqual(Set(manager.recentResumeTargets.map(\.projectPath)), [targetProjectPath, unrelatedProjectPath])

        manager.hideSession(visible)

        XCTAssertEqual(manager.recentResumeTargets.map(\.projectPath), [unrelatedProjectPath])
    }

    @MainActor
    func testManualHideKeepsRecentEmptyWhenSessionDirectoryReadFails() throws {
        let root = NSTemporaryDirectory() + "cctop-manual-hide-recent-directory-\(UUID().uuidString)"
        let sessionsPath = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let projectPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .path
        var hidden = Session(
            sessionId: "hidden-directory-session",
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.source = Session.codexSource

        var history = hidden
        history.sessionId = "ended-hidden-directory-project"
        history.endedAt = Date(timeIntervalSince1970: 2_000)
        try history.writeToFile(path: (historyDir as NSString).appendingPathComponent("history.json"))
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: sessionsPath))

        let suiteName = "cctop-manual-hide-recent-directory-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        visibility.hide(hidden)

        let manager = makeManager(
            sessionsDir: sessionsPath,
            historyDir: historyDir,
            manualSessionVisibility: visibility
        )

        XCTAssertEqual(manager.historyManager.recentProjects.map(\.projectPath), [projectPath])
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)
        XCTAssertTrue(visibility.isHidden(hidden))

        let threadID = "legacy-hidden-directory-session"
        let legacySuiteName = "cctop-legacy-hide-recent-directory-\(UUID().uuidString)"
        let legacyDefaults = try XCTUnwrap(UserDefaults(suiteName: legacySuiteName))
        defer { legacyDefaults.removePersistentDomain(forName: legacySuiteName) }
        legacyDefaults.set(["codex:\(threadID)"], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        let legacyVisibility = ManualSessionVisibilityStore(defaults: legacyDefaults)

        let legacyManager = makeManager(
            sessionsDir: sessionsPath,
            historyDir: historyDir,
            manualSessionVisibility: legacyVisibility
        )

        XCTAssertEqual(legacyManager.historyManager.recentProjects.map(\.projectPath), [projectPath])
        XCTAssertTrue(legacyManager.recentResumeTargets.isEmpty)
        XCTAssertEqual(
            legacyDefaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )
        XCTAssertTrue(legacyVisibility.hiddenSessionIDs.isEmpty)
    }

    @MainActor
    func testManualHideIgnoresSessionThatIsNoLongerVisible() throws {
        let root = NSTemporaryDirectory() + "cctop-manual-hide-vanished-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let suiteName = "cctop-manual-hide-vanished-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        let vanished = Session.mock(id: "vanished", source: Session.codexSource)
        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            manualSessionVisibility: visibility
        )

        manager.hideSession(vanished)

        XCTAssertFalse(visibility.isHidden(vanished))
        XCTAssertNil(defaults.object(forKey: ManualSessionVisibilityStore.defaultsKey))
    }

    // MARK: - Codex memory maintenance sessions

    func testCodexMemoryMaintenanceSessionUsesConfiguredDirectory() {
        let root = NSTemporaryDirectory() + "cctop-memory-\(UUID().uuidString)"
        let memoriesDir = (root as NSString).appendingPathComponent("alice/.codex/memories")
        setenv("CCTOP_CODEX_MEMORIES_DIR", memoriesDir + "/", 1)
        defer {
            unsetenv("CCTOP_CODEX_MEMORIES_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let normalizedEquivalent = (root as NSString)
            .appendingPathComponent("alice/.codex/../.codex/memories")
        let session = codexDesktopSession(sessionId: "codex-memory", projectPath: normalizedEquivalent)

        XCTAssertEqual(Config.codexMemoriesDir(), memoriesDir + "/")
        XCTAssertTrue(session.isCodexMemoryMaintenanceSession)
    }

    func testCodexReservedMemoryDirectoryClassificationIsNarrow() {
        let root = NSTemporaryDirectory() + "cctop-memory-\(UUID().uuidString)"
        let memoriesDir = (root as NSString).appendingPathComponent("bob/.codex/memories")
        setenv("CCTOP_CODEX_MEMORIES_DIR", memoriesDir, 1)
        defer {
            unsetenv("CCTOP_CODEX_MEMORIES_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let normalProject = codexDesktopSession(
            sessionId: "normal-codex",
            projectPath: (root as NSString).appendingPathComponent("bob/projects/cctop")
        )
        XCTAssertFalse(normalProject.isCodexMemoryMaintenanceSession)

        var userLaunchedMemoryTask = Session(
            sessionId: "user-launched-memory-task",
            projectPath: memoriesDir,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        userLaunchedMemoryTask.source = Session.codexSource
        XCTAssertTrue(userLaunchedMemoryTask.isCodexMemoryMaintenanceSession)

        var nonCodexMemory = codexDesktopSession(sessionId: "other-memory", projectPath: memoriesDir)
        nonCodexMemory.source = "cc"
        XCTAssertFalse(nonCodexMemory.isCodexMemoryMaintenanceSession)

        let neighboringMemoriesProject = codexDesktopSession(
            sessionId: "neighboring-memories",
            projectPath: (root as NSString).appendingPathComponent("bob/projects/memories")
        )
        XCTAssertFalse(neighboringMemoriesProject.isCodexMemoryMaintenanceSession)

        XCTAssertEqual(normalProject.projectName, "cctop")
    }

    func testCodexDesktopTitleGenerationClassificationIsNarrow() {
        let projectPath = "/Users/alice/projects/cctop"

        var titleGeneration = codexDesktopSession(sessionId: "title-helper", projectPath: projectPath)
        titleGeneration.lastPrompt = codexTitleGenerationPrompt()
        XCTAssertTrue(titleGeneration.isCodexDesktopTitleGenerationSession)

        var normalCodexDesktop = codexDesktopSession(sessionId: "normal-codex", projectPath: projectPath)
        normalCodexDesktop.sessionName = "Explain Codex memory sessions"
        normalCodexDesktop.lastPrompt = "They disappeared indeed. commit."
        XCTAssertFalse(normalCodexDesktop.isCodexDesktopTitleGenerationSession)

        var namedTitleGeneration = titleGeneration
        namedTitleGeneration.sessionName = "Generated title"
        XCTAssertFalse(namedTitleGeneration.isCodexDesktopTitleGenerationSession)

        var nonDesktopTitleGeneration = Session(
            sessionId: "terminal-title-helper",
            projectPath: projectPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        nonDesktopTitleGeneration.source = Session.codexSource
        nonDesktopTitleGeneration.lastPrompt = codexTitleGenerationPrompt()
        XCTAssertFalse(nonDesktopTitleGeneration.isCodexDesktopTitleGenerationSession)

        var nonCodexTitleGeneration = titleGeneration
        nonCodexTitleGeneration.source = "cc"
        XCTAssertFalse(nonCodexTitleGeneration.isCodexDesktopTitleGenerationSession)
    }

    @MainActor
    func testSessionManagerHidesCodexMemoryMaintenanceSessionsWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-memory-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let memoriesDir = (root as NSString).appendingPathComponent("carol/.codex/memories")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_CODEX_MEMORIES_DIR", memoriesDir, 1)
        defer {
            unsetenv("CCTOP_CODEX_MEMORIES_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let memorySession = codexDesktopSession(sessionId: "memory-session", projectPath: memoriesDir)
        let memoryPath = (sessionsDir as NSString).appendingPathComponent("codex-memory-session.json")
        try memorySession.writeToFile(path: memoryPath)
        FileManager.default.createFile(atPath: memoryPath + ".lock", contents: nil)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: memoryPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: memoryPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerHidesCodexDesktopTitleGenerationSessionsWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-title-helper-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        var titleGeneration = codexDesktopSession(
            sessionId: "title-helper",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        titleGeneration.lastPrompt = codexTitleGenerationPrompt(for: "Why do I have several memories sessions?")
        let titleHelperPath = (sessionsDir as NSString).appendingPathComponent("codex-title-helper.json")
        try titleGeneration.writeToFile(path: titleHelperPath)
        FileManager.default.createFile(atPath: titleHelperPath + ".lock", contents: nil)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: titleHelperPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: titleHelperPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: titleHelperPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    func testAutoHiddenSessionSnapshotPreservesLatestFileFields() throws {
        let root = NSTemporaryDirectory() + "cctop-auto-hide-merge-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let memoriesDir = (root as NSString).appendingPathComponent("carol/.codex/memories")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)

        setenv("CCTOP_CODEX_MEMORIES_DIR", memoriesDir, 1)
        defer {
            unsetenv("CCTOP_CODEX_MEMORIES_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        var latest = codexDesktopSession(sessionId: "memory-session", projectPath: memoriesDir)
        latest.status = .working
        latest.lastTool = "Read"
        latest.lastToolDetail = "Sources.swift"
        latest.lastPrompt = "Summarize project state"
        latest.activeSubagents = [
            SubagentInfo(agentId: "agent-1", agentType: "reviewer", startedAt: Date(timeIntervalSince1970: 100))
        ]

        let memoryPath = (sessionsDir as NSString).appendingPathComponent("codex-memory-session.json")
        try latest.writeToFile(path: memoryPath)

        let hidden = try XCTUnwrap(SessionManager.autoHiddenSessionSnapshot(path: memoryPath))

        XCTAssertTrue(hidden.hidden)
        XCTAssertEqual(hidden.status, .working)
        XCTAssertEqual(hidden.lastTool, "Read")
        XCTAssertEqual(hidden.lastToolDetail, "Sources.swift")
        XCTAssertEqual(hidden.lastPrompt, "Summarize project state")
        XCTAssertEqual(hidden.activeSubagents, latest.activeSubagents)
    }

    func testAutoHiddenSessionSnapshotSkipsFilesThatNoLongerNeedHiding() throws {
        let root = NSTemporaryDirectory() + "cctop-auto-hide-skip-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let normalSession = codexDesktopSession(
            sessionId: "normal-codex",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        let path = (sessionsDir as NSString).appendingPathComponent("codex-normal.json")
        try normalSession.writeToFile(path: path)

        XCTAssertNil(try SessionManager.autoHiddenSessionSnapshot(path: path))
    }

    @MainActor
    func testSessionManagerSkipsAlreadyHiddenSessionsWithoutArchivingOrRemovingThem() throws {
        let root = NSTemporaryDirectory() + "cctop-hidden-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        var hidden = Session(
            sessionId: "hidden-review",
            projectPath: (root as NSString).appendingPathComponent("reviews/cctop"),
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.hidden = true
        hidden.pid = 999_999
        let hiddenPath = (sessionsDir as NSString).appendingPathComponent("999999.json")
        try hidden.writeToFile(path: hiddenPath)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: hiddenPath))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testCleanupActivePathsIncludeHiddenLiveSessions() throws {
        let root = NSTemporaryDirectory() + "cctop-hidden-active-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let worktreePath = (root as NSString).appendingPathComponent(".codex/worktrees/hidden-live")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        var hidden = Session(
            sessionId: "hidden-live",
            projectPath: worktreePath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.hidden = true
        hidden.pid = 999_998
        let hiddenPath = (sessionsDir as NSString).appendingPathComponent("999998.json")
        try hidden.writeToFile(path: hiddenPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { $0.sessionId == "hidden-live" }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [worktreePath])
    }

    @MainActor
    func testCleanupActivePathsIncludeAutoHiddenLiveSessions() throws {
        let root = NSTemporaryDirectory() + "cctop-auto-hidden-active-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let worktreePath = (root as NSString).appendingPathComponent(".codex/worktrees/title-helper")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        var titleGeneration = codexDesktopSession(sessionId: "title-helper-active", projectPath: worktreePath)
        titleGeneration.sessionName = nil
        titleGeneration.lastPrompt = codexTitleGenerationPrompt()
        titleGeneration.lastActivity = Date()
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-title-helper-active.json")
        try titleGeneration.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            desktopAppConnection: DesktopAppConnectionLookup { _ in true },
            processAlive: { $0.sessionId == "title-helper-active" }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [worktreePath])
        XCTAssertTrue(try Session.fromFile(path: sessionPath).hidden)
    }

    @MainActor
    func testCleanupSnapshotForRemovalRefreshesHiddenActiveProtection() throws {
        let root = NSTemporaryDirectory() + "cctop-hidden-active-refresh-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let worktreePath = (root as NSString).appendingPathComponent(".codex/worktrees/late-hidden")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { $0.sessionId == "late-hidden" }
        )
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])

        var hidden = Session(
            sessionId: "late-hidden",
            projectPath: worktreePath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.hidden = true
        hidden.pid = 999_997
        try hidden.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("999997.json"))

        let snapshot = manager.cleanupSnapshotForRemoval()

        XCTAssertEqual(snapshot.activeProjectPaths, [worktreePath])
    }

    @MainActor
    func testGarbageCollectRefreshPreservesHiddenCleanupProtection() throws {
        let root = NSTemporaryDirectory() + "cctop-gc-hidden-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let protectedPath = (root as NSString).appendingPathComponent(".codex/worktrees/hidden-live")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        var hidden = Session(
            sessionId: "hidden-live",
            projectPath: protectedPath,
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        hidden.hidden = true
        hidden.pid = 999_996
        try hidden.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("999996.json"))

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let finishedDesktopPath = (sessionsDir as NSString).appendingPathComponent("codex-finished-desktop.json")
        var finishedDesktop = codexDesktopSession(sessionId: "finished-desktop", projectPath: "/tmp/finished-desktop")
        finishedDesktop.lastActivity = old
        finishedDesktop.disconnectedAt = old
        try finishedDesktop.writeToFile(path: finishedDesktopPath)

        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), visibilityPrefix: "cctop-gc-hidden-cleanup")
        sources.codexThreads = StubCodexThreadState(existing: ["finished-desktop"], archived: [])
        sources.claudeDesktopSessions = StubClaudeDesktopState(snapshot: ClaudeDesktopSessionMetadataSnapshot())
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { $0.sessionId == "hidden-live" }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [protectedPath])

        var history = Session(
            sessionId: "history",
            projectPath: "/tmp/history",
            branch: "main",
            terminal: TerminalInfo(program: "zsh")
        )
        history.endedAt = Date()
        try history.writeToFile(path: (historyDir as NSString).appendingPathComponent("history.json"))

        var refreshedActivePaths: Set<String>?
        manager.cleanupRefreshHandler = { _, activePaths in
            refreshedActivePaths = activePaths
        }

        manager.garbageCollectFinished()

        XCTAssertFalse(FileManager.default.fileExists(atPath: finishedDesktopPath))
        XCTAssertEqual(refreshedActivePaths, [protectedPath])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [protectedPath])
    }

    @MainActor
    func testGarbageCollectSkipsBusySessionLockWithoutBlockingMainActor() throws {
        let root = NSTemporaryDirectory() + "cctop-gc-busy-lock-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-busy-finished-thread.json")
        var session = codexDesktopSession(sessionId: "busy-finished-thread", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        let readyPath = (root as NSString).appendingPathComponent("lock-ready")
        let lockHolder = try startSessionLockHolder(lockPath: sessionPath + ".lock", readyPath: readyPath, holdSeconds: 1.5)
        defer { terminateProcess(lockHolder) }

        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), visibilityPrefix: "cctop-gc-busy-lock")
        sources.codexThreads = StubCodexThreadState(existing: ["busy-finished-thread"], archived: [])
        sources.claudeDesktopSessions = StubClaudeDesktopState(snapshot: ClaudeDesktopSessionMetadataSnapshot())
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        let start = Date()
        manager.garbageCollectFinished()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.75)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testSessionManagerHidesGenericSubagentSessionFilesWithoutArchivingOrRemovingThem() throws {
        let root = NSTemporaryDirectory() + "cctop-generic-subagent-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(atPath: root) }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("12345.json")
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
          "session_id": "delegated-review",
          "project_path": "\(root)/projects/cctop",
          "project_name": "cctop",
          "branch": "main",
          "status": "working",
          "last_activity": "\(now)",
          "started_at": "\(now)",
          "terminal": {"program": "zsh"},
          "pid": \(ProcessInfo.processInfo.processIdentifier),
          "source": "opencode",
          "is_subagent": true
        }
        """
        try json.write(toFile: sessionPath, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: sessionPath + ".lock", contents: nil)

        let manager = makeManager(sessionsDir: sessionsDir, historyDir: historyDir)
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerHidesCodexSubagentThreadsForAnyCodexHostWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-subagents-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            subagentThreads: ["codex-cli-subagent", "codex-desktop-subagent"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let cliPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-cli-subagent.json")
        let desktopPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-desktop-subagent.json")
        try codexTerminalSession(
            sessionId: "codex-cli-subagent",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: cliPath)
        try codexDesktopSession(
            sessionId: "codex-desktop-subagent",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: desktopPath)
        FileManager.default.createFile(atPath: cliPath + ".lock", contents: nil)
        FileManager.default.createFile(atPath: desktopPath + ".lock", contents: nil)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktopPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: cliPath + ".lock"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktopPath + ".lock"))
        XCTAssertTrue(try Session.fromFile(path: cliPath).hidden)
        XCTAssertTrue(try Session.fromFile(path: desktopPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerKeepsUserVisibleDelegatedCodexThreadVisible() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-delegated-visible-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            delegatedThreads: ["delegated-visible"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-delegated-visible.json")
        try codexDesktopSession(
            sessionId: "delegated-visible",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["delegated-visible"])
        let persisted = try Session.fromFile(path: sessionPath)
        XCTAssertFalse(persisted.hidden)
        XCTAssertFalse(persisted.isSubagentSession)
    }

    @MainActor
    func testSessionManagerRepairsStickyDelegatedCodexThreadClassification() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-delegated-repair-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            delegatedThreads: ["delegated-sticky", "memory-sticky"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-delegated-sticky.json")
        var session = codexDesktopSession(
            sessionId: "delegated-sticky",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        session.isSubagentSession = true
        session.hidden = true
        try session.writeToFile(path: sessionPath)

        let memoryPath = (sessionsDir as NSString).appendingPathComponent("codex-memory-sticky.json")
        var memorySession = codexDesktopSession(
            sessionId: "memory-sticky",
            projectPath: Config.codexMemoriesDir()
        )
        memorySession.isSubagentSession = true
        memorySession.hidden = true
        try memorySession.writeToFile(path: memoryPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["delegated-sticky"])
        let persisted = try Session.fromFile(path: sessionPath)
        XCTAssertFalse(persisted.hidden)
        XCTAssertFalse(persisted.isSubagentSession)
        let persistedMemory = try Session.fromFile(path: memoryPath)
        XCTAssertTrue(persistedMemory.hidden)
        XCTAssertTrue(persistedMemory.isSubagentSession)
    }

    @MainActor
    func testSessionManagerDoesNotRepairStickyDelegatedCodexThreadWithContradictorySpawnEdge() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-delegated-contradiction-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            delegatedThreads: ["delegated-with-edge"]
        )
        try executeSQLite(
            "INSERT INTO thread_spawn_edges VALUES ('parent', 'delegated-with-edge', 'open');",
            path: stateDB
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-delegated-with-edge.json")
        var session = codexDesktopSession(
            sessionId: "delegated-with-edge",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        session.isSubagentSession = true
        session.hidden = true
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        let persisted = try Session.fromFile(path: sessionPath)
        XCTAssertTrue(persisted.hidden)
        XCTAssertTrue(persisted.isSubagentSession)
    }

    @MainActor
    func testSessionManagerDoesNotRepairStickyDelegatedCodexThreadWithoutSpawnEdgeSchema() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-delegated-legacy-schema-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            delegatedThreads: ["delegated-legacy"]
        )
        try executeSQLite("DROP TABLE thread_spawn_edges;", path: stateDB)

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-delegated-legacy.json")
        var session = codexDesktopSession(
            sessionId: "delegated-legacy",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        session.isSubagentSession = true
        session.hidden = true
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        let persisted = try Session.fromFile(path: sessionPath)
        XCTAssertTrue(persisted.hidden)
        XCTAssertTrue(persisted.isSubagentSession)
    }

    @MainActor
    func testSessionManagerFiltersCodexExecHelperThreadsWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-exec-helper-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            execHelperThreads: ["codex-exec-helper"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-exec-helper.json")
        try codexDesktopSession(
            sessionId: "codex-exec-helper",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: sessionPath)
        FileManager.default.createFile(atPath: sessionPath + ".lock", contents: nil)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            desktopAppConnection: DesktopAppConnectionLookup { _ in true }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath + ".lock"))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerFiltersCodexDesktopSessionsMissingFromReadableStateWithoutRemovingFiles() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-missing-state-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["visible-thread"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let missingPath = (sessionsDir as NSString).appendingPathComponent("codex-missing-thread.json")
        let visiblePath = (sessionsDir as NSString).appendingPathComponent("codex-visible-thread.json")
        var missing = codexDesktopSession(
            sessionId: "missing-thread",
            projectPath: (root as NSString).appendingPathComponent("projects/probe")
        )
        missing.lastActivity = now.addingTimeInterval(-SessionManager.codexMissingThreadGraceSeconds - 1)
        try missing.writeToFile(path: missingPath)
        var visible = codexDesktopSession(
            sessionId: "visible-thread",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        visible.lastActivity = now
        try visible.writeToFile(path: visiblePath)
        FileManager.default.createFile(atPath: missingPath + ".lock", contents: nil)
        FileManager.default.createFile(atPath: visiblePath + ".lock", contents: nil)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            desktopAppConnection: DesktopAppConnectionLookup { _ in true },
            now: { now }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["visible-thread"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: missingPath + ".lock"))
        XCTAssertFalse(try Session.fromFile(path: missingPath).hidden)
        XCTAssertTrue(FileManager.default.fileExists(atPath: visiblePath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: visiblePath + ".lock"))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerKeepsFreshCodexDesktopSessionVisibleWhileThreadStateCatchesUp() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-fresh-missing-state-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["other-thread"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-fresh-thread.json")
        var session = codexDesktopSession(
            sessionId: "fresh-thread",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        session.lastActivity = now.addingTimeInterval(-SessionManager.codexMissingThreadGraceSeconds / 2)
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            desktopAppConnection: DesktopAppConnectionLookup { _ in true },
            now: { now }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["fresh-thread"])
        XCTAssertEqual(
            SessionDisplayPolicy.activeSessions(from: manager.sessions, now: now).map(\.sessionId),
            ["fresh-thread"]
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerPublishesOneGroupedActiveOrderThroughRealisticFileUpdates() throws {
        let root = NSTemporaryDirectory() + "cctop-stable-active-order-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let now = Date(timeIntervalSince1970: 1_900_000_000)
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let alphaPath = (sessionsDir as NSString).appendingPathComponent("101.json")
        let betaPath = (sessionsDir as NSString).appendingPathComponent("202.json")
        let gammaPath = (sessionsDir as NSString).appendingPathComponent("303.json")
        let deltaPath = (sessionsDir as NSString).appendingPathComponent("404.json")
        var alpha = Session.mock(id: "alpha", status: .working, pid: 101, source: Session.opencodeSource)
        alpha.lastActivity = now.addingTimeInterval(-60)
        var beta = Session.mock(id: "beta", status: .working, pid: 202, source: Session.opencodeSource)
        beta.lastActivity = now.addingTimeInterval(-10)
        try alpha.writeToFile(path: alphaPath)
        try beta.writeToFile(path: betaPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { _ in true },
            now: { now }
        )
        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: manager.sessions, now: now).map(\.id), ["101", "202"])

        var gamma = Session.mock(id: "gamma", status: .waitingInput, pid: 303, source: Session.opencodeSource)
        gamma.lastActivity = now.addingTimeInterval(-30)
        var delta = Session.mock(id: "delta", status: .waitingInput, pid: 404, source: Session.opencodeSource)
        delta.lastActivity = now.addingTimeInterval(-20)
        try gamma.writeToFile(path: gammaPath)
        try delta.writeToFile(path: deltaPath)
        manager.loadSessions()
        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: manager.sessions, now: now).map(\.id), ["303", "404", "101", "202"])

        alpha.status = .waitingInput
        alpha.lastActivity = now
        alpha.notificationMessage = "Continue?"
        beta.status = .idle
        beta.lastActivity = now.addingTimeInterval(-300)
        beta.lastTool = "Bash"
        beta.lastToolDetail = "make test"
        try alpha.writeToFile(path: alphaPath)
        try beta.writeToFile(path: betaPath)
        manager.loadSessions()

        let activeAfterUpdates = SessionDisplayPolicy.activeSessions(from: manager.sessions, now: now)
        XCTAssertEqual(activeAfterUpdates.map(\.id), ["303", "404", "101", "202"])
        let snapshot = DisplayStateWriter.snapshot(
            sessions: manager.sessions,
            theme: .claude,
            appRunning: true,
            appIdentity: DisplayState.ProcessIdentity(pid: 999, startTime: 1_234),
            now: now
        )
        XCTAssertEqual(
            snapshot.sessions.map(\.cctopSessionId),
            activeAfterUpdates.map { $0.cctopSessionId ?? "" }
        )
        XCTAssertEqual(snapshot.sessions.count, activeAfterUpdates.count)
        XCTAssertTrue(activeAfterUpdates.allSatisfy { Session.isValidCctopSessionId($0.cctopSessionId) })

        alpha.hidden = true
        try alpha.writeToFile(path: alphaPath)
        manager.loadSessions()
        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: manager.sessions, now: now).map(\.id), ["303", "404", "202"])

        beta.endedAt = now
        try beta.writeToFile(path: betaPath)
        manager.loadSessions()
        XCTAssertEqual(SessionDisplayPolicy.activeSessions(from: manager.sessions, now: now).map(\.id), ["303", "404"])
    }

    @MainActor
    func testLegacyIdentityMigrationRetriesAfterBusySessionLock() throws {
        let root = NSTemporaryDirectory() + "cctop-identity-retry-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("4242.json")
        var legacy = Session.mock(id: "legacy", pid: 4242, source: Session.opencodeSource)
        legacy.cctopSessionId = nil
        try legacy.writeToFile(path: sessionPath)

        let readyPath = (root as NSString).appendingPathComponent("identity-lock-ready")
        let lockHolder = try startSessionLockHolder(
            lockPath: sessionPath + ".lock",
            readyPath: readyPath,
            holdSeconds: 10
        )
        defer { terminateProcess(lockHolder) }

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { _ in true }
        )
        XCTAssertNil(manager.sessions.first?.cctopSessionId)
        waitForIdentityMigrationQueue(manager)
        XCTAssertNil(try Session.fromFile(path: sessionPath).cctopSessionId)

        terminateProcess(lockHolder)
        let hookInput = try JSONDecoder().decode(HookInput.self, from: Data("""
        {"session_id":"legacy","cwd":"/tmp/project","hook_event_name":"PreToolUse","harness_name":"opencode"}
        """.utf8))
        let hookDeps = HookDependencies(
            sessionsDir: { sessionsDir },
            environment: { [:] },
            currentBranch: { _ in "main" },
            process: VisibilityHookProcessProber(),
            names: VisibilityHookNameResolver(),
            logger: HookLogger(logsDir: (root as NSString).appendingPathComponent("logs"))
        )
        try HookHandler.handleHook(hookName: "PreToolUse", input: hookInput, deps: hookDeps)
        let hookAssignedID = try XCTUnwrap(Session.fromFile(path: sessionPath).cctopSessionId)
        manager.loadSessions()
        waitForIdentityMigrationQueue(manager)

        XCTAssertEqual(try Session.fromFile(path: sessionPath).cctopSessionId, hookAssignedID)
        XCTAssertEqual(manager.sessions.first?.cctopSessionId, hookAssignedID)
    }

    @MainActor
    func testLegacyDurableDuplicatesMigrateToOneCctopSessionID() throws {
        let root = NSTemporaryDirectory() + "cctop-identity-duplicates-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let reference = "11111111-2222-4333-8444-555555555555"
        for pid: UInt32 in [4242, 5002] {
            var session = Session.mock(id: reference, pid: pid, source: Session.ccSource)
            session.cctopSessionId = nil
            session.harnessSessionId = reference
            try session.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("\(pid).json"))
        }

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { _ in true }
        )
        let publishedIDs = Set(manager.sessions.compactMap(\.cctopSessionId))
        XCTAssertEqual(manager.sessions.count, 1)
        XCTAssertEqual(publishedIDs.count, 1)
        XCTAssertTrue(publishedIDs.allSatisfy(Session.isValidCctopSessionId))

        waitForIdentityMigrationQueue(manager)
        let persistedIDs = try Set([4242, 5002].map { pid in
            try XCTUnwrap(Session.fromFile(path: (sessionsDir as NSString).appendingPathComponent("\(pid).json")).cctopSessionId)
        })
        XCTAssertEqual(persistedIDs, publishedIDs)
    }

    @MainActor
    func testConflictingDurableLegacyIdentitiesFailClosed() throws {
        let root = NSTemporaryDirectory() + "cctop-identity-conflict-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let reference = "11111111-2222-4333-8444-555555555555"
        let existingIDs = [
            "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        ]
        for (index, pid) in [4242, 5002, 6003].enumerated() {
            var session = Session.mock(id: reference, pid: UInt32(pid), source: Session.ccSource)
            session.cctopSessionId = index < existingIDs.count ? existingIDs[index] : nil
            session.harnessSessionId = reference
            try session.writeToFile(path: (sessionsDir as NSString).appendingPathComponent("\(pid).json"))
        }

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            processAlive: { _ in true }
        )

        XCTAssertNil(manager.sessions.first(where: { $0.pid == 6003 })?.cctopSessionId)
        XCTAssertNil(try Session.fromFile(
            path: (sessionsDir as NSString).appendingPathComponent("6003.json")
        ).cctopSessionId)
    }

    @MainActor
    func testSessionManagerKeepsUserVisibleCodexExecThreads() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-user-exec-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            userExecThreads: ["codex-user-exec"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-user-exec.json")
        try codexDesktopSession(
            sessionId: "codex-user-exec",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            desktopAppConnection: DesktopAppConnectionLookup { _ in true }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["codex-user-exec"])
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
    }

    @MainActor
    func testSessionManagerKeepsCodexExecThreadsWithFirstUserMessageVisible() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-exec-first-message-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            execThreadsWithFirstUserMessage: ["codex-exec-first-message": "Review this diff"]
        )

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-codex-exec-first-message.json")
        try codexDesktopSession(
            sessionId: "codex-exec-first-message",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        ).writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            desktopAppConnection: DesktopAppConnectionLookup { _ in true }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["codex-exec-first-message"])
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
    }

    @MainActor
    func testSessionManagerKeepsParentSessionWithActiveSubagentsVisible() throws {
        let root = NSTemporaryDirectory() + "cctop-parent-subagents-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["parent-thread"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-parent-thread.json")
        var session = codexDesktopSession(
            sessionId: "parent-thread",
            projectPath: (root as NSString).appendingPathComponent("projects/cctop")
        )
        session.activeSubagents = [
            SubagentInfo(agentId: "agent-1", agentType: "reviewer", startedAt: Date(timeIntervalSince1970: 100))
        ]
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            desktopAppConnection: DesktopAppConnectionLookup { _ in true }
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["parent-thread"])
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
    }

    @MainActor
    func testSessionManagerRemovesFinishedCodexDedupLoserWithoutArchiving() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-dedup-cleanup-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["conv-a"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        var oldPidKeyed = Session(
            sessionId: "conv-a", projectPath: "/tmp/p", branch: "main", terminal: TerminalInfo()
        )
        oldPidKeyed.source = Session.codexSource
        oldPidKeyed.pid = 999_999
        oldPidKeyed.endedAt = Date(timeIntervalSince1970: 100)
        let oldPath = (sessionsDir as NSString).appendingPathComponent("999999.json")
        try oldPidKeyed.writeToFile(path: oldPath)

        var desktopKeyed = Session(
            sessionId: "conv-a", projectPath: "/tmp/p", branch: "main",
            terminal: TerminalInfo(bundleId: HostAppBundleID.codexDesktop)
        )
        desktopKeyed.source = Session.codexSource
        desktopKeyed.lastActivity = Date()
        let desktopPath = (sessionsDir as NSString).appendingPathComponent("codex-conv-a.json")
        try desktopKeyed.writeToFile(path: desktopPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        )
        manager.loadSessions()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: desktopPath))
        XCTAssertEqual(manager.sessions.map(\.sessionId), ["conv-a"])
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerHidesArchivedCodexDesktopSessionButKeepsFileForUnarchive() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["archived-thread"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-archived-thread.json")
        var session = codexDesktopSession(sessionId: "archived-thread", projectPath: "/tmp/p")
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), ["archived-thread"])
        XCTAssertEqual(manager.cleanupSources.map(\.projectPath), ["/tmp/p"])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: ["archived-thread"])
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["archived-thread"])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, ["/tmp/p"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testSessionManagerTracksCodexArchiveTransitionsWithoutDesktopHostEvidence() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archive-across-hosts-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let threadID = "cross-host-archive"
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: [threadID])

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-\(threadID).json")
        var session = Session(
            sessionId: threadID,
            projectPath: "/tmp/p",
            branch: "main",
            terminal: TerminalInfo(bundleId: nil)
        )
        session.source = Session.codexSource
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            processAlive: { _ in true }
        )
        manager.loadSessions()
        XCTAssertEqual(manager.sessions.map(\.sessionId), [threadID])

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [threadID])
        manager.loadSessions()
        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, ["/tmp/p"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [], userExecThreads: [threadID])
        manager.loadSessions()
        XCTAssertEqual(manager.sessions.map(\.sessionId), [threadID])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testSessionManagerHidesArchivedCodexDesktopSessionWhenSourceIsMissing() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-missing-source-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["archived-without-source"])

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-archived-without-source.json")
        var session = codexDesktopSession(sessionId: "archived-without-source", projectPath: "/tmp/p")
        session.source = nil
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), ["archived-without-source"])
        XCTAssertEqual(manager.cleanupSources.map(\.projectPath), ["/tmp/p"])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["archived-without-source"])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, ["/tmp/p"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testSessionManagerHidesArchivedClaudeDesktopSessionButKeepsFileForUnarchive() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-archived-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "archived-claude-session",
            isArchived: true
        )

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("archived-claude-session.json")
        var session = claudeDesktopSession(sessionId: "archived-claude-session", projectPath: "/tmp/p")
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            claudeDesktopSessions: ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), ["archived-claude-session"])
        XCTAssertEqual(manager.cleanupSources.map(\.projectPath), ["/tmp/p"])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)

        try FileManager.default.removeItem(atPath: claudeDir)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "archived-claude-session",
            isArchived: false
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), ["archived-claude-session"])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, ["/tmp/p"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testSessionManagerHidesArchivedClaudeDesktopSessionWhenSourceIsMissing() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-archived-missing-source-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "archived-claude-without-source",
            isArchived: true
        )

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("archived-claude-without-source.json")
        var session = claudeDesktopSession(sessionId: "archived-claude-without-source", projectPath: "/tmp/p")
        session.source = nil
        session.lastActivity = Date()
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            claudeDesktopSessions: ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertEqual(manager.cleanupSources.map(\.sessionId), ["archived-claude-without-source"])
        XCTAssertEqual(manager.cleanupSources.map(\.projectPath), ["/tmp/p"])
        XCTAssertEqual(manager.cleanupActiveProjectPaths, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    @MainActor
    func testSessionManagerHidesEndedClaudeDesktopSessionWithoutMatchingMetadata() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-orphan-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "different-claude-session",
            isArchived: false
        )

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent("orphan-claude-session.json")
        var session = claudeDesktopSession(sessionId: "orphan-claude-session", projectPath: "/tmp/p")
        let ended = Date()
        session.source = nil
        session.pid = nil
        session.endedAt = ended
        session.disconnectedAt = ended
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            claudeDesktopSessions: ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
        )
        manager.loadSessions()

        XCTAssertEqual(manager.sessions.map(\.sessionId), [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertFalse(try Session.fromFile(path: sessionPath).hidden)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: historyDir)).isEmpty)
    }

    // The GC deletion decision must read live Codex archive state on every call, not a snapshot,
    // so a thread archived between a GC scan and its delete keeps its file. Calling the helper
    // twice across a DB change proves it never caches.
    func testIsCodexDesktopThreadArchivedReadsLiveState() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-live-\(UUID().uuidString)"
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        let session = codexDesktopSession(sessionId: "live-thread", projectPath: "/tmp/p")

        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["live-thread"])
        XCTAssertTrue(SessionManager.isCodexDesktopThreadArchived(
            session,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        ))

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        XCTAssertFalse(SessionManager.isCodexDesktopThreadArchived(
            session,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB)
        ))
    }

    // The archive check is gated on the Codex Desktop bundle ID, so a non-Codex-Desktop session
    // sharing an archived thread ID is never treated as archived (and stays on the normal GC path).
    func testIsCodexDesktopThreadArchivedIgnoresNonCodexDesktopHosts() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-host-\(UUID().uuidString)"
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["shared-id"])
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        // A real terminal host (iTerm) running Codex CLI, whose session_id collides with an
        // archived Desktop thread id: it must NOT be treated as archived, because the gate keys on
        // the Codex Desktop bundle id — not on source, and not on a bare nil bundle id that would
        // short-circuit before the lookup even runs.
        var terminalSession = Session(
            sessionId: "shared-id", projectPath: "/tmp/p", branch: "main",
            terminal: TerminalInfo(bundleId: "com.googlecode.iterm2")
        )
        terminalSession.source = Session.codexSource
        XCTAssertFalse(SessionManager.isCodexDesktopThreadArchived(terminalSession))
    }

    func testIsCodexDesktopThreadArchivedIgnoresOpencodeWithLeakedCodexDesktopBundle() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-opencode-\(UUID().uuidString)"
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["opencode-39189"])
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        var session = Session(
            sessionId: "opencode-39189", projectPath: "/tmp/p", branch: "main",
            terminal: TerminalInfo(bundleId: "com.openai.codex")
        )
        session.source = "opencode"

        XCTAssertFalse(SessionManager.isCodexDesktopThreadArchived(session))
    }

    // The Claude archive check is also gated on the Claude Desktop bundle ID. A terminal Claude
    // Code session sharing an archived Desktop cliSessionId must stay on the normal lifecycle path.
    func testIsClaudeDesktopSessionArchivedIgnoresNonClaudeDesktopHosts() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-archived-host-\(UUID().uuidString)"
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try writeClaudeDesktopSessionMetadata(root: claudeDir, cliSessionId: "shared-id", isArchived: true)
        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        var terminalSession = Session(
            sessionId: "shared-id", projectPath: "/tmp/p", branch: "main",
            terminal: TerminalInfo(bundleId: "com.googlecode.iterm2")
        )
        terminalSession.source = "cc"
        XCTAssertFalse(SessionManager.isClaudeDesktopSessionArchived(terminalSession))
    }

    // GC keeps a finished Codex Desktop file while its thread is archived, then reaps it once the
    // thread is unarchived — proving GC consults live archive state at the deletion decision.
    @MainActor
    func testGarbageCollectRespectsLiveCodexArchiveState() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-archived-gc-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        // Aged past the dormant retention window → finished lifecycle, so GC would normally reap it.
        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-finished-thread.json")
        var session = codexDesktopSession(sessionId: "finished-thread", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            desktopAppConnection: DesktopAppConnectionLookup { _ in false }
        )

        try writeCodexStateDatabase(path: stateDB, archivedThreads: ["finished-thread"])
        manager.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager.garbageCollectFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testGarbageCollectRetainsLegacyDesktopEvidenceBeforeAndAfterMigration() throws {
        let root = NSTemporaryDirectory() + "cctop-unresolved-legacy-desktop-gc-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let identityBlockerPath = (root as NSString).appendingPathComponent("session-identities")
        try Data("not a directory".utf8).write(to: URL(fileURLWithPath: identityBlockerPath))
        let threadID = "66666666-7777-4888-8999-aaaaaaaaaaaa"
        let cctopSessionID = "66666666-7777-4888-8999-bbbbbbbbbbbb"
        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("\(threadID).json")
        var session = codexDesktopSession(sessionId: threadID, projectPath: "/tmp/unresolved-legacy-desktop")
        session.cctopSessionId = nil
        session.harnessSessionId = threadID
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        let suiteName = "cctop-unresolved-legacy-desktop-gc-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(["codex:\(threadID)"], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        let visibility = ManualSessionVisibilityStore(defaults: defaults)

        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), manualSessionVisibility: visibility)
        sources.codexThreads = StubCodexThreadState(existing: [threadID], archived: [])
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        manager.garbageCollectFinished()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        XCTAssertTrue(visibility.hiddenSessionIDs.isEmpty)
        XCTAssertEqual(
            defaults.stringArray(forKey: ManualSessionVisibilityStore.legacyDefaultsKey),
            ["codex:\(threadID)"]
        )

        session.cctopSessionId = cctopSessionID
        try session.writeToFile(path: sessionPath)
        try FileManager.default.removeItem(atPath: identityBlockerPath)
        manager.loadSessions()

        XCTAssertNil(defaults.object(forKey: ManualSessionVisibilityStore.legacyDefaultsKey))
        XCTAssertEqual(visibility.hiddenSessionIDs, [cctopSessionID])
        manager.garbageCollectFinished()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
        manager.loadSessions()
        XCTAssertEqual(visibility.hiddenSessionIDs, [cctopSessionID])
        XCTAssertTrue(manager.sessions.isEmpty)
        XCTAssertTrue(manager.recentResumeTargets.isEmpty)

        defaults.removeObject(forKey: ManualSessionVisibilityStore.defaultsKey)
        manager.garbageCollectFinished()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testGarbageCollectRetainsUnreadableLegacyUUIDWhileDurableKeyIsUnresolved() throws {
        let root = NSTemporaryDirectory() + "cctop-unreadable-legacy-uuid-gc-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let sessionPath = (sessionsDir as NSString).appendingPathComponent(
            "77777777-8888-4999-8aaa-bbbbbbbbbbbb.json"
        )
        try Data("not valid session json".utf8).write(to: URL(fileURLWithPath: sessionPath))

        let suiteName = "cctop-unreadable-legacy-uuid-gc-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let cctopSessionID = "77777777-8888-4999-8aaa-cccccccccccc"
        defaults.set(["codex:unresolved"], forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        let visibility = ManualSessionVisibilityStore(defaults: defaults)
        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            manualSessionVisibility: visibility
        )

        manager.garbageCollectFinished()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        defaults.set([cctopSessionID], forKey: ManualSessionVisibilityStore.defaultsKey)
        defaults.removeObject(forKey: ManualSessionVisibilityStore.legacyDefaultsKey)
        manager.garbageCollectFinished()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        defaults.removeObject(forKey: ManualSessionVisibilityStore.defaultsKey)
        manager.garbageCollectFinished()

        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }

    // GC keeps a finished Claude Desktop file while its session metadata is archived, then reaps
    // it once the session is unarchived.
    @MainActor
    func testGarbageCollectRespectsLiveClaudeArchiveState() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-archived-gc-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            try? FileManager.default.removeItem(atPath: root)
        }

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("finished-claude-session.json")
        var session = claudeDesktopSession(sessionId: "finished-claude-session", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            claudeDesktopSessions: ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir),
            desktopAppConnection: DesktopAppConnectionLookup { _ in false }
        )

        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "finished-claude-session",
            isArchived: true
        )
        manager.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        try FileManager.default.removeItem(atPath: claudeDir)
        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "finished-claude-session",
            isArchived: false
        )
        manager.garbageCollectFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }

    @MainActor
    func testGarbageCollectBatchesClaudeArchiveLookupForFinishedDesktopSessions() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-batched-gc-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        for sessionId in ["finished-claude-one", "finished-claude-two"] {
            let sessionPath = (sessionsDir as NSString).appendingPathComponent("\(sessionId).json")
            var session = claudeDesktopSession(sessionId: sessionId, projectPath: "/tmp/p")
            session.lastActivity = old
            session.disconnectedAt = old
            try session.writeToFile(path: sessionPath)
        }

        let claudeState = CountingClaudeDesktopState()
        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), visibilityPrefix: "cctop-claude-batched-gc")
        sources.codexThreads = StubCodexThreadState()
        sources.claudeDesktopSessions = claudeState
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        claudeState.archivedRequests.removeAll()
        manager.garbageCollectFinished()

        XCTAssertEqual(claudeState.archivedRequests.count, 3)
        XCTAssertEqual(
            claudeState.archivedRequests.first,
            Set(["finished-claude-one", "finished-claude-two"])
        )
        XCTAssertEqual(
            Set(claudeState.archivedRequests.dropFirst()),
            Set([
                Set(["finished-claude-one"]),
                Set(["finished-claude-two"])
            ])
        )
    }

    @MainActor
    func testGarbageCollectRechecksClaudeArchiveStateUnderLockBeforeDeleting() throws {
        let root = NSTemporaryDirectory() + "cctop-claude-gc-archive-race-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("finished-claude-race.json")
        var session = claudeDesktopSession(sessionId: "finished-claude-race", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        let claudeState = SequencedClaudeDesktopState(archivedResponses: [[], ["finished-claude-race"]])
        var sources = isolatedSessionDataSources(sessionsDir: URL(fileURLWithPath: sessionsDir), visibilityPrefix: "cctop-claude-gc-archive-race")
        sources.codexThreads = StubCodexThreadState()
        sources.claudeDesktopSessions = claudeState
        sources.desktopAppConnection = DesktopAppConnectionLookup { _ in false }
        sources.processAlive = { _ in false }
        let manager = SessionManager(
            historyManager: HistoryManager(historyDir: URL(fileURLWithPath: historyDir)),
            dataSources: sources,
            startMonitoring: false
        )

        claudeState.archivedRequests.removeAll()
        manager.garbageCollectFinished()

        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))
    }

    func testBuildCandidatesEnrichesDesktopProjectNameFromExternalMetadata() throws {
        let root = NSTemporaryDirectory() + "cctop-desktop-project-enrich-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let claudeDir = (root as NSString).appendingPathComponent("claude-code-sessions")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: root) }

        setenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR", claudeDir, 1)
        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CLAUDE_CODE_SESSIONS_DIR")
            unsetenv("CCTOP_CODEX_STATE_DB")
        }

        try writeClaudeDesktopSessionMetadata(
            root: claudeDir,
            cliSessionId: "claude-desktop-project",
            isArchived: false,
            originCwd: "/Users/dev/projects/cctop",
            worktreeName: "generated-worktree"
        )
        try writeCodexStateDatabase(
            path: stateDB,
            archivedThreads: [],
            cwds: ["codex-desktop-project": "/Users/dev/projects/rdoc"]
        )

        let claudePath = (sessionsDir as NSString).appendingPathComponent("claude.json")
        try claudeDesktopSession(
            sessionId: "claude-desktop-project",
            projectPath: "/tmp/generated-worktree"
        ).writeToFile(path: claudePath)

        let codexPath = (sessionsDir as NSString).appendingPathComponent("codex.json")
        try codexDesktopSession(
            sessionId: "codex-desktop-project",
            projectPath: "/tmp/other-generated-worktree"
        ).writeToFile(path: codexPath)

        let candidates = SessionManager.buildCandidates(
            [URL(fileURLWithPath: claudePath), URL(fileURLWithPath: codexPath)],
            now: Date(),
            desktopAppConnectionLookup: DesktopAppConnectionLookup { _ in true },
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            claudeDesktopSessions: ClaudeDesktopSessionArchiveLookup(sessionsDirectory: claudeDir)
        )
        let namesByID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.session.sessionId, $0.session.desktopProjectName) })

        XCTAssertEqual(namesByID["claude-desktop-project"]!, "cctop")
        XCTAssertEqual(namesByID["codex-desktop-project"]!, "rdoc")
    }

    // Blocker #1: when the archive DB exists but cannot be read, GC must NOT delete a finished
    // Codex Desktop file — failing open here would permanently destroy a session the user archived.
    @MainActor
    func testGarbageCollectKeepsFinishedCodexDesktopFileWhenArchiveDbUnreadable() throws {
        let root = NSTemporaryDirectory() + "cctop-codex-gc-unreadable-\(UUID().uuidString)"
        let sessionsDir = (root as NSString).appendingPathComponent("sessions")
        let historyDir = (root as NSString).appendingPathComponent("history")
        let stateDB = (root as NSString).appendingPathComponent("state_5.sqlite")
        try FileManager.default.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: historyDir, withIntermediateDirectories: true)

        setenv("CCTOP_CODEX_STATE_DB", stateDB, 1)
        defer {
            unsetenv("CCTOP_CODEX_STATE_DB")
            try? FileManager.default.removeItem(atPath: root)
        }

        // Aged past retention → finished lifecycle, so GC would reap it absent the archive guard.
        let old = Date(timeIntervalSinceNow: -SessionManager.lifecycleWindows.retention - 86_400)
        let sessionPath = (sessionsDir as NSString).appendingPathComponent("codex-finished-thread.json")
        var session = codexDesktopSession(sessionId: "finished-thread", projectPath: "/tmp/p")
        session.lastActivity = old
        session.disconnectedAt = old
        try session.writeToFile(path: sessionPath)

        // DB present but unparseable → lookup returns nil → GC fails safe and keeps the file.
        try Data("not a database".utf8).write(to: URL(fileURLWithPath: stateDB))
        let manager = makeManager(
            sessionsDir: sessionsDir,
            historyDir: historyDir,
            codexThreads: CodexThreadArchiveLookup(stateDatabasePath: stateDB),
            desktopAppConnection: DesktopAppConnectionLookup { _ in false }
        )
        manager.garbageCollectFinished()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionPath))

        // Once the DB is readable and shows the thread is not archived, GC reaps it. (Remove the
        // corrupt bytes first — sqlite3 cannot DROP/CREATE over a non-database file.)
        try FileManager.default.removeItem(atPath: stateDB)
        try writeCodexStateDatabase(path: stateDB, archivedThreads: [])
        manager.garbageCollectFinished()
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionPath))
    }
}

@MainActor
private func waitForIdentityMigrationQueue(_ manager: SessionManager, timeout: TimeInterval = 3) {
    let deadline = Date().addingTimeInterval(timeout)
    while !manager.pendingIdentityMigrationPaths.isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.01))
    }
    XCTAssertTrue(manager.pendingIdentityMigrationPaths.isEmpty)
}

private struct VisibilityHookProcessProber: ProcessProbing {
    func parentPID() -> UInt32 { 4242 }
    func startTime(pid: UInt32) -> TimeInterval? { 1_000 }
    func isAlive(pid: UInt32) -> Bool { true }
    func commandName(pid: UInt32) -> String? { nil }
    func controllingTTY() -> String? { nil }
}

private struct VisibilityHookNameResolver: SessionNameResolving {
    func codexThreadName(sessionId: String) -> String? { nil }
    func claudeDesktopTitle(cliSessionId: String) -> String? { nil }
    func transcriptSessionName(transcriptPath: String?, sessionId: String) -> String? { nil }
}

private func startSessionLockHolder(lockPath: String, readyPath: String, holdSeconds: TimeInterval) throws -> Process {
    let script = """
    import fcntl
    import pathlib
    import sys
    import time

    lock_path, ready_path, hold_seconds = sys.argv[1], sys.argv[2], float(sys.argv[3])
    with open(lock_path, "a") as lock_file:
        fcntl.flock(lock_file, fcntl.LOCK_EX)
        pathlib.Path(ready_path).write_text("ready")
        time.sleep(hold_seconds)
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", script, lockPath, readyPath, String(holdSeconds)]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    try waitForFile(path: readyPath, process: process)
    return process
}

private func waitForFile(path: String, process: Process, timeout: TimeInterval = 10) throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if FileManager.default.fileExists(atPath: path) { return }
        if !process.isRunning {
            throw NSError(
                domain: "CctopMenubarTests",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "lock holder exited before acquiring the lock"]
            )
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    throw NSError(
        domain: "CctopMenubarTests",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "timed out waiting for lock holder"]
    )
}

private func terminateProcess(_ process: Process) {
    guard process.isRunning else { return }
    process.terminate()
    process.waitUntilExit()
}

private final class CountingClaudeDesktopState: ClaudeDesktopSessionStateProviding {
    var archivedRequests: [Set<String>] = []

    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>? {
        archivedRequests.append(sessionIDs)
        return []
    }

    func metadataSnapshot(matching sessionIDs: Set<String>) -> ClaudeDesktopSessionMetadataSnapshot? {
        ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: sessionIDs,
            archivedSessionIDs: [],
            projectNamesBySessionID: [:],
            isAuthoritative: true
        )
    }
}

private final class SequencedClaudeDesktopState: ClaudeDesktopSessionStateProviding {
    var archivedRequests: [Set<String>] = []
    private var archivedResponses: [Set<String>]

    init(archivedResponses: [Set<String>]) {
        self.archivedResponses = archivedResponses
    }

    func archivedSessionIDs(matching sessionIDs: Set<String>) -> Set<String>? {
        archivedRequests.append(sessionIDs)
        let response = archivedResponses.isEmpty ? Set<String>() : archivedResponses.removeFirst()
        return response.intersection(sessionIDs)
    }

    func metadataSnapshot(matching sessionIDs: Set<String>) -> ClaudeDesktopSessionMetadataSnapshot? {
        ClaudeDesktopSessionMetadataSnapshot(
            matchedSessionIDs: sessionIDs,
            archivedSessionIDs: [],
            projectNamesBySessionID: [:],
            isAuthoritative: true
        )
    }
}
