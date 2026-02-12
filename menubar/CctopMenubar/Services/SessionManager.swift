import Foundation
import UserNotifications
import os.log

private let logger = Logger(subsystem: "com.st0012.CctopMenubar", category: "SessionManager")

@MainActor
class SessionManager: ObservableObject {
    @Published var sessions: [Session] = []

    private let sessionsDir: URL
    private var source: DispatchSourceFileSystemObject?
    private var debounceTask: DispatchWorkItem?
    private var livenessTimer: Timer?

    init() {
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

        let oldStatuses = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.status) })

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
        let alive = allDecoded.filter { $0.1.isAlive }
        let dead = allDecoded.filter { !$0.1.isAlive }
        logger.info("loadSessions: \(jsonFiles.count) files, \(allDecoded.count) decoded, \(alive.count) alive, \(dead.count) dead")
        let oldCount = sessions.count
        sessions = alive.map(\.1)
        if sessions.count != oldCount {
            logger.info("loadSessions: session count changed \(oldCount) -> \(self.sessions.count)")
        }

        if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
            for session in sessions {
                guard session.status.needsAttention,
                      let oldStatus = oldStatuses[session.id],
                      !oldStatus.needsAttention else { continue }
                sendNotification(for: session)
            }
        }
        for (url, session) in dead {
            let sid = session.sessionId
            let pid = session.pid.map(String.init) ?? "nil"
            logger.error("removing dead session \(sid, privacy: .public) pid=\(pid, privacy: .public)")
            try? FileManager.default.removeItem(at: url)
        }

        cleanupOldFormatFiles(jsonFiles)
    }

    /// Remove old-format UUID-keyed session files (pre-PID migration).
    /// PID-keyed filenames are purely numeric; UUID filenames contain letters/hyphens.
    private func cleanupOldFormatFiles(_ jsonFiles: [URL]) {
        for url in jsonFiles {
            let stem = url.deletingPathExtension().lastPathComponent
            if stem.rangeOfCharacter(from: CharacterSet.decimalDigits.inverted) != nil {
                logger.info("removing old-format session file: \(stem, privacy: .public)")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func resetSession(_ session: Session) {
        guard let pid = session.pid else { return }
        let url = sessionsDir.appendingPathComponent("\(pid).json")
        guard let data = try? Data(contentsOf: url),
              var mutable = try? JSONDecoder.sessionDecoder.decode(Session.self, from: data)
        else { return }
        mutable.status = .idle
        mutable.lastTool = nil
        mutable.lastToolDetail = nil
        mutable.notificationMessage = nil
        mutable.lastActivity = Date()
        guard let encoded = try? JSONEncoder.sessionEncoder.encode(mutable) else { return }
        try? encoded.write(to: url, options: .atomic)
        loadSessions()
    }

    static func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                logger.error("Notification permission error: \(error, privacy: .public)")
            }
            logger.info("Notification permission granted: \(granted, privacy: .public)")
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
