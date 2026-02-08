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
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: sessionsDir,
            includingPropertiesForKeys: nil
        ) else {
            sessions = []
            return
        }

        sessions = files
            .filter { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".tmp") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url),
                      let session = try? decoder.decode(Session.self, from: data),
                      session.isAlive else { return nil }
                return session
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
            self?.loadSessions()
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }
}
