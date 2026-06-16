// swiftlint:disable file_length
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

struct TerminalInfo: Codable, Equatable {
    let program: String
    let sessionId: String?
    let tty: String?
    let bundleId: String?
    let socket: String? // Remote-control socket (e.g. KITTY_LISTEN_ON)
    let multiplexer: MultiplexerInfo?
    let binaryPaths: [String: String]?

    enum CodingKeys: String, CodingKey {
        case program
        case sessionId = "session_id"
        case tty
        case bundleId = "bundle_id"
        case socket
        case multiplexer
        case binaryPaths = "binary_paths"
    }

    init(program: String = "", sessionId: String? = nil, tty: String? = nil,
         bundleId: String? = nil, socket: String? = nil, multiplexer: MultiplexerInfo? = nil,
         binaryPaths: [String: String]? = nil) {
        self.program = program
        self.sessionId = sessionId
        self.tty = tty
        self.bundleId = bundleId
        self.socket = socket
        self.multiplexer = multiplexer
        self.binaryPaths = binaryPaths
    }
}

/// Identifies a terminal multiplexer (cmux, zellij, tmux) hosting the session.
/// Each variant carries exactly the fields needed for its focus command.
enum MultiplexerInfo: Codable, Equatable {
    /// cmux focus-surface --workspace $workspaceId --surface $surfaceId
    case cmux(socket: String, workspaceId: String, surfaceId: String?, paneId: String?, binaryPath: String?)
    /// zellij --session $sessionName action focus-pane-id $paneId
    case zellij(sessionName: String, paneId: String, binaryPath: String?)
    /// tmux -S $socket select-window -t $paneId && tmux -S $socket select-pane -t $paneId
    case tmux(socket: String, paneId: String, binaryPath: String?)

    private enum CodingKeys: String, CodingKey {
        case name
        case sessionName = "session_name"
        case workspaceId = "workspace_id"
        case surfaceId = "surface_id"
        case paneId = "pane_id"
        case socket
        case binaryPath = "binary_path"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)
        let binaryPath = try container.decodeIfPresent(String.self, forKey: .binaryPath)
        switch name {
        case "cmux":
            self = .cmux(
                socket: try container.decode(String.self, forKey: .socket),
                workspaceId: try container.decode(String.self, forKey: .workspaceId),
                surfaceId: try container.decodeIfPresent(String.self, forKey: .surfaceId),
                paneId: try container.decodeIfPresent(String.self, forKey: .paneId),
                binaryPath: binaryPath
            )
        case "zellij":
            self = .zellij(
                sessionName: try container.decode(String.self, forKey: .sessionName),
                paneId: try container.decode(String.self, forKey: .paneId),
                binaryPath: binaryPath
            )
        case "tmux":
            self = .tmux(
                socket: try container.decode(String.self, forKey: .socket),
                paneId: try container.decode(String.self, forKey: .paneId),
                binaryPath: binaryPath
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .name, in: container,
                debugDescription: "Unknown multiplexer: \(name)"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cmux(let socket, let workspaceId, let surfaceId, let paneId, let binaryPath):
            try container.encode("cmux", forKey: .name)
            try container.encode(socket, forKey: .socket)
            try container.encode(workspaceId, forKey: .workspaceId)
            try container.encodeIfPresent(surfaceId, forKey: .surfaceId)
            try container.encodeIfPresent(paneId, forKey: .paneId)
            try container.encodeIfPresent(binaryPath, forKey: .binaryPath)
        case .zellij(let sessionName, let paneId, let binaryPath):
            try container.encode("zellij", forKey: .name)
            try container.encode(sessionName, forKey: .sessionName)
            try container.encode(paneId, forKey: .paneId)
            try container.encodeIfPresent(binaryPath, forKey: .binaryPath)
        case .tmux(let socket, let paneId, let binaryPath):
            try container.encode("tmux", forKey: .name)
            try container.encode(socket, forKey: .socket)
            try container.encode(paneId, forKey: .paneId)
            try container.encodeIfPresent(binaryPath, forKey: .binaryPath)
        }
    }
}

extension MultiplexerInfo {
    var isCmux: Bool {
        if case .cmux = self { return true }
        return false
    }
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
    case active = 0    // backing process alive, or (Codex Desktop) recent hook activity
    case dormant = 1   // process gone, but the conversation is recent and may resume
    case finished = 2  // ended or aged out → eligible for GC
}

struct Session: Codable, Identifiable, Equatable {
    var sessionId: String
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

    /// Whether a desktop-app bundle id is believable for this harness. GUI launchers leak
    /// `__CFBundleIdentifier` into child tools, so a desktop bundle proves desktop hosting
    /// only when it is the harness's OWN desktop app: cc -> Claude Desktop,
    /// codex -> Codex Desktop. Explicit non-desktop harnesses (opencode, pi) trust none;
    /// nil-source legacy records keep the previous bundle-first behavior.
    static func trustsDesktopBundle(source: String?, bundleId: String?) -> Bool {
        switch source {
        case nil:
            return bundleId == HostAppBundleID.claudeDesktop || bundleId == HostAppBundleID.codexDesktop
        case Self.ccSource?:
            return bundleId == HostAppBundleID.claudeDesktop
        case Self.codexSource?:
            return bundleId == HostAppBundleID.codexDesktop
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
    /// Delegates to the memberwise init so fields added to `Session` later pick up
    /// their memberwise defaults here instead of needing a second hand-synced list.
    init(sessionId: String, projectPath: String, branch: String, terminal: TerminalInfo) {
        self.init(
            sessionId: sessionId,
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

    static func fromFile(path: String) throws -> Session {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try JSONDecoder.sessionDecoder.decode(Session.self, from: data)
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
    /// to `Session` later can never be silently dropped on session-id rotation.
    func withSessionId(_ newId: String, branch: String? = nil, terminal: TerminalInfo? = nil) -> Session {
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

    static func sorted(_ sessions: [Session]) -> [Session] {
        // Live (active) sessions first, then dormant; within each tier by status, then recency.
        sessions.sorted {
            ($0.lifecycle.rawValue, $0.status.sortOrder, $1.lastActivity)
                < ($1.lifecycle.rawValue, $1.status.sortOrder, $0.lastActivity)
        }
    }

    static func extractProjectName(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

extension Session {

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
        case .waitingInput, .needsAttention:
            return notificationMessage ?? promptSnippet
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

// MARK: - Process Liveness

extension Session {
    static func processInfo(pid: UInt32) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, Int32(pid)]
        let result = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        return info
    }

    static func processStartTime(pid: UInt32) -> TimeInterval? {
        guard let info = processInfo(pid: pid) else { return nil }
        return startTime(from: info)
    }

    var isAlive: Bool {
        guard let pid else { return false }
        guard kill(Int32(pid), 0) == 0 || errno == EPERM else { return false }
        guard let info = Self.processInfo(pid: pid) else { return false }

        if let stored = pidStartTime {
            let current = Self.startTime(from: info)
            if abs(stored - current) > 1.0 { return false }
        }

        // A live process that is identifiably a DIFFERENT harness's binary cannot be this
        // session's host: the capture-time parent walk can adopt a foreign harness PID, and
        // rapid PID reuse can land within the 1s start-time tolerance (issue #155).
        if Self.isForeignHarnessComm(Self.commandName(from: info), source: source) { return false }

        // Suspended (Ctrl+Z) or orphaned (PPID=1) processes are unreachable
        if info.kp_proc.p_stat == 4 { return false }
        if info.kp_eproc.e_ppid == 1 { return false }

        return true
    }

    private static func startTime(from info: kinfo_proc) -> TimeInterval {
        let tv = info.kp_proc.p_starttime
        return TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000
    }

    /// Kernel-reported executable basename (`p_comm`, truncated to MAXCOMLEN).
    /// p_comm stores MAXCOMLEN chars + NUL; the +1 keeps a full-length comm's
    /// terminator inside the rebound region.
    static func commandName(from info: kinfo_proc) -> String {
        var proc = info.kp_proc
        return withUnsafePointer(to: &proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { cStr in
                String(cString: cStr)
            }
        }
    }

    static func processCommandName(pid: UInt32) -> String? {
        processInfo(pid: pid).map { commandName(from: $0) }
    }

    /// Maps a process name to the harness that owns that binary. Codex also ships
    /// arch-suffixed binaries (`codex-aarch64-apple-darwin`, truncated by MAXCOMLEN),
    /// hence the prefix match.
    static func harnessOwningComm(_ comm: String) -> String? {
        if comm == "claude" { return ccSource }
        if comm == "codex" || comm.hasPrefix("codex-") { return codexSource }
        if comm == "opencode" { return opencodeSource }
        if comm == "pi" { return piSource }
        return nil
    }

    /// True when the process name belongs to a DIFFERENT harness than this session's.
    /// Conservative: an unrecognized name proves nothing (claude could run under a
    /// wrapper). Legacy nil sources are Claude Code sessions.
    static func isForeignHarnessComm(_ comm: String, source: String?) -> Bool {
        guard let owner = harnessOwningComm(comm) else { return false }
        return owner != (source ?? ccSource)
    }
}
