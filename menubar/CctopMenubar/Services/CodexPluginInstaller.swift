import Foundation
import os.log

private let logger = Logger(subsystem: "com.st0012.CctopMenubar", category: "CodexPluginInstaller")

/// Installs, updates, and removes cctop's Codex CLI hook entries.
/// Installs a shim to `~/.codex/cctop-shim.sh`, merges 5 hook entries into
/// `~/.codex/hooks.json` (preserving user hooks), and patches
/// `~/.codex/config.toml` only when needed — Codex defaults `[features].hooks`
/// to true so cctop doesn't write the flag on a clean config. It removes any
/// deprecated `codex_hooks` line (which would trigger Codex's startup warning)
/// and overrides an explicit `hooks = false` opt-out.
/// Ownership is tracked by substring-matching `cctop-shim.sh` inside hook commands,
/// so reinstall is idempotent and uninstall never touches entries it did not create.
enum CodexPluginInstaller {

    static let registeredEvents: [String] = [
        "SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop"
    ]

    /// Substring used to identify cctop-owned hook entries inside hooks.json.
    static let ownershipMarker = "cctop-shim.sh"

    // MARK: - Paths

    /// Reads HOME from the environment so tests can override. Falls back to the
    /// current-user home directory.
    private static var homeDir: URL {
        if let home = ProcessInfo.processInfo.environment["HOME"] {
            return URL(fileURLWithPath: home)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    static var codexDir: URL { homeDir.appendingPathComponent(".codex") }
    static var shimPath: URL { codexDir.appendingPathComponent("cctop-shim.sh") }
    static var hooksJsonPath: URL { codexDir.appendingPathComponent("hooks.json") }
    static var configTomlPath: URL { codexDir.appendingPathComponent("config.toml") }

    // MARK: - Detection

    /// True if `~/.codex/` exists. Used to decide whether to show the install banner.
    static func codexConfigExists() -> Bool {
        FileManager.default.fileExists(atPath: codexDir.path)
    }

    /// Wired up to fire on Codex events? Requires shim + 5 hook entries + hooks
    /// not explicitly disabled. A missing config.toml or an unset flag counts
    /// as enabled because Codex defaults `[features].hooks` to true. Only an
    /// explicit `hooks = false` (or `codex_hooks = false` with no overriding
    /// `hooks` value) flips this to false.
    /// Staleness is reported separately via `needsUpdate(bundledShim:)`.
    static func isInstalled() -> Bool {
        guard FileManager.default.fileExists(atPath: shimPath.path) else { return false }
        guard let root = try? readJsonDict(at: hooksJsonPath),
              let hooks = root["hooks"] as? [String: Any] else {
            return false
        }
        for event in registeredEvents {
            guard let entries = hooks[event] as? [[String: Any]],
                  entries.contains(where: hasCctopCommand) else { return false }
        }
        // Only an explicit opt-out counts as not installed. Missing file or
        // unset flag = Codex default (hooks enabled).
        if let configText = try? String(contentsOf: configTomlPath, encoding: .utf8),
           !isFeatureFlagEnabled(configText) {
            return false
        }
        return true
    }

    /// Nil if missing. Throws `InstallError.corruptJson` if present but unparseable,
    /// so callers refuse to overwrite a corrupt user file.
    private static func readJsonDict(at url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            let parsed = try JSONSerialization.jsonObject(with: data)
            return parsed as? [String: Any]
        } catch {
            logger.error(
                "Failed to parse \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)"
            )
            throw InstallError.corruptJson
        }
    }

    /// True if the bundled shim content differs from the installed shim (update available).
    static func needsUpdate(bundledShim: Data) -> Bool {
        guard let installed = try? Data(contentsOf: shimPath) else { return false }
        return installed != bundledShim
    }

    // MARK: - Install / Remove

    static func install(shimContents: Data, hooksTemplate: Data) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: codexDir, withIntermediateDirectories: true
            )
            try writeShim(shimContents)
            try mergeHooksFile(template: hooksTemplate)
            try enableFeatureFlag()
            logger.info("Installed Codex plugin to \(codexDir.path, privacy: .public)")
            return true
        } catch {
            logger.error("Failed to install Codex plugin: \(error, privacy: .public)")
            return false
        }
    }

    /// Remove cctop's hooks entries and delete the shim. Leaves the feature flag and
    /// any user-defined hooks untouched.
    static func remove() -> Bool {
        do {
            try removeHooksEntries()
            // Ignore "file doesn't exist" when removing the shim; propagate other errors.
            if FileManager.default.fileExists(atPath: shimPath.path) {
                try FileManager.default.removeItem(at: shimPath)
            }
            logger.info("Removed Codex plugin")
            return true
        } catch {
            logger.error("Failed to remove Codex plugin: \(error, privacy: .public)")
            return false
        }
    }

    // MARK: - Shim

    private static func writeShim(_ data: Data) throws {
        try data.write(to: shimPath, options: .atomic)
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try FileManager.default.setAttributes(attrs, ofItemAtPath: shimPath.path)
    }

    // MARK: - hooks.json merge

    /// Merge cctop hook entries from `template` into `~/.codex/hooks.json`, replacing
    /// any prior cctop-owned commands. Preserves unrelated user hooks. Throws
    /// `InstallError.corruptJson` if the existing file cannot be parsed — the caller
    /// should surface this as "Install failed" rather than clobber user data.
    static func mergeHooksFile(template templateData: Data) throws {
        guard let template = (try? JSONSerialization.jsonObject(with: templateData)) as? [String: Any],
              let templateHooks = template["hooks"] as? [String: Any] else {
            throw InstallError.invalidTemplate
        }

        let resolvedTemplateHooks = substituteShimPath(
            in: templateHooks, shim: shellQuote(shimPath.path)
        )

        var rootDict = try readJsonDict(at: hooksJsonPath) ?? [:]
        var hooksDict = (rootDict["hooks"] as? [String: Any]) ?? [:]

        for event in registeredEvents {
            var entries = (hooksDict[event] as? [[String: Any]]) ?? []
            entries = stripCctopCommands(from: entries)
            if let templateEntries = resolvedTemplateHooks[event] as? [[String: Any]] {
                entries.append(contentsOf: templateEntries)
            }
            hooksDict[event] = entries
        }

        rootDict["hooks"] = hooksDict
        try writeHooksJson(rootDict)
    }

    /// Remove all cctop-owned commands from `~/.codex/hooks.json`. Matcher entries that
    /// become empty after stripping are dropped. Event keys that have no remaining
    /// matchers are dropped. Never touches user commands that share a matcher. Throws
    /// `InstallError.corruptJson` if the file cannot be parsed — do not overwrite it.
    static func removeHooksEntries() throws {
        guard var rootDict = try readJsonDict(at: hooksJsonPath) else { return }
        var hooksDict = (rootDict["hooks"] as? [String: Any]) ?? [:]
        for (event, value) in hooksDict {
            guard let entries = value as? [[String: Any]] else { continue }
            let stripped = stripCctopCommands(from: entries)
            if stripped.isEmpty {
                hooksDict.removeValue(forKey: event)
            } else {
                hooksDict[event] = stripped
            }
        }
        rootDict["hooks"] = hooksDict
        try writeHooksJson(rootDict)
    }

    /// Returns true if any command in a matcher entry references the cctop shim.
    /// A matcher entry has shape `{ "matcher": "...", "hooks": [{ "type": "command", ... }] }`.
    private static func hasCctopCommand(_ entry: [String: Any]) -> Bool {
        guard let commands = entry["hooks"] as? [[String: Any]] else { return false }
        return commands.contains {
            ($0["command"] as? String)?.contains(ownershipMarker) ?? false
        }
    }

    /// For each matcher entry, remove inner commands that reference the cctop shim.
    /// If a matcher's `hooks` array becomes empty, drop the matcher entirely. Non-cctop
    /// commands sharing a matcher with a cctop command are preserved.
    private static func stripCctopCommands(from entries: [[String: Any]]) -> [[String: Any]] {
        entries.compactMap { entry in
            guard var inner = entry["hooks"] as? [[String: Any]] else { return entry }
            inner.removeAll {
                ($0["command"] as? String)?.contains(ownershipMarker) ?? false
            }
            if inner.isEmpty { return nil }
            var mut = entry
            mut["hooks"] = inner
            return mut
        }
    }

    /// POSIX shell single-quoting for a path. Wraps the path in `'...'` and escapes any
    /// embedded single quotes by closing-escaping-reopening. Handles spaces, `$`, `"`,
    /// backslashes, and other metacharacters safely.
    static func shellQuote(_ path: String) -> String {
        let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Replace `{SHIM}` placeholders in every command string with the (already
    /// shell-quoted) shim path.
    private static func substituteShimPath(
        in hooksDict: [String: Any], shim: String
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        for (event, value) in hooksDict {
            guard let entries = value as? [[String: Any]] else {
                result[event] = value
                continue
            }
            result[event] = entries.map { entry -> [String: Any] in
                var mutable = entry
                if let cmds = entry["hooks"] as? [[String: Any]] {
                    mutable["hooks"] = cmds.map { cmd -> [String: Any] in
                        var cmdMut = cmd
                        if let raw = cmd["command"] as? String {
                            cmdMut["command"] = raw.replacingOccurrences(of: "{SHIM}", with: shim)
                        }
                        return cmdMut
                    }
                }
                return mutable
            }
        }
        return result
    }

    private static func writeHooksJson(_ root: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )
        // `JSONSerialization` escapes `/` as `\/`. That's valid JSON but noisy when a
        // user cats their hooks.json; replace with the bare `/`, which is also valid.
        guard let text = String(data: data, encoding: .utf8) else {
            try data.write(to: hooksJsonPath, options: .atomic)
            return
        }
        let cleaned = text.replacingOccurrences(of: "\\/", with: "/")
        try Data(cleaned.utf8).write(to: hooksJsonPath, options: .atomic)
    }

    // MARK: - config.toml feature flag

    /// Patch config.toml to make Codex load cctop's hooks: remove any
    /// deprecated `codex_hooks` line, override an explicit `hooks = false`.
    /// No-op on a clean config (Codex defaults `hooks` to true). No-op when
    /// config.toml doesn't exist (same reason).
    static func enableFeatureFlag() throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: configTomlPath.path) else { return }

        guard let raw = try? String(contentsOf: configTomlPath, encoding: .utf8) else {
            throw InstallError.invalidConfigToml
        }
        let patched = patchConfigToml(raw)
        if patched != raw {
            try patched.data(using: .utf8)?.write(to: configTomlPath, options: .atomic)
        }
    }

    /// TOML feature-flag patching. See `CodexConfigToml.patchEnableHooks`.
    static func patchConfigToml(_ input: String) -> String {
        CodexConfigToml.patchEnableHooks(input)
    }

    /// See `CodexConfigToml.isHooksEnabled`.
    static func isFeatureFlagEnabled(_ input: String) -> Bool {
        CodexConfigToml.isHooksEnabled(input)
    }

    /// True if config.toml still contains the deprecated `[features].codex_hooks`
    /// line. Used to drive the "Update Available" UI for installs that predate
    /// the rename.
    static func configTomlHasLegacyKey(_ input: String) -> Bool {
        CodexConfigToml.hasLegacyKey(input)
    }

    // MARK: - Errors

    enum InstallError: Error {
        case invalidTemplate
        case invalidConfigToml
        case corruptJson
    }
}
