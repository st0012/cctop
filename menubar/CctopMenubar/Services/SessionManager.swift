import Foundation

@MainActor
class SessionManager: ObservableObject {
    @Published var sessions: [Session] = []

    private let sessionsDir: URL
    private var source: DispatchSourceFileSystemObject?

    init() {
        self.sessionsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cctop/sessions")
        loadSessions()
        startWatching()
    }

    func loadSessions() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else {
            sessions = []
            return
        }

        let allDecoded = files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
            .compactMap { url -> (URL, Session)? in
                guard let data = try? Data(contentsOf: url),
                      let session = try? JSONDecoder.sessionDecoder.decode(Session.self, from: data)
                else { return nil }
                return (url, session)
            }
        sessions = allDecoded.filter { $0.1.isAlive }.map(\.1)
        for (url, session) in allDecoded where !session.isAlive {
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
            Task { @MainActor in
                self?.loadSessions()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    deinit {
        source?.cancel()
    }
}
