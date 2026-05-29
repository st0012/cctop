import AppKit
import Darwin.libproc
import Foundation
import UserNotifications
import os.log

let sessionManagerLogger = Logger(subsystem: "com.st0012.CctopMenubar", category: "SessionManager")
private typealias SessionFile = (url: URL, session: Session)

@MainActor
// swiftlint:disable:next type_body_length
class SessionManager: ObservableObject {
    @Published var sessions: [Session] = []

    let historyManager: HistoryManager

    private let sessionsDir: URL
    private let desktopAppConnectionLookup: DesktopAppConnectionLookup
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: DispatchWorkItem?
    private var livenessTimer: Timer?
    private var gcTimer: Timer?

    /// Lifecycle windows: desktop app liveness decides connection when available; `active` is the
    /// fallback recency threshold and `retention` controls dormant desktop cleanup.
    nonisolated static let lifecycleWindows = LifecycleWindows(active: 600, retention: 1_209_600)

    init(
        historyManager: HistoryManager,
        desktopAppConnectionLookup: DesktopAppConnectionLookup = .live
    ) {
        self.historyManager = historyManager
        self.desktopAppConnectionLookup = desktopAppConnectionLookup
        self.sessionsDir = URL(fileURLWithPath: Config.sessionsDir())
        loadSessions()
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

    func loadSessions() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else {
            sessionManagerLogger.warning("loadSessions: could not read directory")
            sessions = []
            return
        }

        // Notification transition guards use the same identity policy as dedup: Codex and
        // desktop conversations are stable by session_id; other sessions keep PID identity.
        let oldStatuses = Dictionary(
            sessions.map { (SessionIdentityPolicy.stableKey(for: $0), $0.status) },
            uniquingKeysWith: { first, _ in first }
        )

        let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
        let allDecoded = decodedSessions(from: jsonFiles)
        let hidden = allDecoded.filter { $0.session.hidden }
        let autoHidden = allDecoded.filter { !$0.session.hidden && $0.session.shouldAutoHide }
        let visibleFiles = allDecoded.filter { !$0.session.hidden && !$0.session.shouldAutoHide }.map(\.url)
        let candidates = Self.buildCandidates(visibleFiles, now: Date(), desktopAppConnectionLookup: desktopAppConnectionLookup)
        let archivedCodexThreadIDs = Self.archivedCodexDesktopThreadIDs(in: candidates.map(\.session))
        let claudeMetadata = Self.claudeDesktopMetadataSnapshot(in: candidates.map(\.session))
        let archivedClaudeSessionIDs = claudeMetadata?.archivedSessionIDs ?? []
        let liveCandidates = candidates.filter {
            !Self.isArchivedCodexDesktopSession($0.session, archivedThreadIDs: archivedCodexThreadIDs)
                && !Self.isArchivedClaudeDesktopSession($0.session, archivedSessionIDs: archivedClaudeSessionIDs)
                && !Self.isOrphanedEndedClaudeDesktopSession($0.session, metadataSnapshot: claudeMetadata)
        }
        sessionManagerLogger.info("loadSessions: \(jsonFiles.count) files, \(allDecoded.count) decoded")
        sessionManagerLogger.info(
            "loadSessions: \(liveCandidates.count) visible candidates, \(hidden.count) hidden, \(autoHidden.count) auto-hidden"
        )
        sessionManagerLogger.info("loadSessions: \(archivedCodexThreadIDs.count) codex-archived")
        sessionManagerLogger.info("loadSessions: \(archivedClaudeSessionIDs.count) claude-archived")

        // Publish active + dormant; finished are hidden (swept below / by GC).
        let winners = SessionIdentityPolicy.dedupedCandidatesByStableKey(liveCandidates)
        let newSessions = winners
            .filter { $0.session.lifecycle != .finished }
            .map { adjustDisplayStatus($0.session) }

        sendTransitionNotifications(for: newSessions, oldStatuses: oldStatuses)
        // Only publish when data actually changed to avoid unnecessary SwiftUI re-renders.
        if newSessions != sessions {
            if newSessions.count != sessions.count {
                sessionManagerLogger.info("loadSessions: session count \(self.sessions.count) -> \(newSessions.count)")
            }
            sessions = newSessions
        }

        hideAutoHiddenSessions(autoHidden)
        clearReconnectedDesktopSessions(liveCandidates, now: Date())
        stampDisconnectedDesktopSessions(liveCandidates, now: Date())

        // Non-desktop finished sessions keep today's behavior: archive to Recent Projects and
        // remove now (no Recent-Projects lag). Desktop files are retained while dormant and reaped
        // only by the slow, lock-held GC. No dormant file is ever deleted on this fast path.
        archiveAndRemoveFinishedNonDesktop(liveCandidates, winners: winners)
        historyManager.rebuildRecentProjects(excludingActive: Set(sessions.map(\.projectPath)))
    }

    private func sendTransitionNotifications(for newSessions: [Session], oldStatuses: [String: SessionStatus]) {
        // Notifications: only a LIVE (active) session that NEWLY needs attention. Dormant never notifies.
        guard UserDefaults.standard.bool(forKey: "notificationsEnabled") else { return }
        for session in newSessions where session.lifecycle == .active {
            guard session.status.needsAttention,
                  let oldStatus = oldStatuses[SessionIdentityPolicy.stableKey(for: session)],
                  !oldStatus.needsAttention else { continue }
            sendNotification(for: session)
        }
    }

    private func decodedSessions(from jsonFiles: [URL]) -> [SessionFile] {
        jsonFiles.compactMap { url in
            guard let data = try? Data(contentsOf: url) else {
                sessionManagerLogger.warning("loadSessions: could not read \(url.lastPathComponent, privacy: .public)")
                return nil
            }
            do {
                let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
                return (url, session)
            } catch {
                sessionManagerLogger.error("loadSessions: decode failed \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
    }

    private func hideAutoHiddenSessions(_ sessions: [(URL, Session)]) {
        for (url, session) in sessions {
            sessionManagerLogger.info(
                "hiding \(self.autoHideReason(for: session), privacy: .public) session \(session.sessionId, privacy: .public)"
            )
            do {
                try withSessionLock(sessionPath: url.path) {
                    guard let hiddenSession = try Self.autoHiddenSessionSnapshot(path: url.path) else { return }
                    try hiddenSession.writeToFile(path: url.path)
                }
            } catch {
                sessionManagerLogger.warning(
                    "skipping auto-hide update for \(session.sessionId, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func autoHideReason(for session: Session) -> String {
        if session.isCodexMemoryMaintenanceSession { return "Codex memory maintenance" }
        if session.isCodexDesktopTitleGenerationSession { return "Codex title generation" }
        return "maintenance"
    }

    private func archiveAndRemoveFinishedNonDesktop(_ candidates: [DedupCandidate], winners: [DedupCandidate]) {
        let winnerPaths = Set(winners.map(\.path))
        for candidate in candidates where candidate.session.lifecycle == .finished
                                    && candidate.session.hostClass != .desktop {
            // A finished dedup winner is a real completed non-desktop session, so keep today's
            // Recent Projects behavior. A finished duplicate loser is stale migration debris;
            // remove it without archiving so it cannot later surface as a separate session.
            if winnerPaths.contains(candidate.path) {
                archiveAndRemove(candidate)
            } else {
                removeStaleDuplicate(candidate)
            }
        }
    }

    private func archiveAndRemove(_ candidate: DedupCandidate) {
        let session = candidate.session
        // A dead non-desktop process holds no lock, so removing its .json needs no flock. Remove
        // the .json ONLY — never the .lock (unlinking a lock a hook still holds splits the inode).
        if historyManager.archiveSession(session) {
            try? FileManager.default.removeItem(atPath: candidate.path)
        } else {
            sessionManagerLogger.warning("skipping removal of \(session.sessionId, privacy: .public) — archive failed")
        }
    }

    private func removeStaleDuplicate(_ candidate: DedupCandidate) {
        sessionManagerLogger.info("removing stale duplicate session file \(candidate.path, privacy: .public)")
        try? FileManager.default.removeItem(atPath: candidate.path)
    }

    private func clearReconnectedDesktopSessions(_ candidates: [DedupCandidate], now: Date) {
        for candidate in candidates {
            guard candidate.session.hostClass == .desktop,
                  candidate.session.lifecycle == .active,
                  candidate.session.disconnectedAt != nil else { continue }
            try? withSessionLock(sessionPath: candidate.path) {
                guard var session = try? Session.fromFile(path: candidate.path),
                      session.hostClass == .desktop,
                      session.disconnectedAt != nil else {
                    return
                }
                let lifecycle = SessionLifecyclePolicy.lifecycle(
                    for: session,
                    hostClass: SessionHostClass.desktop,
                    processAlive: session.isAlive,
                    now: now,
                    windows: Self.lifecycleWindows,
                    desktopAppRunning: Self.desktopAppRunning(for: session, lookup: desktopAppConnectionLookup)
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
            try? withSessionLock(sessionPath: candidate.path) {
                guard var session = try? Session.fromFile(path: candidate.path),
                      session.hostClass == .desktop,
                      session.disconnectedAt == nil else {
                    return
                }
                let lifecycle = SessionLifecyclePolicy.lifecycle(
                    for: session,
                    hostClass: SessionHostClass.desktop,
                    processAlive: session.isAlive,
                    now: now,
                    windows: Self.lifecycleWindows,
                    desktopAppRunning: Self.desktopAppRunning(for: session, lookup: desktopAppConnectionLookup)
                )
                guard lifecycle == .dormant else { return }
                session.disconnectedAt = now
                try? session.writeToFile(path: candidate.path)
            }
        }
    }

    /// Pass 2: reap finished desktop files (non-desktop is handled on the fast path). Acquires
    /// the per-session lock, re-validates under it, and unlinks the `.json` ONLY (never the `.lock`).
    /// A decode failure is never treated as finished. Also sweeps pre-PID legacy files.
    func garbageCollectFinished() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: nil) else { return }
        let now = Date()
        let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
        var removedAny = false
        for url in jsonFiles {
            if Self.isLegacyUUIDFilename(url.deletingPathExtension().lastPathComponent) {
                try? fm.removeItem(at: url)   // pre-PID legacy file; no live writer to race
                continue
            }
            try? withSessionLock(sessionPath: url.path) {
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
                    processAlive: session.isAlive,
                    now: now,
                    windows: Self.lifecycleWindows,
                    desktopAppRunning: Self.desktopAppRunning(for: session, lookup: desktopAppConnectionLookup)
                )
                guard life == .finished else { return }
                // Re-read external desktop archive state under the lock, right before deleting. A session
                // archived after the directory scan must keep its .json so a later unarchive can restore it.
                guard !Self.isArchivedDesktopSession(session) else { return }
                try? fm.removeItem(at: url)   // .json ONLY — never the .lock
                removedAny = true
            }
        }
        if removedAny {
            historyManager.rebuildRecentProjects(excludingActive: Set(sessions.map(\.projectPath)))
        }
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
        result = Self.adjustIdleTimeout(result)
        return result
    }

    private static let idleTimeoutSeconds: TimeInterval = 3600 // 60 minutes

    /// If a session has been in `waitingInput` for over 60 minutes, treat it as
    /// `idle` for display. The user likely walked away.
    private static func adjustIdleTimeout(_ session: Session) -> Session {
        guard session.status == .waitingInput,
              -session.lastActivity.timeIntervalSinceNow > Self.idleTimeoutSeconds else {
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
        let size = proc_listchildpids(pid_t(pid), nil, 0)
        guard size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<pid_t>.size
        var pids = [pid_t](repeating: 0, count: count)
        let actual = proc_listchildpids(pid_t(pid), &pids, size)
        let actualCount = Int(actual) / MemoryLayout<pid_t>.size
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

    private func sendNotification(for session: Session) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        sessionManagerLogger.error("Notification permission error: \(error, privacy: .public)")
                    }
                    if granted {
                        self.postNotification(for: session)
                    }
                }
            case .authorized, .provisional, .ephemeral:
                self.postNotification(for: session)
            default:
                break
            }
        }
    }

    private func postNotification(for session: Session) {
        let content = UNMutableNotificationContent()
        content.title = session.displayName
        switch session.status {
        case .waitingPermission:
            content.body = session.notificationMessage ?? "Permission needed"
        case .waitingInput:
            content.body = session.lastPrompt.map { "Waiting: \(String($0.prefix(80)))" } ?? "Waiting for input"
        default:
            content.body = "Needs attention"
        }
        content.sound = .default
        content.userInfo = ["sessionPID": session.pid.map(String.init) ?? ""]

        let request = UNNotificationRequest(
            identifier: "session-\(session.id)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                sessionManagerLogger.error("Failed to send notification: \(error, privacy: .public)")
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

extension SessionManager {
    /// A pre-PID session file was keyed by a bare session UUID. Today's files are either
    /// numeric (PID) or `codex-<uuid>`, so only genuinely old files match.
    nonisolated static func isLegacyUUIDFilename(_ stem: String) -> Bool {
        HostApp.isUUID(stem)
    }

    nonisolated static func desktopAppRunning(
        for session: Session,
        lookup: DesktopAppConnectionLookup
    ) -> Bool? {
        guard session.hostClass == .desktop,
              let bundleID = session.terminal?.bundleId else {
            return nil
        }
        return lookup.isRunning(bundleID)
    }
}

extension SessionManager {
    nonisolated static func autoHiddenSessionSnapshot(path: String) throws -> Session? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        var latest = try Session.fromFile(path: path)
        guard !latest.hidden, latest.shouldAutoHide else { return nil }
        latest.hidden = true
        return latest
    }
}
