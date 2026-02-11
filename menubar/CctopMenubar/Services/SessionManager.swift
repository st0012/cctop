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
        self.sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cctop/sessions")
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

        let oldStatuses = Dictionary(uniqueKeysWithValues: sessions.map { ($0.sessionId, $0.status) })

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
        logger.info("loadSessions: \(jsonFiles.count, privacy: .public) files, \(allDecoded.count, privacy: .public) decoded, \(alive.count, privacy: .public) alive, \(dead.count, privacy: .public) dead")
        let oldCount = sessions.count
        sessions = alive.map(\.1)
        if sessions.count != oldCount {
            logger.info("loadSessions: session count changed \(oldCount) -> \(self.sessions.count)")
        }

        if UserDefaults.standard.bool(forKey: "notificationsEnabled") {
            for session in sessions {
                let oldStatus = oldStatuses[session.sessionId]
                if session.status.needsAttention && oldStatus != nil && !(oldStatus!.needsAttention) {
                    sendNotification(for: session)
                }
            }
        }
        for (url, session) in dead {
            logger.error("loadSessions: removing dead session \(session.sessionId, privacy: .public) project=\(session.projectName, privacy: .public) pid=\(session.pid.map(String.init) ?? "nil", privacy: .public)")
            try? FileManager.default.removeItem(at: url)
        }
    }

    func resetSession(_ session: Session) {
        let url = sessionsDir.appendingPathComponent("\(session.sessionId).json")
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
        let content = UNMutableNotificationContent()
        content.title = session.projectName
        switch session.status {
        case .waitingPermission:
            content.body = session.notificationMessage ?? "Permission needed"
        case .waitingInput:
            content.body = session.lastPrompt.map { "Waiting: \(String($0.prefix(80)))" } ?? "Waiting for input"
        default:
            content.body = "Needs attention"
        }
        content.sound = .default
        content.userInfo = ["sessionId": session.sessionId]

        let request = UNNotificationRequest(
            identifier: "session-\(session.sessionId)",
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
