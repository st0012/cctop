import AppKit
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
    @Published var sdConfigExists: Bool = false
    @Published var sdInstalled: Bool = false
    @Published var sdNeedsUpdate: Bool = false

    static let ccInstallCommand =
        "claude plugin marketplace add st0012/cctop && claude plugin install cctop"

    private let homeDirectory: URL
    private let ocPluginPath: URL
    private let piPluginPath: URL
    private let ccPluginCacheDir: URL
    private let sdAppSupportDir: URL
    private var streamDeckRestartTask: Task<Void, Never>?
    nonisolated static let ccOrphanedMarker = ".orphaned_at"
    nonisolated static let ccPluginManifestPath = ".claude-plugin/plugin.json"
    static let sdPluginDirName = "com.st0012.cctop.sdPlugin"
    static let sdAppBundleID = "com.elgato.StreamDeck"

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
        self.sdAppSupportDir = homeDirectory.appendingPathComponent(
            "Library/Application Support/com.elgato.StreamDeck"
        )
        if refreshOnInit {
            refresh()
        }
    }

    private var sdPluginDestination: URL {
        sdAppSupportDir.appendingPathComponent("Plugins/\(Self.sdPluginDirName)")
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

        sdConfigExists = fm.fileExists(atPath: sdAppSupportDir.path)
        let installedManifest = sdPluginDestination.appendingPathComponent("manifest.json")
        sdInstalled = fm.fileExists(atPath: installedManifest.path)
        sdNeedsUpdate = sdInstalled && Self.streamDeckInstallOutdated(
            bundledDirectory: Self.bundledStreamDeckPluginDirectory,
            installedDirectory: sdPluginDestination
        )

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
}

// MARK: - Stream Deck

extension PluginManager {
    func installStreamDeckPlugin() -> Bool {
        defer { refresh() }
        guard let bundled = Self.bundledStreamDeckPluginDirectory else {
            logger.error("Missing bundled Stream Deck plugin")
            return false
        }
        do {
            try Self.replaceDirectory(at: sdPluginDestination, with: bundled)
            logger.info("Installed cctop Stream Deck plugin")
            restartStreamDeckIfRunning()
            return true
        } catch {
            logger.error("Failed to install Stream Deck plugin: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    func removeStreamDeckPlugin() -> Bool {
        defer { refresh() }
        do {
            try FileManager.default.removeItem(at: sdPluginDestination)
            logger.info("Removed cctop Stream Deck plugin; user profiles were left unchanged")
            restartStreamDeckIfRunning()
            return true
        } catch {
            logger.error("Failed to remove Stream Deck plugin: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Opens the bundled profile with Stream Deck's importer. cctop never reads
    /// or writes Stream Deck's profile database, so unrelated actions and profiles
    /// remain entirely under Stream Deck's control.
    func importStreamDeckProfile() -> Bool {
        guard let profile = Self.bundledStreamDeckPluginDirectory?
            .appendingPathComponent("profiles/cctop.streamDeckProfile"),
              FileManager.default.fileExists(atPath: profile.path) else {
            logger.error("Missing bundled Stream Deck profile")
            return false
        }
        return NSWorkspace.shared.open(profile)
    }

    nonisolated static var bundledStreamDeckPluginDirectory: URL? {
        Bundle.main.url(forResource: "com.st0012.cctop", withExtension: "sdPlugin")
    }

    nonisolated static func streamDeckInstallOutdated(
        bundledDirectory: URL?,
        installedDirectory: URL
    ) -> Bool {
        guard let bundledDirectory else { return false }
        let fileManager = FileManager.default
        guard let files = fileManager.enumerator(
            at: bundledDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return true
        }

        let bundledRoot = bundledDirectory.standardizedFileURL.path
        var foundManifest = false
        for case let bundledFile as URL in files {
            guard (try? bundledFile.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            let bundledPath = bundledFile.standardizedFileURL.path
            guard bundledPath.hasPrefix("\(bundledRoot)/") else { return true }
            let relativePath = String(bundledPath.dropFirst(bundledRoot.count + 1))
            if relativePath == "manifest.json" { foundManifest = true }
            let installedFile = installedDirectory.appendingPathComponent(relativePath)
            guard let bundledData = try? Data(contentsOf: bundledFile),
                  let installedData = try? Data(contentsOf: installedFile),
                  bundledData == installedData else {
                return true
            }
        }
        return !foundManifest
    }

    /// Stage the complete plugin before changing the installed copy. If the
    /// final move fails, restore the prior installation from its sibling backup.
    nonisolated static func replaceDirectory(at destination: URL, with source: URL) throws {
        let fileManager = FileManager.default
        let parent = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let token = UUID().uuidString
        let staging = parent.appendingPathComponent(".\(destination.lastPathComponent).staging-\(token)")
        let backup = parent.appendingPathComponent(".\(destination.lastPathComponent).backup-\(token)")

        do {
            try fileManager.copyItem(at: source, to: staging)
            let hadExistingInstall = fileManager.fileExists(atPath: destination.path)
            if hadExistingInstall {
                try fileManager.moveItem(at: destination, to: backup)
            }
            do {
                try fileManager.moveItem(at: staging, to: destination)
                if hadExistingInstall { try? fileManager.removeItem(at: backup) }
            } catch {
                if hadExistingInstall, !fileManager.fileExists(atPath: destination.path) {
                    try? fileManager.moveItem(at: backup, to: destination)
                }
                throw error
            }
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private func restartStreamDeckIfRunning() {
        guard let app = NSRunningApplication
            .runningApplications(withBundleIdentifier: Self.sdAppBundleID).first,
              let bundleURL = app.bundleURL else { return }

        streamDeckRestartTask?.cancel()
        app.terminate()
        streamDeckRestartTask = Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                let stillRunning = !NSRunningApplication
                    .runningApplications(withBundleIdentifier: Self.sdAppBundleID).isEmpty
                if !stillRunning {
                    do {
                        _ = try await NSWorkspace.shared.openApplication(
                            at: bundleURL,
                            configuration: NSWorkspace.OpenConfiguration()
                        )
                    } catch {
                        logger.error(
                            "Failed to restart Stream Deck: \(error.localizedDescription, privacy: .public)"
                        )
                    }
                    return
                }
            }
            logger.error("Timed out waiting to restart Stream Deck")
        }
    }
}

// MARK: - Shared plugin file operations

extension PluginManager {
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
