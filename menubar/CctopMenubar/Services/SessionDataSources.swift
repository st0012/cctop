import Foundation

/// The external inputs SessionManager consults while deriving session state: the sessions
/// directory, the Codex/Claude Desktop archive stores, desktop-app liveness, process liveness,
/// notification and manual-visibility preferences, and the clock. Production uses `.live()`; tests override
/// individual fields to run the full pipeline against temp directories, stub lookups, and a
/// deterministic clock. One state-deriving input remains outside this seam:
/// `adjustPermissionStatus` probes the live process tree (`proc_listchildpids`) directly.
struct SessionDataSources {
    var sessionsDir: URL
    var codexThreads: any CodexThreadStateProviding
    var claudeDesktopSessions: any ClaudeDesktopSessionStateProviding
    var desktopAppConnection: DesktopAppConnectionLookup
    var processAlive: (SessionData) -> Bool
    var notificationsEnabled: () -> Bool
    var notificationClient: SessionNotificationClient = .live
    var manualSessionVisibility: ManualSessionVisibilityStore = .live
    var now: () -> Date

    /// A function rather than a stored constant so `Config.sessionsDir()` is resolved
    /// when the caller constructs its sources. The live metadata stores resolve their
    /// own paths as needed, with short internal caches for repeated reads in one pass.
    static func live() -> SessionDataSources {
        SessionDataSources(
            sessionsDir: URL(fileURLWithPath: Config.sessionsDir()),
            codexThreads: CodexThreadArchiveLookup(),
            claudeDesktopSessions: ClaudeDesktopSessionArchiveLookup(),
            desktopAppConnection: .live,
            processAlive: { $0.isAlive },
            notificationsEnabled: { UserDefaults.standard.bool(forKey: "notificationsEnabled") },
            now: Date.init
        )
    }
}
