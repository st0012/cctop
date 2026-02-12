import Foundation

struct EditorConfig: Codable {
    var processName: String
    var cliCommand: String

    enum CodingKeys: String, CodingKey {
        case processName = "process_name"
        case cliCommand = "cli_command"
    }

    init(processName: String = "Code", cliCommand: String = "code") {
        self.processName = processName
        self.cliCommand = cliCommand
    }
}

struct Config: Codable {
    var editor: EditorConfig

    init(editor: EditorConfig = EditorConfig()) {
        self.editor = editor
    }

    static func load() -> Config {
        guard let home = FileManager.default.homeDirectoryForCurrentUser.path
            .nilIfEmpty else { return Config() }

        let configPath = (home as NSString).appendingPathComponent(".cctop/config.json")
        guard FileManager.default.fileExists(atPath: configPath),
              let data = try? Data(contentsOf: URL(fileURLWithPath: configPath)),
              let config = try? JSONDecoder().decode(Config.self, from: data) else {
            return Config()
        }
        return config
    }

    static func sessionsDir() -> String {
        if let override = ProcessInfo.processInfo.environment["CCTOP_SESSIONS_DIR"],
           !override.isEmpty {
            ensureDirectoryExists(override)
            return override
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = (home as NSString).appendingPathComponent(".cctop/sessions")
        ensureDirectoryExists(dir)
        return dir
    }

    private static func ensureDirectoryExists(_ path: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
