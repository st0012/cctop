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
    @Published var codexHookStatus: CodexHookStatus = .notInstalled
    @Published var codexLegacyConfigKey: Bool = false

    static let ccInstallCommand =
        "claude plugin marketplace add st0012/cctop && claude plugin install cctop"

    private let homeDirectory: URL
    private let ocPluginPath: URL
    private let piPluginPath: URL
    private let ccPluginCacheDir: URL
    static let ccOrphanedMarker = ".orphaned_at"
    static let ccPluginManifestPath = ".claude-plugin/plugin.json"

    /// `homeDirectory` controls where Claude Code, opencode, and pi detection
    /// looks, so tests and previews can stage a directory (or point at a
    /// nonexistent one) instead of reading the developer's real home. Codex
    /// detection and install/remove still go through `CodexPluginInstaller`'s
    /// real-home paths and are NOT redirected by this seam. `refreshOnInit:
    /// false` yields an inert manager whose published flags all start false —
    /// preview and snapshot setups override exactly the flags they mean to show.
    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        refreshOnInit: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.ocPluginPath = homeDirectory.appendingPathComponent(
            ".config/opencode/plugins/cctop.js"
        )
        self.piPluginPath = homeDirectory.appendingPathComponent(
            ".pi/agent/extensions/cctop.ts"
        )
        self.ccPluginCacheDir = homeDirectory.appendingPathComponent(
            ".claude/plugins/cache/cctop/cctop"
        )
        if refreshOnInit {
            refresh()
        }
    }

    func refresh() {
        let fm = FileManager.default

        ccInstalled = Self.hasActiveClaudeCodePluginVersion(in: ccPluginCacheDir)

        let ocConfigDir = homeDirectory.appendingPathComponent(".config/opencode")
        ocConfigExists = fm.fileExists(atPath: ocConfigDir.path)
        ocInstalled = fm.fileExists(atPath: ocPluginPath.path)
        ocNeedsUpdate = ocInstalled && Self.installedPluginOutdated(at: ocPluginPath)

        let piConfigDir = homeDirectory.appendingPathComponent(".pi")
        piConfigExists = fm.fileExists(atPath: piConfigDir.path)
        piInstalled = fm.fileExists(atPath: piPluginPath.path)

        let codexDirExists = CodexPluginInstaller.codexConfigExists()
        let codexConfigText: String? = codexDirExists
            ? (try? String(contentsOf: CodexPluginInstaller.configTomlPath, encoding: .utf8))
            : nil
        let codexHookFilesInstalled = CodexPluginInstaller.hasInstalledHookFiles()
        // The legacy key feeds both the update flag and the cleanup hint —
        // compute it once per refresh.
        let codexLegacyKey = codexConfigText.map(CodexPluginInstaller.configTomlHasLegacyKey) ?? false
        let codexSnapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: codexDirExists,
            hookFilesInstalled: codexHookFilesInstalled,
            featureEnabled: codexConfigText.map(CodexPluginInstaller.isFeatureFlagEnabled) ?? true,
            needsUpdate: codexHookFilesInstalled && (Self.codexInstallStale() || codexLegacyKey),
            configText: codexConfigText,
            legacyConfigKey: codexLegacyKey,
            hooksJsonPath: CodexPluginInstaller.hooksJsonPath.path
        ))
        codexConfigExists = codexSnapshot.configExists
        codexNeedsUpdate = codexSnapshot.needsUpdate
        codexHookStatus = codexSnapshot.hookStatus
        codexInstalled = codexSnapshot.installed
        codexLegacyConfigKey = codexSnapshot.legacyConfigKey
    }

    /// Cache layout is `<marketplace>/<plugin>/<version>/`. Claude Code writes a `.orphaned_at`
    /// marker inside a version directory after uninstall instead of deleting the directory.
    nonisolated static func hasActiveClaudeCodePluginVersion(in baseDir: URL) -> Bool {
        let fm = FileManager.default
        guard let versions = try? fm.contentsOfDirectory(atPath: baseDir.path) else {
            return false
        }
        return versions.contains { version in
            let versionDir = baseDir.appendingPathComponent(version)
            let orphaned = versionDir.appendingPathComponent(ccOrphanedMarker)
            let manifest = versionDir.appendingPathComponent(ccPluginManifestPath)
            return !fm.fileExists(atPath: orphaned.path)
                && fm.fileExists(atPath: manifest.path)
        }
    }

    private static func installedPluginOutdated(at ocPluginPath: URL) -> Bool {
        guard let bundledData = loadBundledResource(name: "opencode-plugin", ext: "js"),
              let installedData = try? Data(contentsOf: ocPluginPath) else {
            return false
        }
        return bundledData != installedData
    }

    /// True when the bundled Codex shim or hook template differs from the installed
    /// cctop-owned install. The other "Update Available" trigger — a deprecated
    /// `codex_hooks` key — is supplied by the caller, which already computed it for
    /// the snapshot. The update action handles both in one click.
    private static func codexInstallStale() -> Bool {
        guard let shim = loadBundledResource(name: "codex-shim", ext: "sh"),
              let hooks = loadBundledResource(name: "codex-hooks", ext: "json") else {
            return false
        }
        return CodexPluginInstaller.needsUpdate(bundledShim: shim, hooksTemplate: hooks)
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

    /// Cleanup-only path for a deprecated `codex_hooks` key left behind
    /// without an install (e.g. hooks removed by an older cctop that didn't
    /// migrate). Install and remove already migrate as part of their work.
    func cleanUpCodexLegacyConfig() -> Bool {
        defer { refresh() }
        return CodexPluginInstaller.migrateLegacyConfigKey()
    }

    func installOpenCodePlugin() -> Bool {
        installBundledPlugin(
            resource: "opencode-plugin", ext: "js",
            destination: ocPluginPath, name: "opencode"
        )
    }

    func removeOpenCodePlugin() -> Bool {
        removeBundledPlugin(path: ocPluginPath, name: "opencode")
    }

    func installPiPlugin() -> Bool {
        installBundledPlugin(
            resource: "pi-plugin", ext: "ts",
            destination: piPluginPath, name: "pi"
        )
    }

    func removePiPlugin() -> Bool {
        removeBundledPlugin(path: piPluginPath, name: "pi")
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
