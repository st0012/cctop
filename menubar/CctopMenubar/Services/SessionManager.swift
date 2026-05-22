import AppKit
import Darwin.libproc
import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.st0012.CctopMenubar", category: "SessionManager")

@MainActor
class SessionManager: ObservableObject {
    @Published var sessions: [Session] = []

    let historyManager: HistoryManager

    private let sessionsDir: URL
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: DispatchWorkItem?
    private var livenessTimer: Timer?

    init(historyManager: HistoryManager) {
        self.historyManager = historyManager
        self.sessionsDir = URL(fileURLWithPath: Config.sessionsDir())
        loadSessions()
        startWatching()
        livenessTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.loadSessions()
            }
        }
    }

    func loadSessions() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else {
            logger.warning("loadSessions: could not read directory")
            sessions = []
            return
        }

        // Tolerate duplicate ids defensively — `sessions` is deduped below, but a transient
        // double-file must never trap here (uniqueKeysWithValues crashes on a dup key).
        let oldStatuses = Dictionary(sessions.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })

        let jsonFiles = files.filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
        let allDecoded = jsonFiles
            .compactMap { url -> (URL, Session)? in
                guard let data = try? Data(contentsOf: url) else {
                    logger.warning("loadSessions: could not read \(url.lastPathComponent, privacy: .public)")
                    return nil
                }
                do {
                    let session = try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
                    return (url, session)
                } catch {
                    logger.error("loadSessions: decode failed \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
                    return nil
                }
            }
        var alive: [(URL, Session)] = []
        var dead: [(URL, Session)] = []
        for entry in allDecoded {
            if entry.1.endedAt != nil || !entry.1.isAlive { dead.append(entry) } else { alive.append(entry) }
        }
        logger.info("loadSessions: \(jsonFiles.count) files, \(allDecoded.count) decoded, \(alive.count) alive, \(dead.count) dead")
        let newSessions = Self.dedupedByID(alive.map(\.1).map { adjustDisplayStatus($0) })

        // Side effects: run before the equality guard so they always execute.
        if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
            for session in newSessions {
                guard session.status.needsAttention,
                      let oldStatus = oldStatuses[session.id],
                      !oldStatus.needsAttention else { continue }
                sendNotification(for: session)
            }
        }
        // Only publish when data actually changed to avoid unnecessary SwiftUI re-renders.
        if newSessions != sessions {
            if newSessions.count != sessions.count {
                logger.info("loadSessions: session count changed \(self.sessions.count) -> \(newSessions.count)")
            }
            sessions = newSessions
        }

        archiveAndRemoveDeadSessions(dead)
        cleanupOldFormatFiles(jsonFiles)
    }

    private func archiveAndRemoveDeadSessions(_ dead: [(URL, Session)]) {
        for (url, session) in dead {
            let sid = session.sessionId
            let pid = session.pid.map(String.init) ?? "nil"

            // Desktop-app sessions are deliberately skipped from archiving — drop the
            // live file directly so it doesn't linger as a "dead" entry forever.
            if session.isHostedByDesktopApp {
                logger.info("dropping dead desktop-app session \(sid, privacy: .public) pid=\(pid, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
                continue
            }

            logger.info("archiving dead session \(sid, privacy: .public) pid=\(pid, privacy: .public)")
            let archived = historyManager.archiveSession(session)
            if archived {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.removeItem(at: url.appendingPathExtension("lock"))
            } else {
                logger.warning("skipping removal of \(sid, privacy: .public) — archive failed")
            }
        }
        historyManager.rebuildRecentProjects(
            excludingActive: Set(sessions.map(\.projectPath))
        )
    }

    /// A pre-PID session file was keyed by a bare session UUID. Today's files are either
    /// numeric (PID) or `codex-<uuid>` (one Codex conversation per file); neither is a bare
    /// UUID, so only genuinely old files match and get cleaned up.
    nonisolated static func isLegacyUUIDFilename(_ stem: String) -> Bool {
        HostApp.isUUID(stem)
    }

    // MIGRATION(v0.6.0): Remove after all users have migrated to PID-keyed sessions.
    /// Remove old-format UUID-keyed session files (pre-PID migration).
    /// PID-keyed filenames are purely numeric; UUID filenames contain letters/hyphens.
    private func cleanupOldFormatFiles(_ jsonFiles: [URL]) {
        for url in jsonFiles {
            let stem = url.deletingPathExtension().lastPathComponent
            if Self.isLegacyUUIDFilename(stem) {
                logger.info("removing old-format session file: \(stem, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Distinct sessions can transiently share an `id`: Codex multiplexes conversations
    /// onto one host PID, and a migration window can briefly leave two files for the same
    /// conversation. Collapse by `id` (keeping the most recently active) so the published
    /// list — and everything keyed by id (SwiftUI identity, the status map) — stays unique.
    nonisolated static func dedupedByID(_ sessions: [Session]) -> [Session] {
        var byID: [String: Session] = [:]
        for session in sessions {
            if let existing = byID[session.id], existing.lastActivity >= session.lastActivity {
                continue
            }
            byID[session.id] = session
        }
        return byID.values.sorted { $0.id < $1.id }
    }

    /// Apply display-side status adjustments. The session file on disk is NOT modified.
    private func adjustDisplayStatus(_ session: Session) -> Session {
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
                            logger.error("Notification permission error: \(error, privacy: .public)")
                        }
                        logger.info("Notification permission granted: \(granted, privacy: .public)")
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
                        logger.error("Notification permission error: \(error, privacy: .public)")
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
                logger.error("Failed to send notification: \(error, privacy: .public)")
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
    }
}
