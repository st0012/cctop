import Foundation
import os.log

private let logger = Logger(subsystem: "com.st0012.CctopMenubar", category: "PluginManager")

@MainActor
class PluginManager: ObservableObject {
    @Published var ccInstalled: Bool = false
    @Published var ocInstalled: Bool = false
    @Published var ocNeedsUpdate: Bool = false
    @Published var ocConfigExists: Bool = false
    @Published var piInstalled: Bool = false
    @Published var piConfigExists: Bool = false
    @Published var codexInstalled: Bool = false
    @Published var codexNeedsUpdate: Bool = false
    @Published var codexConfigExists: Bool = false
    @Published var codexFlagAlreadyEnabled: Bool = false

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let ocPluginPath = home.appendingPathComponent(
        ".config/opencode/plugins/cctop.js"
    )
    private static let piPluginPath = home.appendingPathComponent(
        ".pi/agent/extensions/cctop.ts"
    )

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let home = Self.home

        let ccDir = home.appendingPathComponent(".claude/plugins/cache/cctop")
        var isDir: ObjCBool = false
        ccInstalled = fm.fileExists(atPath: ccDir.path, isDirectory: &isDir)
            && isDir.boolValue

        let ocConfigDir = home.appendingPathComponent(".config/opencode")
        ocConfigExists = fm.fileExists(atPath: ocConfigDir.path)
        ocInstalled = fm.fileExists(atPath: Self.ocPluginPath.path)
        ocNeedsUpdate = ocInstalled && Self.installedPluginOutdated()

        let piConfigDir = home.appendingPathComponent(".pi")
        piConfigExists = fm.fileExists(atPath: piConfigDir.path)
        piInstalled = fm.fileExists(atPath: Self.piPluginPath.path)

        codexConfigExists = CodexPluginInstaller.codexConfigExists()
        codexInstalled = CodexPluginInstaller.isInstalled()

        let codexConfigText: String? = codexConfigExists
            ? (try? String(contentsOf: CodexPluginInstaller.configTomlPath, encoding: .utf8))
            : nil

        codexNeedsUpdate = codexInstalled
            && Self.codexInstallStale(configText: codexConfigText)
        codexFlagAlreadyEnabled = codexConfigText
            .map(CodexPluginInstaller.isFeatureFlagEnabled) ?? false
    }

    private static func installedPluginOutdated() -> Bool {
        guard let bundledData = loadBundledResource(name: "opencode-plugin", ext: "js"),
              let installedData = try? Data(contentsOf: ocPluginPath) else {
            return false
        }
        return bundledData != installedData
    }

    /// "Update Available" fires when either the bundled shim differs from the
    /// installed one OR the supplied config.toml content still contains the
    /// deprecated `[features].codex_hooks` key. The install action handles
    /// both: it rewrites the shim and migrates the TOML key in one click.
    /// Takes the config text as a parameter so callers can dedupe the disk
    /// read with their own (e.g. `refresh()` reads the file once for the
    /// `codexFlagAlreadyEnabled` check too).
    private static func codexInstallStale(configText: String?) -> Bool {
        if let data = loadBundledResource(name: "codex-shim", ext: "sh"),
           CodexPluginInstaller.needsUpdate(bundledShim: data) {
            return true
        }
        if let text = configText, CodexPluginInstaller.configTomlHasLegacyKey(text) {
            return true
        }
        return false
    }

    /// Read a bundled Resources file. Logs and returns nil if missing or unreadable.
    private static func loadBundledResource(name: String, ext: String) -> Data? {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
            logger.error("Missing bundled resource \(name, privacy: .public).\(ext, privacy: .public)")
            return nil
        }
        return try? Data(contentsOf: url)
    }

    func installCodexPlugin() -> Bool {
        defer { refresh() }
        guard let shim = Self.loadBundledResource(name: "codex-shim", ext: "sh"),
              let template = Self.loadBundledResource(name: "codex-hooks", ext: "json") else {
            return false
        }
        return CodexPluginInstaller.install(shimContents: shim, hooksTemplate: template)
    }

    func removeCodexPlugin() -> Bool {
        defer { refresh() }
        return CodexPluginInstaller.remove()
    }

    func installOpenCodePlugin() -> Bool {
        installBundledPlugin(
            resource: "opencode-plugin", ext: "js",
            destination: Self.ocPluginPath, name: "opencode"
        )
    }

    func removeOpenCodePlugin() -> Bool {
        removeBundledPlugin(path: Self.ocPluginPath, name: "opencode")
    }

    func installPiPlugin() -> Bool {
        installBundledPlugin(
            resource: "pi-plugin", ext: "ts",
            destination: Self.piPluginPath, name: "pi"
        )
    }

    func removePiPlugin() -> Bool {
        removeBundledPlugin(path: Self.piPluginPath, name: "pi")
    }

    // MARK: - Private

    private func installBundledPlugin(
        resource: String, ext: String, destination: URL, name: String
    ) -> Bool {
        defer { refresh() }
        guard let bundledData = Self.loadBundledResource(name: resource, ext: ext) else {
            return false
        }
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try bundledData.write(to: destination, options: .atomic)
            logger.info("Installed \(name) plugin to \(destination.path, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to install \(name) plugin: \(error, privacy: .public)")
            return false
        }
    }

    private func removeBundledPlugin(path: URL, name: String) -> Bool {
        defer { refresh() }

        do {
            try FileManager.default.removeItem(at: path)
            logger.info(
                "Removed \(name) plugin from \(path.path, privacy: .public)"
            )
            return true
        } catch {
            logger.error(
                "Failed to remove \(name) plugin: \(error, privacy: .public)"
            )
            return false
        }
    }
}
