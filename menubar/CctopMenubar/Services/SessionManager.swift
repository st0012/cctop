import AppKit
import Darwin.libproc
import Foundation
@preconcurrency import UserNotifications
import os.log

let sessionManagerLogger = Logger(subsystem: "com.st0012.CctopMenubar", category: "SessionManager")

struct WorktreeCleanupSessionSnapshot {
    let cleanupSources: [SessionDataCleanupSource]
    let activeProjectPaths: Set<String>
}

@MainActor
// swiftlint:disable:next type_body_length
class SessionManager: ObservableObject {
    @Published private(set) var userSessions: [UserSession] = []
    @Published var recentResumeTargets: [RecentResumeTarget] = []

    let historyManager: HistoryManager
    let dataSources: SessionDataSources
    var cleanupRefreshHandler: (([SessionDataCleanupSource], Set<String>) -> Void)?
    private(set) var cleanupSources: [SessionDataCleanupSource] = []
    private(set) var cleanupActiveProjectPaths: Set<String> = []
    private var currentClassificationCleanupSources: [SessionDataCleanupSource] = []
    var codexThreadClassificationMemory = CodexThreadClassificationMemory()

    private let sessionsDir: URL
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: DispatchWorkItem?
    private var livenessTimer: Timer?
    private var gcTimer: Timer?
    private var lastDisplaySignature = SessionDisplayPolicy.Signature.empty
    var lastLoadLogSignature: SessionLoadLogSignature?
    var sessionFileCache: [String: SessionFileCacheEntry] = [:]
    var pendingIdentityMigrationPaths: Set<String> = []
    /// Lifecycle windows: `active` is the recent-activity connection fallback; `retention`
    /// is Codex's absolute inactivity cap and the dormant non-Codex desktop cleanup window.
    nonisolated static let lifecycleWindows = LifecycleWindows(active: 600, retention: 1_209_600)
    nonisolated static let codexMissingThreadGraceSeconds: TimeInterval = 10

    /// `startMonitoring: false` skips the directory watcher and the periodic timers so tests can
    /// drive `loadSessions()`/`garbageCollectFinished()` explicitly without background reloads.
    init(
        historyManager: HistoryManager,
        dataSources: SessionDataSources = .live(),
        startMonitoring: Bool = true
    ) {
        self.historyManager = historyManager
        self.dataSources = dataSources
        self.sessionsDir = dataSources.sessionsDir
        loadSessions()
        guard startMonitoring else { return }
        startWatching()
        // Pass 1 (fast): read, derive lifecycle, dedup, publish.
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.loadSessions() }
        }
        // Pass 2 (slow): GC finished desktop files under the per-session lock.
        gcTimer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.garbageCollectFinished() }
        }
    }

    // swiftlint:disable:next function_body_length
    func loadSessions() {
        let hasStoredHideEvidence = dataSources.manualSessionVisibility.hasStoredHideEvidence
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            sessionManagerLogger.warning("loadSessions: could not read directory")
            lastDisplaySignature = .empty
            lastLoadLogSignature = nil
            sessionFileCache.removeAll()
            updateSessionProjection([])
            if !hasStoredHideEvidence {
                publishRecentResumeTargets(historyManager.recentProjects.map(RecentResumeTarget.project))
            }
            return
        }

        let oldUserSessions = userSessions

        let jsonFiles = sessionJSONFiles(in: files)
        let allDecoded = decodedSessions(from: jsonFiles)
        let inventoryComplete = allDecoded.count == jsonFiles.count
        let classification = identifyingPersistedRecords(
            in: deriveSessionClassification(from: allDecoded),
            knownRecords: allDecoded
        )
        let hidden = classification.records.filter { $0.disposition == .hidden(.persistedHidden) }
        let autoHidden = classification.autoHiddenSessions
        let displayCandidates = classification.displayCandidates
        let summary = SessionLoadSummary(
            files: jsonFiles.count,
            decoded: allDecoded.count,
            live: displayCandidates.count,
            hidden: hidden.count,
            autoHidden: autoHidden.count
        )
        logLoadSummary(summary, classification: classification)

        // Publish active + dormant; finished are hidden (swept below / by GC).
        let winners = SessionIdentityPolicy.dedupedCandidatesByStableKey(displayCandidates)
        let now = dataSources.now()
        let identifiedCandidates = identifiedPublishableCandidates(winners: winners, knownRecords: allDecoded)
        let identifiedInventory = classification.records.map(\.candidate.data) + identifiedCandidates.map(\.data)
        dataSources.manualSessionVisibility.migrateLegacyStableKeys(
            using: identifiedInventory, persistedSessions: allDecoded.map(\.session), inventoryComplete: inventoryComplete
        )
        let manualHides = dataSources.manualSessionVisibility.manualHideEvidence(in: identifiedInventory)
        let hiddenSessionIDs = manualHides.hiddenSessionIDs
        let retainedFinishedCleanupSources = retainedFinishedCleanupSources(winners: winners, manualHides: manualHides)
        let observedCleanupSources = classification.cleanupSources + retainedFinishedCleanupSources
        let visibleCandidates = identifiedCandidates.filter { !manualHides.matches($0.data) }
        let visibleRecords = displayCandidates.filter { !manualHides.matches($0.data) }
        let groupedUserSessions = UserSession.grouping(
            winners: visibleCandidates,
            records: visibleRecords
        )
        let loadedUserSessions = groupedUserSessions.map {
            $0.replacingDisplayData(adjustDisplayStatus($0.displayRecord.data))
        }
        let newUserSessions = SessionDisplayPolicy.reconcilingOrder(
            in: loadedUserSessions,
            preserving: oldUserSessions,
            now: now
        )
        let displaySignature = SessionDisplayPolicy.signature(for: newUserSessions, now: now)
        updateSessionProjection(
            newUserSessions,
            displaySignature: displaySignature,
            syncNotificationsFrom: oldUserSessions
        )

        hideAutoHiddenSessions(autoHidden)
        hideCodexInternalHelperSessions(classification.codexInternalHelperCandidates)
        clearReconnectedDesktopSessions(displayCandidates, now: now)
        stampDisconnectedDesktopSessions(displayCandidates, now: now)
        // Non-desktop finished sessions keep today's behavior: archive to Recent Projects and
        // remove now (no Recent-Projects lag). Desktop files are retained while dormant and reaped
        // only by the slow, lock-held GC. No dormant file is ever deleted on this fast path.
        let newlyArchivedCleanupSources = archiveAndRemoveFinishedNonDesktop(
            classification.finishedNonDesktopCandidates,
            winners: winners,
            manualHides: manualHides
        )
        let activeProjectPaths = classification.protectedProjectPathsForCleanup
        let recentExcludedPaths = activeProjectPaths.union(classification.manualHiddenProjectPaths(hiddenSessionIDs))
        let publishedSessionIDs = Set(newUserSessions.compactMap { $0.identity.cctopSessionID })
        let shouldFreezeVisibilityProjections = manualHides.hasUnresolvedLegacyKeys
            || (!inventoryComplete && !hiddenSessionIDs.isEmpty)
        if !shouldFreezeVisibilityProjections {
            _ = historyManager.rebuildRecentProjects(excludingActive: recentExcludedPaths)
            publishRecentResumeTargets(RecentResumeTarget.build(
                projects: historyManager.recentProjects,
                classification: classification,
                excludingDesktopSessionIDs: hiddenSessionIDs.union(publishedSessionIDs)
            ))
            refreshCleanupSources(from: observedCleanupSources, activeProjectPaths: activeProjectPaths)
        } else { // Freeze existing items, add unresolved finished evidence, and only grow path protection.
            let frozenCleanupSources = mergingCleanupSources(
                currentClassificationCleanupSources,
                with: observedCleanupSources + newlyArchivedCleanupSources
            )
            let frozenActiveProjectPaths = cleanupActiveProjectPaths.union(activeProjectPaths)
            if frozenCleanupSources != currentClassificationCleanupSources
                || frozenActiveProjectPaths != cleanupActiveProjectPaths {
                refreshCleanupSources(from: frozenCleanupSources, activeProjectPaths: frozenActiveProjectPaths)
            }
        }

        // Prune permanent IDs only after a complete inventory; partial reads retain them to avoid revealing sessions.
        if inventoryComplete {
            let validSessionIDs = Set(identifiedInventory.compactMap(\.cctopSessionId).filter(CctopSessionID.isValid))
            dataSources.manualSessionVisibility.prune(retaining: validSessionIDs)
        }
    }

    private func publishRecentResumeTargets(_ targets: [RecentResumeTarget]) {
        if targets != recentResumeTargets {
            recentResumeTargets = targets
        }
    }

    func updateSessionProjection(
        _ newUserSessions: [UserSession],
        displaySignature: SessionDisplayPolicy.Signature? = nil,
        syncNotificationsFrom oldUserSessions: [UserSession]? = nil
    ) {
        let oldCount = userSessions.count
        let displayChanged = displaySignature.map { $0 != lastDisplaySignature } ?? false
        guard newUserSessions != userSessions || displayChanged else { return }
        if newUserSessions.count != oldCount {
            sessionManagerLogger.info("loadSessions: session count \(oldCount) -> \(newUserSessions.count)")
        }
        if let displaySignature {
            lastDisplaySignature = displaySignature
        }
        userSessions = newUserSessions
        if let oldUserSessions {
            syncTransitionNotifications(for: newUserSessions, oldUserSessions: oldUserSessions)
        }
    }

    func cleanupSnapshotForRemoval() -> WorktreeCleanupSessionSnapshot {
        loadSessions()
        return WorktreeCleanupSessionSnapshot(
            cleanupSources: cleanupSources,
            activeProjectPaths: cleanupActiveProjectPaths
        )
    }

    private func hideAutoHiddenSessions(_ sessions: [(URL, SessionData)]) {
        for (url, session) in sessions {
            withSessionLockForMaintenance(sessionPath: url.path, sessionId: session.sessionId, action: "auto-hide update") {
                guard let hiddenSession = try Self.autoHiddenSessionSnapshot(path: url.path) else { return }
                sessionManagerLogger.info(
                    "hiding \(self.autoHideReason(for: session), privacy: .public) session \(session.sessionId, privacy: .public)"
                )
                try hiddenSession.writeToFile(path: url.path)
            }
        }
    }

    private func autoHideReason(for session: SessionData) -> String {
        if session.isSubagentSession { return "subagent-owned" }
        if session.isCodexMemoryMaintenanceSession { return "Codex memory maintenance" }
        if session.isCodexTitleGenerationSession { return "Codex title generation" }
        return "maintenance"
    }

    private func clearReconnectedDesktopSessions(_ candidates: [SessionRecord], now: Date) {
        for candidate in candidates {
            guard candidate.data.hostClass == .desktop,
                  candidate.data.lifecycle == .active,
                  candidate.data.disconnectedAt != nil else { continue }
            withSessionLockForMaintenance(
                sessionPath: candidate.path,
                sessionId: candidate.data.sessionId,
                action: "desktop reconnect update"
            ) {
                guard var session = try? SessionData.fromFile(path: candidate.path),
                      session.hostClass == .desktop,
                      session.disconnectedAt != nil else {
                    return
                }
                let lifecycle = SessionLifecyclePolicy.lifecycle(
                    for: session,
                    hostClass: SessionHostClass.desktop,
                    processAlive: dataSources.processAlive(session),
                    now: now,
                    windows: Self.lifecycleWindows,
                    desktopAppRunning: Self.desktopAppRunning(for: session, lookup: dataSources.desktopAppConnection)
                )
                guard lifecycle == .active else { return }
                session.disconnectedAt = nil
                try? session.writeToFile(path: candidate.path)
            }
        }
    }

    private func stampDisconnectedDesktopSessions(_ candidates: [SessionRecord], now: Date) {
        for candidate in candidates {
            guard candidate.data.hostClass == .desktop,
                  candidate.data.lifecycle == .dormant,
                  candidate.data.disconnectedAt == nil else { continue }
            withSessionLockForMaintenance(
                sessionPath: candidate.path,
                sessionId: candidate.data.sessionId,
                action: "desktop disconnect update"
            ) {
                guard var session = try? SessionData.fromFile(path: candidate.path),
                      session.hostClass == .desktop,
                      session.disconnectedAt == nil else {
                    return
                }
                let lifecycle = SessionLifecyclePolicy.lifecycle(
                    for: session,
                    hostClass: SessionHostClass.desktop,
                    processAlive: dataSources.processAlive(session),
                    now: now,
                    windows: Self.lifecycleWindows,
                    desktopAppRunning: Self.desktopAppRunning(for: session, lookup: dataSources.desktopAppConnection)
                )
                guard lifecycle == .dormant else { return }
                session.disconnectedAt = now
                try? session.writeToFile(path: candidate.path)
            }
        }
    }

    /// Reap finished desktop and pre-PID legacy files after lock-held lifecycle validation.
    func garbageCollectFinished() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        let now = dataSources.now()
        let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
        let manualHides = dataSources.manualSessionVisibility.manualHideEvidence(
            in: jsonFiles.compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.sessionDecoder.decode(SessionData.self, from: $0) }
            }
        )
        preloadArchiveStateForFinishedRetainedSessions(in: jsonFiles, now: now)
        var removedAny = false
        for url in jsonFiles {
            if sweepLegacyUUIDFileIfNeeded(url, manualHides: manualHides) { continue }
            withSessionLockForMaintenance(
                sessionPath: url.path,
                sessionId: url.deletingPathExtension().lastPathComponent,
                action: "retained session GC"
            ) {
                guard let data = try? Data(contentsOf: url),
                      let session = try? JSONDecoder.sessionDecoder.decode(SessionData.self, from: data) else {
                    return   // decode failure → never treat as finished
                }
                guard !session.hidden, !session.shouldAutoHide else { return }
                let hostClass = session.hostClass
                guard session.isCodex || hostClass == .desktop else { return } // Other sessions use the fast path.
                let life = SessionLifecyclePolicy.lifecycle(
                    for: session,
                    hostClass: hostClass,
                    processAlive: dataSources.processAlive(session),
                    now: now,
                    windows: Self.lifecycleWindows,
                    desktopAppRunning: Self.desktopAppRunning(for: session, lookup: dataSources.desktopAppConnection)
                )
                guard life == .finished else { return }
                guard !shouldRetainFinishedManualHideEvidence(session, matching: manualHides) else { return }
                // Re-check external archive state under the lock so a concurrent archive retains its file.
                guard !Self.isArchivedRetainedSession(
                    session,
                    codexThreads: dataSources.codexThreads,
                    claudeDesktopSessions: dataSources.claudeDesktopSessions
                ) else { return }
                try? fm.removeItem(at: url)   // .json ONLY — never the .lock
                removedAny = true
            }
        }
        if removedAny, historyManager.rebuildRecentProjects(excludingActive: cleanupActiveProjectPaths) {
            refreshCleanupSources(from: currentClassificationCleanupSources, activeProjectPaths: cleanupActiveProjectPaths)
        }
    }

    private func refreshCleanupSources(from currentSources: [SessionDataCleanupSource], activeProjectPaths: Set<String>) {
        currentClassificationCleanupSources = currentSources
        cleanupSources = historyManager.lastDecodedHistorySessions
            .compactMap { SessionDataCleanupSource(endedSession: $0) } + currentSources
        cleanupActiveProjectPaths = activeProjectPaths
        cleanupRefreshHandler?(cleanupSources, activeProjectPaths)
    }

    /// Apply display-side status adjustments. The session file on disk is NOT modified.
    private func adjustDisplayStatus(_ session: SessionData) -> SessionData {
        // A dormant (backgrounded) session isn't actively in any state — render it neutral (idle)
        // so it never shows a false "waiting"/"permission" pill. It's already excluded from counts
        // and notifications; this keeps the card itself honest.
        if session.lifecycle == .dormant {
            var result = session
            result.status = .idle
            return result
        }
        var result = adjustPermissionStatus(session)
        result = Self.adjustIdleTimeout(result, now: dataSources.now())
        return result
    }

    private static let idleTimeoutSeconds: TimeInterval = 3600 // 60 minutes

    /// If a session has been in `waitingInput` for over 60 minutes, treat it as
    /// `idle` for display. The user likely walked away.
    nonisolated static func adjustIdleTimeout(_ session: SessionData, now: Date) -> SessionData {
        guard session.status == .waitingInput,
              now.timeIntervalSince(session.lastActivity) > Self.idleTimeoutSeconds else {
            return session
        }
        var adjusted = session
        adjusted.status = .idle
        return adjusted
    }

    /// If a session is in `waiting_permission` but has a child process that started
    /// AFTER the permission was requested, the user has granted permission and a tool
    /// is running. Adjust the in-memory status to `working` so the UI reflects reality.
    /// The session file on disk is NOT modified.
    ///
    /// This distinguishes tool subprocesses from long-lived children like MCP servers
    /// by comparing each child's start time against `lastActivity` (set when
    /// PermissionRequest fired).
    private func adjustPermissionStatus(_ session: SessionData) -> SessionData {
        guard session.status == .waitingPermission,
              let pid = session.pid else {
            return session
        }

        // Small tolerance for clock/serialization jitter; MCP servers started minutes+ before.
        let cutoff = session.lastActivity.timeIntervalSince1970 - 1.0
        for childPid in listChildPids(pid: pid) {
            if let startTime = SessionData.processStartTime(pid: UInt32(childPid)),
               startTime > cutoff {
                var adjusted = session
                adjusted.status = .working
                return adjusted
            }
        }
        return session
    }

    /// Returns the direct child PIDs of the given process.
    private func listChildPids(pid: UInt32) -> [pid_t] {
        let reportedCount = proc_listchildpids(pid_t(pid), nil, 0)
        let count = ProcessChildPIDProbe.capacity(fromReportedCount: reportedCount)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: count)
        let actual = proc_listchildpids(pid_t(pid), &pids, ProcessChildPIDProbe.bufferSize(forCapacity: count))
        let actualCount = ProcessChildPIDProbe.returnedCount(actual, capacity: count)
        return Array(pids.prefix(actualCount))
    }

    static func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                DispatchQueue.main.async {
                    // Menubar-only apps (activationPolicy = .accessory) can't show the
                    // macOS notification permission prompt. Temporarily become a regular
                    // app so the system presents the dialog, then switch back.
                    let wasAccessory = NSApplication.shared.activationPolicy() == .accessory
                    if wasAccessory { NSApplication.shared.setActivationPolicy(.regular) }

                    center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                        if let error {
                            sessionManagerLogger.error("Notification permission error: \(error, privacy: .public)")
                        }
                        sessionManagerLogger.info("Notification permission granted: \(granted, privacy: .public)")
                        DispatchQueue.main.async {
                            if wasAccessory { NSApplication.shared.setActivationPolicy(.accessory) }
                        }
                    }
                }
            case .denied:
                DispatchQueue.main.async {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
                        NSWorkspace.shared.open(url)
                    }
                }
            default:
                break
            }
        }
    }

    private func startWatching() {
        try? FileManager.default.createDirectory(at: sessionsDir, withIntermediateDirectories: true)

        let fd = open(sessionsDir.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.debounceTask?.cancel()
            let task = DispatchWorkItem { [weak self] in
                Task { @MainActor in
                    self?.loadSessions()
                }
            }
            self?.debounceTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: task)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
        livenessTimer?.invalidate()
        gcTimer?.invalidate()
    }
}
