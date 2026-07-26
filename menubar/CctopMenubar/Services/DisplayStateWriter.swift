import AppKit
import Foundation
import os.log

private let displayStateLogger = Logger(
    subsystem: "com.st0012.CctopMenubar",
    category: "DisplayState"
)

/// The versioned projection cctop publishes for external display surfaces.
/// Consumers render these values verbatim; they do not inspect session files or
/// reproduce cctop's ordering, lifecycle, identity, or theme rules.
struct DisplayState: Encodable {
    struct ProcessIdentity {
        let pid: Int32
        let startTime: TimeInterval
    }

    struct Entry: Encodable, Equatable {
        let id: String
        let name: String
        let status: String
        let color: String
    }

    struct DedupeKey: Encodable {
        let version: Int
        let appRunning: Bool
        let appPID: Int32?
        let appStartTime: TimeInterval?
        let sessions: [Entry]
    }

    let version: Int
    let generatedAt: String
    let appRunning: Bool
    let appPID: Int32?
    let appStartTime: TimeInterval?
    let sessions: [Entry]

    var dedupeKey: DedupeKey {
        DedupeKey(
            version: version,
            appRunning: appRunning,
            appPID: appPID,
            appStartTime: appStartTime,
            sessions: sessions
        )
    }
}

/// Publishes cctop's resolved display model to ~/.cctop/display-state.json.
/// This file is the Stream Deck API boundary, not an intermediate session source.
final class DisplayStateWriter {
    static let schemaVersion = 1

    private var lastSnapshot: Data?

    func write(sessions: [Session], theme: AppTheme, appRunning: Bool, now: Date = Date()) {
        // An Xcode test host launches the app executable but is not a user-facing
        // cctop instance. It must not claim liveness or overwrite the user's surface.
        guard !Self.isXcodeTestHost else { return }
        let appPID = appRunning ? ProcessInfo.processInfo.processIdentifier : nil
        let appIdentity = appPID.flatMap { pid -> DisplayState.ProcessIdentity? in
            guard let startTime = Session.processStartTime(pid: UInt32(pid)) else { return nil }
            return DisplayState.ProcessIdentity(pid: pid, startTime: startTime)
        }
        let snapshot = Self.snapshot(
            sessions: sessions,
            theme: theme,
            appRunning: appRunning,
            appIdentity: appIdentity,
            now: now
        )
        guard let data = try? Self.encoder.encode(snapshot),
              let dedupeKey = try? Self.encoder.encode(snapshot.dedupeKey),
              dedupeKey != lastSnapshot else { return }

        do {
            let stateURL = Self.defaultStateURL
            try FileManager.default.createDirectory(
                at: stateURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: stateURL, options: .atomic)
            lastSnapshot = dedupeKey
        } catch {
            displayStateLogger.error(
                "Failed to publish Stream Deck display state: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    static func snapshot(
        sessions: [Session],
        theme: AppTheme,
        appRunning: Bool,
        appIdentity: DisplayState.ProcessIdentity?,
        now: Date
    ) -> DisplayState {
        let ordered = SessionDisplayPolicy.activeSessions(from: sessions, now: now)
        return DisplayState(
            version: schemaVersion,
            generatedAt: timestampFormatter.string(from: now),
            appRunning: appRunning,
            appPID: appRunning ? appIdentity?.pid : nil,
            appStartTime: appRunning ? appIdentity?.startTime : nil,
            sessions: ordered.map { session in
                DisplayState.Entry(
                    id: session.id,
                    name: session.displayName,
                    status: session.status.rawValue,
                    color: hexColor(for: session.status, theme: theme)
                )
            }
        )
    }

    /// Hardware keys always use the same dark status palette as cctop's other
    /// persistent surfaces, including the compacting badge color.
    static func hexColor(for status: SessionStatus, theme: AppTheme) -> String {
        let color: NSColor
        switch status {
        case .waitingPermission: color = theme.statusPermission.dark
        case .waitingInput, .needsAttention: color = theme.statusAttention.dark
        case .working: color = theme.statusWorking.dark
        case .compacting: color = theme.agentBadge.dark
        case .idle: color = theme.statusIdle.dark
        }
        let srgb = color.usingColorSpace(.sRGB) ?? color
        func component(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
        return String(
            format: "#%02X%02X%02X",
            component(srgb.redComponent),
            component(srgb.greenComponent),
            component(srgb.blueComponent)
        )
    }

    private static let defaultStateURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".cctop/display-state.json")

    private static let isXcodeTestHost = ProcessInfo.processInfo.environment[
        "XCTestConfigurationFilePath"
    ] != nil

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
