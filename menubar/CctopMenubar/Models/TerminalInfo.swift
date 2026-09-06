import Foundation

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
