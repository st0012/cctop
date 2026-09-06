import Foundation

// MARK: - Shared date formatting

extension Date {
    func relativeDescription(asOf now: Date = Date()) -> String {
        let seconds = Int(now.timeIntervalSince(self))
        if seconds <= 0 { return "just now" }
        if seconds >= 86400 { return "\(seconds / 86400)d ago" }
        if seconds >= 3600 { return "\(seconds / 3600)h ago" }
        if seconds >= 60 { return "\(seconds / 60)m ago" }
        return "\(seconds)s ago"
    }

    var relativeDescription: String {
        relativeDescription()
    }
}

extension JSONEncoder {
    static let sessionEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }()
}

extension JSONDecoder {
    static let sessionDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let withoutFractional = ISO8601DateFormatter()
        withoutFractional.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = withFractional.date(from: string) { return date }
            if let date = withoutFractional.date(from: string) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(string)")
        }
        return decoder
    }()
}

/// Bundle identifiers of the desktop apps that host coding sessions in-app.
/// Single source of truth for both targets: the hook trusts these IDs when
/// classifying desktop-hosted sessions, and the app maps them to `HostApp` cases.
enum HostAppBundleID {
    static let claudeDesktop = "com.anthropic.claudefordesktop"
    static let codexDesktop = "com.openai.codex"
}

struct SubagentInfo: Codable, Equatable {
    let agentId: String
    let agentType: String
    let startedAt: Date

    enum CodingKeys: String, CodingKey {
        case agentId = "agent_id"
        case agentType = "agent_type"
        case startedAt = "started_at"
    }
}

/// Display-only lifecycle of a session, derived on each load and never persisted (a new
/// persisted `SessionStatus` would decode to `.working` on older app builds). Orthogonal to
/// `SessionStatus`: a dormant card keeps its last-known status for context but is excluded
/// from attention counts and notifications. The raw value is the dedup preference rank
/// (lower = preferred): active beats dormant beats finished.
enum SessionLifecycle: Int, Equatable {
    case active = 0    // backing process alive, or recent Codex hook activity
    case dormant = 1   // process gone, but the conversation is recent and may resume
    case finished = 2  // ended or aged out → eligible for GC
}

/// A cctop-owned user-session ID. The selected winner's value forms the current identity.
/// Multiple `SessionRecord` values can carry the same ID before the app forms that group.
enum CctopSessionID {
    static func make() -> String {
        UUID().uuidString.lowercased()
    }

    static func isValid(_ value: String?) -> Bool {
        guard let value, let uuid = UUID(uuidString: value) else { return false }
        return uuid.uuidString.lowercased() == value
    }
}

/// The Codable model for session data decoded from one hook-owned JSON file.
/// `lifecycle` is a derived display overlay and is never written to that JSON file.
struct SessionData: Codable, Identifiable, Equatable {
    var sessionId: String
    /// Serialized cctop-owned ID used to form one `UserSession`. It is deliberately
    /// independent of harness references and live focus-target metadata. Nil only on legacy
    /// records that have not yet been migrated by the app or touched by a current hook.
    var cctopSessionId: String?
    /// The exact unsanitized session reference supplied to the hook, byte-for-byte.
    /// This is lookup evidence for supported resume mappings, never cctop identity.
    /// Nil on records written by hooks that predate the field.
    var harnessSessionId: String?
    let projectPath: String
    let projectName: String
    var branch: String
    var status: SessionStatus
    var lastPrompt: String?
    var lastActivity: Date
    var startedAt: Date
    var terminal: TerminalInfo?
    var pid: UInt32?
    var pidStartTime: TimeInterval?
    var lastTool: String?
    var lastToolDetail: String?
    var notificationMessage: String?
    var sessionName: String?
    var desktopProjectName: String?
    var workspaceFile: String?
    var source: String?
    var endedAt: Date?
    var disconnectedAt: Date?
    var activeSubagents: [SubagentInfo]?
    var isSubagentSession: Bool
    var hidden: Bool
    var createdByHookVersion: String?
    var lastWrittenByHookVersion: String?

    /// Display-only lifecycle, derived on each load. Deliberately NOT in `CodingKeys`, so the
    /// synthesized `Codable` skips it and decode defaults it to `.active` (never persisted —
    /// a persisted lifecycle would decode to `.working` on older builds via SessionStatus).
    /// It IS a stored property, so it joins synthesized `Equatable` — a dormant flip changes
    /// equality and re-renders.
    var lifecycle: SessionLifecycle = .active

    /// Harness id Codex reports (CLI and Desktop both pass `--harness codex`).
    static let codexSource = "codex"
    static let ccSource = "cc"
    static let opencodeSource = "opencode"
    static let piSource = "pi"

    var isCodex: Bool { source == Self.codexSource }

    /// Whether persisted desktop bundle metadata can identify the host.
    /// Only Claude Desktop and nil-source legacy records trust this metadata.
    static func trustsDesktopBundle(source: String?, bundleId: String?) -> Bool {
        switch source {
        case nil:
            return bundleId == HostAppBundleID.claudeDesktop || bundleId == HostAppBundleID.codexDesktop
        case Self.ccSource?:
            return bundleId == HostAppBundleID.claudeDesktop
        default:
            return false
        }
    }

    // Codex multiplexes many conversations onto one host process, so the PID is not unique
    // per conversation — identify Codex sessions by session_id (matching their codex-<id>
    // file key). Every other source runs one session per PID.
    var id: String {
        if isCodex { return sessionId }
        return pid.map { String($0) } ?? sessionId
    }

    var displayName: String {
        sessionName ?? projectName
    }

    var subagentCount: Int {
        activeSubagents?.count ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cctopSessionId = "cctop_session_id"
        case harnessSessionId = "harness_session_id"
        case projectPath = "project_path"
        case projectName = "project_name"
        case branch, status
        case lastPrompt = "last_prompt"
        case lastActivity = "last_activity"
        case startedAt = "started_at"
        case terminal, pid
        case pidStartTime = "pid_start_time"
        case lastTool = "last_tool"
        case lastToolDetail = "last_tool_detail"
        case notificationMessage = "notification_message"
        case sessionName = "session_name"
        case desktopProjectName = "desktop_project_name"
        case workspaceFile = "workspace_file"
        case source
        case endedAt = "ended_at"
        case disconnectedAt = "disconnected_at"
        case activeSubagents = "active_subagents"
        case isSubagentSession = "is_subagent"
        case hidden
        case createdByHookVersion = "created_by_hook_version"
        case lastWrittenByHookVersion = "last_written_by_hook_version"
    }

    // MARK: - Constructors

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        cctopSessionId = try container.decodeIfPresent(String.self, forKey: .cctopSessionId)
        harnessSessionId = try container.decodeIfPresent(String.self, forKey: .harnessSessionId)
        projectPath = try container.decode(String.self, forKey: .projectPath)
        projectName = try container.decode(String.self, forKey: .projectName)
        branch = try container.decode(String.self, forKey: .branch)
        status = try container.decode(SessionStatus.self, forKey: .status)
        lastPrompt = try container.decodeIfPresent(String.self, forKey: .lastPrompt)
        lastActivity = try container.decode(Date.self, forKey: .lastActivity)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        terminal = try container.decodeIfPresent(TerminalInfo.self, forKey: .terminal)
        pid = try container.decodeIfPresent(UInt32.self, forKey: .pid)
        pidStartTime = try container.decodeIfPresent(TimeInterval.self, forKey: .pidStartTime)
        lastTool = try container.decodeIfPresent(String.self, forKey: .lastTool)
        lastToolDetail = try container.decodeIfPresent(String.self, forKey: .lastToolDetail)
        notificationMessage = try container.decodeIfPresent(String.self, forKey: .notificationMessage)
        sessionName = try container.decodeIfPresent(String.self, forKey: .sessionName)
        desktopProjectName = try container.decodeIfPresent(String.self, forKey: .desktopProjectName)
        workspaceFile = try container.decodeIfPresent(String.self, forKey: .workspaceFile)
        source = try container.decodeIfPresent(String.self, forKey: .source)
        endedAt = try container.decodeIfPresent(Date.self, forKey: .endedAt)
        disconnectedAt = try container.decodeIfPresent(Date.self, forKey: .disconnectedAt)
        activeSubagents = try container.decodeIfPresent([SubagentInfo].self, forKey: .activeSubagents)
        isSubagentSession = try container.decodeIfPresent(Bool.self, forKey: .isSubagentSession) ?? false
        hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
        createdByHookVersion = try container.decodeIfPresent(String.self, forKey: .createdByHookVersion)
        lastWrittenByHookVersion = try container.decodeIfPresent(String.self, forKey: .lastWrittenByHookVersion)
    }

    /// Full memberwise init (used by mocks and tests).
    init(
        sessionId: String,
        cctopSessionId: String? = nil,
        harnessSessionId: String? = nil,
        projectPath: String,
        projectName: String,
        branch: String,
        status: SessionStatus,
        lastPrompt: String?,
        lastActivity: Date,
        startedAt: Date,
        terminal: TerminalInfo?,
        pid: UInt32?,
        pidStartTime: TimeInterval? = nil,
        lastTool: String?,
        lastToolDetail: String?,
        notificationMessage: String?,
        sessionName: String? = nil,
        desktopProjectName: String? = nil,
        workspaceFile: String? = nil,
        source: String? = nil,
        endedAt: Date? = nil,
        disconnectedAt: Date? = nil,
        activeSubagents: [SubagentInfo]? = nil,
        isSubagentSession: Bool = false,
        hidden: Bool = false,
        createdByHookVersion: String? = nil,
        lastWrittenByHookVersion: String? = nil
    ) {
        self.sessionId = sessionId
        self.cctopSessionId = cctopSessionId
        self.harnessSessionId = harnessSessionId
        self.projectPath = projectPath
        self.projectName = projectName
        self.branch = branch
        self.status = status
        self.lastPrompt = lastPrompt
        self.lastActivity = lastActivity
        self.startedAt = startedAt
        self.terminal = terminal
        self.pid = pid
        self.pidStartTime = pidStartTime
        self.lastTool = lastTool
        self.lastToolDetail = lastToolDetail
        self.notificationMessage = notificationMessage
        self.sessionName = sessionName
        self.desktopProjectName = desktopProjectName
        self.workspaceFile = workspaceFile
        self.source = source
        self.endedAt = endedAt
        self.disconnectedAt = disconnectedAt
        self.activeSubagents = activeSubagents
        self.isSubagentSession = isSubagentSession
        self.hidden = hidden
        self.createdByHookVersion = createdByHookVersion
        self.lastWrittenByHookVersion = lastWrittenByHookVersion
    }

    /// Convenience init for creating new sessions (used by cctop-hook).
    /// Delegates to the memberwise init so fields added to `SessionData` later pick up
    /// their memberwise defaults here instead of needing a second hand-synced list.
    init(sessionId: String, projectPath: String, branch: String, terminal: TerminalInfo) {
        self.init(
            sessionId: sessionId,
            cctopSessionId: CctopSessionID.make(),
            projectPath: projectPath,
            projectName: Self.extractProjectName(projectPath),
            branch: branch,
            status: .idle,
            lastPrompt: nil,
            lastActivity: Date(),
            startedAt: Date(),
            terminal: terminal,
            pid: nil,
            lastTool: nil,
            lastToolDetail: nil,
            notificationMessage: nil
        )
    }

    mutating func markWrittenByHook(version: String, isNewSessionFile: Bool) {
        if isNewSessionFile { createdByHookVersion = version }
        lastWrittenByHookVersion = version
    }

    // MARK: - File I/O

    static func fromFile(path: String) throws -> SessionData {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder.sessionDecoder.decode(SessionData.self, from: data)
    }

    func writeToFile(path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let data = try JSONEncoder.sessionEncoder.encode(self)
        // Use hook process PID for unique temp file — prevents race when concurrent hooks write simultaneously
        let tempPath = path + ".\(ProcessInfo.processInfo.processIdentifier).tmp"
        let tempURL = URL(fileURLWithPath: tempPath)
        try data.write(to: tempURL)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tempPath)

        // Atomic replace: rename(2) overwrites existing files on POSIX.
        // No fallback — rename in the same directory always succeeds on macOS/APFS.
        // A remove+move fallback risks deleting the session file if the .tmp is already gone.
        guard rename(tempPath, path) == 0 else {
            let err = errno
            try? fm.removeItem(atPath: tempPath)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(err),
                          userInfo: [NSLocalizedDescriptionKey: "rename(\(tempPath), \(path)) failed: \(err)"])
        }
    }

    // MARK: - Utilities

    static func sanitizeSessionId(raw: String) -> String {
        let filtered = String(raw.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        })
        return String(filtered.prefix(64))
    }

    /// Returns a copy with a new session_id (and optionally updated branch/terminal).
    /// Used when the same OS process gets a new CC session_id on resume.
    /// Copy-mutation preserves every other field by construction, so fields added
    /// to `SessionData` later can never be silently dropped on session-id rotation.
    func withSessionId(_ newId: String, branch: String? = nil, terminal: TerminalInfo? = nil) -> SessionData {
        var copy = self
        copy.sessionId = newId
        if let branch { copy.branch = branch }
        if let terminal { copy.terminal = terminal }
        return copy
    }

    /// Look for a `.code-workspace` file in the given directory.
    /// If exactly one exists, return it. If multiple exist, prefer one matching the project name.
    static func findWorkspaceFile(in projectPath: String) -> String? {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: projectPath) else {
            return nil
        }

        let workspaceFiles = entries.filter { $0.hasSuffix(".code-workspace") }
        if workspaceFiles.isEmpty { return nil }

        func fullPath(_ name: String) -> String {
            (projectPath as NSString).appendingPathComponent(name)
        }

        if workspaceFiles.count == 1 { return fullPath(workspaceFiles[0]) }

        // Multiple workspace files: prefer one matching the project folder name
        let projectName = URL(fileURLWithPath: projectPath).lastPathComponent
        if let match = workspaceFiles.first(where: {
            ($0 as NSString).deletingPathExtension == projectName
        }) {
            return fullPath(match)
        }
        return nil
    }

    static func extractProjectName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

extension SessionData {
    /// The best available inactive timestamp for ordering retained files.
    var effectiveEndDate: Date {
        disconnectedAt ?? endedAt ?? lastActivity
    }

    var relativeTime: String {
        lastActivity.relativeDescription
    }

    var contextLine: String? {
        switch status {
        case .idle: return nil
        case .compacting: return "Compacting context..."
        case .waitingPermission:
            return notificationMessage ?? "Permission needed"
        case .waitingInput:
            return notificationMessage ?? promptSnippet
        case .needsAttention:
            return notificationMessage ?? promptSnippet ?? "Needs attention"
        case .working:
            if let tool = lastTool {
                return formatToolDisplay(tool: tool, detail: lastToolDetail)
            }
            return promptSnippet
        }
    }

    private var promptSnippet: String? {
        lastPrompt.map { "\"\(String($0.prefix(36)))\"" }
    }

    private func formatToolDisplay(tool: String, detail: String?) -> String {
        guard let detail else { return "\(tool)..." }
        let fileName = URL(fileURLWithPath: detail).lastPathComponent
        switch tool.lowercased() {
        // "local_shell" is Codex's equivalent of Claude Code's Bash tool —
        // route both through the same "Running: ..." formatting so Codex
        // sessions don't show a raw "local_shell: ..." in the meta row.
        case "bash", "local_shell": return "Running: \(detail.prefix(30))"
        case "edit": return "Editing \(fileName)"
        case "write": return "Writing \(fileName)"
        case "read": return "Reading \(fileName)"
        case "grep": return "Searching: \(detail.prefix(30))"
        case "glob": return "Finding: \(detail.prefix(30))"
        case "webfetch": return "Fetching: \(detail.prefix(30))"
        case "websearch": return "Searching: \(detail.prefix(30))"
        case "task": return "Task: \(detail.prefix(30))"
        case "agent": return "Spawning: \(detail.prefix(30))"
        default: return "\(tool): \(detail.prefix(30))"
        }
    }
}
