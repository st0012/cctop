import Foundation

struct TerminalInfo: Codable, Equatable {
    let program: String
    let sessionId: String?
    let tty: String?
    let bundleId: String?
    let socket: String? // Remote-control socket (e.g. KITTY_LISTEN_ON)
    let focusUrl: String? // Session deep link for pane focusing (e.g. WARP_FOCUS_URL)
    let multiplexer: MultiplexerInfo?
    let binaryPaths: [String: String]?

    enum CodingKeys: String, CodingKey {
        case program
        case sessionId = "session_id"
        case tty
        case bundleId = "bundle_id"
        case socket
        case focusUrl = "focus_url"
        case multiplexer
        case binaryPaths = "binary_paths"
    }

    init(program: String = "", sessionId: String? = nil, tty: String? = nil,
         bundleId: String? = nil, socket: String? = nil, focusUrl: String? = nil,
         multiplexer: MultiplexerInfo? = nil,
         binaryPaths: [String: String]? = nil) {
        self.program = program
        self.sessionId = sessionId
        self.tty = tty
        self.bundleId = bundleId
        self.socket = socket
        self.focusUrl = focusUrl
        self.multiplexer = multiplexer
        self.binaryPaths = binaryPaths
    }
}

/// Warp session deep link (`<channel-scheme>://session/<32 hex>`), exposed to shells
/// as `WARP_FOCUS_URL` since Warp v0.2026.05.27 (warpdotdev/warp#11130). Opening it
/// makes Warp raise the window and focus the exact pane hosting that terminal
/// session. Launch Services routes the scheme to the channel app and activates it,
/// so the window still comes forward when Warp silently ignores a stale UUID.
///
/// Session JSON is user-writable, so both the hook (capture) and the app (focus)
/// validate against this exact shape — anything else is dropped rather than opened.
/// Each Warp release channel registers its own URL scheme and bundle ID
/// (warpdotdev/warp script/macos/bundle); this table is the single registry behind
/// both the scheme allowlist and `HostApp`'s Warp channel classification.
enum WarpFocusLink {
    private static let bundleIDsByScheme: [String: String] = [
        "warp": "dev.warp.Warp-Stable",
        "warppreview": "dev.warp.Warp-Preview",
        "warpdev": "dev.warp.Warp-Dev",
        "warposs": "dev.warp.WarpOss"
    ]

    static func isChannelScheme(_ scheme: String?) -> Bool {
        scheme.map { bundleIDsByScheme[$0] != nil } ?? false
    }

    static func isChannelBundleID(_ bundleID: String) -> Bool {
        bundleIDsByScheme.values.contains(bundleID)
    }

    /// The link as a URL when it has the exact expected shape and a known channel scheme.
    static func validatedURL(_ raw: String?) -> URL? {
        // `\z` anchors at true end-of-input, so a trailing line terminator can
        // never slip past the match regardless of ICU `$` semantics.
        guard let raw,
              raw.range(of: #"^[a-z]+://session/[0-9a-f]{32}\z"#, options: .regularExpression) != nil,
              let url = URL(string: raw),
              isChannelScheme(url.scheme)
        else { return nil }
        return url
    }

    /// Capture-side sanitizer: returns the value only when it is a valid focus link.
    static func sanitized(_ raw: String?) -> String? {
        validatedURL(raw) != nil ? raw : nil
    }
}

/// Identifies a terminal multiplexer (cmux, herdr, zellij, tmux) hosting the session.
/// Each variant carries exactly the fields needed for its focus command.
enum MultiplexerInfo: Codable, Equatable {
    /// cmux focus-surface --workspace $workspaceId --surface $surfaceId
    case cmux(socket: String, workspaceId: String, surfaceId: String?, paneId: String?, binaryPath: String?)
    /// herdr agent focus $paneId (with HERDR_SOCKET_PATH=$socket)
    case herdr(socket: String, paneId: String, binaryPath: String?)
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
        case "herdr":
            self = .herdr(
                socket: try container.decode(String.self, forKey: .socket),
                paneId: try container.decode(String.self, forKey: .paneId),
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
        case .herdr(let socket, let paneId, let binaryPath):
            try container.encode("herdr", forKey: .name)
            try container.encode(socket, forKey: .socket)
            try container.encode(paneId, forKey: .paneId)
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
