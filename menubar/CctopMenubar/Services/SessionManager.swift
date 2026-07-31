import AppKit
import Darwin.libproc
import Foundation
@preconcurrency import UserNotifications
import os.log

let sessionManagerLogger = Logger(subsystem: "com.st0012.CctopMenubar", category: "SessionManager")

struct WorktreeCleanupSessionSnapshot {
    let cleanupSources: [SessionCleanupSource]
    let activeProjectPaths: Set<String>
}

@MainActor
// swiftlint:disable:next type_body_length
class SessionManager: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var recentResumeTargets: [RecentResumeTarget] = []

    let historyManager: HistoryManager
    let dataSources: SessionDataSources
    var cleanupRefreshHandler: (([SessionCleanupSource], Set<String>) -> Void)?
    private(set) var cleanupSources: [SessionCleanupSource] = []
    private(set) var cleanupActiveProjectPaths: Set<String> = []
    private var currentClassificationCleanupSources: [SessionCleanupSource] = []
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
    /// Lifecycle windows: desktop app liveness decides connection when available; `active` is the
    /// fallback recency threshold and `retention` controls dormant desktop cleanup.
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
            sessions = []
            if !hasStoredHideEvidence {
                publishRecentResumeTargets(historyManager.recentProjects.map(RecentResumeTarget.project))
            }
            return
        }

        let oldSessions = sessions

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
        let identifiedInventory = classification.records.map(\.candidate.session) + identifiedCandidates.map(\.session)
        let hiddenSessionIDs = dataSources.manualSessionVisibility.migrateLegacyStableKeys(
            using: identifiedInventory, persistedSessions: allDecoded.map(\.session), inventoryComplete: inventoryComplete
        )
        let unresolvedLegacyKeys = dataSources.manualSessionVisibility.unresolvedDurableLegacyKeys
        let unresolvedLegacyEvidence = unresolvedManualHideEvidence(in: identifiedInventory, legacyKeys: unresolvedLegacyKeys)
        let retainedFinishedCleanupSources = retainedFinishedCleanupSources(
            winners: winners,
            unresolvedLegacyKeys: unresolvedLegacyKeys,
            unresolvedLegacyEvidence: unresolvedLegacyEvidence
        )
        let observedCleanupSources = classification.cleanupSources + retainedFinishedCleanupSources
        let visibleCandidates = identifiedCandidates.filter { candidate in
            let session = candidate.session
            let hiddenByPermanentID = session.cctopSessionId.map(hiddenSessionIDs.contains) ?? false
            let hiddenByLegacyKey = unresolvedLegacyKeys.contains(SessionIdentityPolicy.stableKey(for: session))
            let hiddenByLegacyEvidence = CctopSessionIdentityStore.durableEvidence(
                source: session.source,
                harnessSessionId: session.harnessSessionId,
                legacySessionId: session.sessionId
            ).map(unresolvedLegacyEvidence.contains) ?? false
            return !hiddenByPermanentID && !hiddenByLegacyKey && !hiddenByLegacyEvidence
        }
        let identifiedSessions = SessionIdentityPolicy.dedupedCandidatesByLogicalIdentity(visibleCandidates).map(\.session)
        let loadedSessions = identifiedSessions.map { adjustDisplayStatus($0) }
        let orderedSessions = SessionDisplayPolicy.reconcilingActiveOrder(in: loadedSessions, preserving: oldSessions, now: now)
        let newSessions = orderedSessions
        let displaySignature = SessionDisplayPolicy.signature(for: newSessions, now: now)
        syncTransitionNotifications(for: newSessions, oldSessions: oldSessions)
        // Only publish when data actually changed, or when the presentation bucket changed
        // because an active idle session crossed the stale-idle threshold.
        if newSessions != sessions || displaySignature != lastDisplaySignature {
            if newSessions.count != sessions.count {
                sessionManagerLogger.info("loadSessions: session count \(self.sessions.count) -> \(newSessions.count)")
            }
            lastDisplaySignature = displaySignature
            sessions = newSessions
        }

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
            unresolvedLegacyKeys: unresolvedLegacyKeys,
            unresolvedLegacyEvidence: unresolvedLegacyEvidence
        )
        let activeProjectPaths = classification.protectedProjectPathsForCleanup
        let recentExcludedPaths = activeProjectPaths.union(classification.manualHiddenProjectPaths(hiddenSessionIDs))
        let shouldFreezeVisibilityProjections = !unresolvedLegacyKeys.isEmpty
            || (!inventoryComplete && !hiddenSessionIDs.isEmpty)
        if !shouldFreezeVisibilityProjections {
            _ = historyManager.rebuildRecentProjects(excludingActive: recentExcludedPaths)
            publishRecentResumeTargets(RecentResumeTarget.build(
                projects: historyManager.recentProjects,
                classification: classification,
                excludingDesktopSessionIDs: hiddenSessionIDs
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
            let validSessionIDs = Set(identifiedInventory.compactMap(\.cctopSessionId).filter(Session.isValidCctopSessionId))
            dataSources.manualSessionVisibility.prune(retaining: validSessionIDs)
        }
    }

    private func publishRecentResumeTargets(_ targets: [RecentResumeTarget]) {
        if targets != recentResumeTargets {
            recentResumeTargets = targets
        }
    }

    func withSessionLockForMaintenance(
        sessionPath: String,
        sessionId: String,
        action: String,
        body: () throws -> Void
    ) {
        do {
            let didAcquire = try withSessionLockIfAvailable(
                sessionPath: sessionPath,
                onError: { sessionManagerLogger.warning("\($0, privacy: .public)") },
                body: body
            )
            if !didAcquire {
                sessionManagerLogger.info(
                    "skipping \(action, privacy: .public) for \(sessionId, privacy: .public): session lock is busy"
                )
            }
        } catch {
            sessionManagerLogger.warning(
                "skipping \(action, privacy: .public) for \(sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func cleanupSnapshotForRemoval() -> WorktreeCleanupSessionSnapshot {
        loadSessions()
        return WorktreeCleanupSessionSnapshot(
            cleanupSources: cleanupSources,
            activeProjectPaths: cleanupActiveProjectPaths
        )
    }

    private func hideAutoHiddenSessions(_ sessions: [(URL, Session)]) {
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

    private func autoHideReason(for session: Session) -> String {
        if session.isSubagentSession { return "subagent-owned" }
        if session.isCodexMemoryMaintenanceSession { return "Codex memory maintenance" }
        if session.isCodexDesktopTitleGenerationSession { return "Codex title generation" }
        return "maintenance"
    }

    private func clearReconnectedDesktopSessions(_ candidates: [DedupCandidate], now: Date) {
        for candidate in candidates {
            guard candidate.session.hostClass == .desktop,
                  candidate.session.lifecycle == .active,
                  candidate.session.disconnectedAt != nil else { continue }
            withSessionLockForMaintenance(
                sessionPath: candidate.path,
                sessionId: candidate.session.sessionId,
                action: "desktop reconnect update"
            ) {
                guard var session = try? Session.fromFile(path: candidate.path),
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

    private func stampDisconnectedDesktopSessions(_ candidates: [DedupCandidate], now: Date) {
        for candidate in candidates {
            guard candidate.session.hostClass == .desktop,
                  candidate.session.lifecycle == .dormant,
                  candidate.session.disconnectedAt == nil else { continue }
            withSessionLockForMaintenance(
                sessionPath: candidate.path,
                sessionId: candidate.session.sessionId,
                action: "desktop disconnect update"
            ) {
                guard var session = try? Session.fromFile(path: candidate.path),
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
        let legacyKeys = dataSources.manualSessionVisibility.unresolvedDurableLegacyKeys
        let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
        let legacyEvidence = unresolvedManualHideEvidence(in: jsonFiles, legacyKeys: legacyKeys)
        preloadDesktopArchiveStateForFinishedSessions(in: jsonFiles, now: now)
        var removedAny = false
        for url in jsonFiles {
            if sweepLegacyUUIDFileIfNeeded(url, unresolvedLegacyKeys: legacyKeys, unresolvedLegacyEvidence: legacyEvidence) { continue }
            withSessionLockForMaintenance(sessionPath: url.path, sessionId: url.deletingPathExtension().lastPathComponent, action: "desktop GC") {
                guard let data = try? Data(contentsOf: url),
                      let session = try? JSONDecoder.sessionDecoder.decode(Session.self, from: data) else {
                    return   // decode failure → never treat as finished
                }
                guard !session.hidden, !session.shouldAutoHide else { return }
                let hostClass = session.hostClass
                guard hostClass == .desktop else { return }   // non-desktop handled on the fast path
                let life = SessionLifecyclePolicy.lifecycle(
                    for: session,
                    hostClass: hostClass,
                    processAlive: dataSources.processAlive(session),
                    now: now,
                    windows: Self.lifecycleWindows,
                    desktopAppRunning: Self.desktopAppRunning(for: session, lookup: dataSources.desktopAppConnection)
                )
                guard life == .finished else { return }
                guard !shouldRetainFinishedManualHideEvidence(
                    session,
                    legacyKeys: legacyKeys,
                    legacyEvidence: legacyEvidence
                ) else { return }
                // Re-check external archive state under the lock so a concurrent archive retains its file.
                guard !Self.isArchivedDesktopSession(
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

    private func refreshCleanupSources(from currentSources: [SessionCleanupSource], activeProjectPaths: Set<String>) {
        currentClassificationCleanupSources = currentSources
        cleanupSources = historyManager.lastDecodedHistorySessions
            .compactMap { SessionCleanupSource(endedSession: $0) } + currentSources
        cleanupActiveProjectPaths = activeProjectPaths
        cleanupRefreshHandler?(cleanupSources, activeProjectPaths)
    }

    /// Apply display-side status adjustments. The session file on disk is NOT modified.
    private func adjustDisplayStatus(_ session: Session) -> Session {
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
    nonisolated static func adjustIdleTimeout(_ session: Session, now: Date) -> Session {
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
    private func adjustPermissionStatus(_ session: Session) -> Session {
        guard session.status == .waitingPermission,
              let pid = session.pid else {
            return session
        }

        // Small tolerance for clock/serialization jitter; MCP servers started minutes+ before.
        let cutoff = session.lastActivity.timeIntervalSince1970 - 1.0
        for childPid in listChildPids(pid: pid) {
            if let startTime = Session.processStartTime(pid: UInt32(childPid)),
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
