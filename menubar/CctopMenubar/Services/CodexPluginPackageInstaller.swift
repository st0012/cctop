import Foundation
import os.log

private let codexPluginPackageLogger = Logger(
    subsystem: "com.st0012.CctopMenubar",
    category: "CodexPluginPackageInstaller"
)

struct CodexPluginPackageSnapshot: Equatable {
    let installed: Bool
    let needsUpdate: Bool
}

enum CodexPluginPackageInstaller {
    static let pluginName = "cctop"
    static let marketplaceName = "cctop"
    static let pluginSelector = "\(pluginName)@\(marketplaceName)"
    static let pluginHookSource = "\(pluginSelector):hooks/hooks.json"
    private static let legacyPluginSelectors = [
        "cctop@personal",
        "cctop-codex@personal",
        "cctop-codex@cctop",
    ]

    enum InstallError: Error {
        case corruptMarketplace
        case incompatibleMarketplaceName(String)
    }

    static var pluginInstallRoot: URL {
        marketplaceRoot.appendingPathComponent("plugins/cctop-codex")
    }

    static var marketplaceRoot: URL {
        UserHomeDirectory.url.appendingPathComponent(".cctop/codex-plugin-marketplace")
    }

    static var marketplacePath: URL {
        marketplaceRoot.appendingPathComponent(".agents/plugins/marketplace.json")
    }

    static var hooksJsonPath: URL {
        pluginInstallRoot.appendingPathComponent("hooks/hooks.json")
    }

    static var shimPath: URL {
        pluginInstallRoot.appendingPathComponent("hooks/cctop-shim.sh")
    }

    static func bundledPluginURL(bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "cctop-codex-plugin", withExtension: nil)
    }

    static func installBundledPlugin(bundle: Bundle = .main) -> Bool {
        guard let source = bundledPluginURL(bundle: bundle) else {
            codexPluginPackageLogger.error("Missing bundled cctop plugin")
            return false
        }
        return installPluginPackage(from: source)
    }

    static func installPluginPackage(from source: URL) -> Bool {
        do {
            try replaceDirectory(from: source, to: pluginInstallRoot)
            try ensureBundledShimIsExecutable()
            try writeMarketplace()
            try installConfigEntries()
            try CodexPluginInstaller.enableFeatureFlag()
            let installed = hasCurrentInstalledConfigEntry()
                && hasCurrentMarketplaceConfigEntry()
                && hasInstalledPluginFiles()
            if installed {
                removeLegacyUserHooks()
            }
            return installed
        } catch {
            codexPluginPackageLogger.error("Failed to install cctop plugin: \(error, privacy: .public)")
            return false
        }
    }

    static func removeBundledPlugin() -> Bool {
        do {
            try removeConfigEntries()
            if FileManager.default.fileExists(atPath: pluginInstallRoot.path) {
                try FileManager.default.removeItem(at: pluginInstallRoot)
            }
        } catch {
            codexPluginPackageLogger.error("Failed to remove bundled cctop plugin files: \(error, privacy: .public)")
            return false
        }

        return CodexPluginInstaller.remove()
    }

    static func hasInstalledPluginFiles() -> Bool {
        let manifest = pluginInstallRoot.appendingPathComponent(".codex-plugin/plugin.json")
        return FileManager.default.fileExists(atPath: manifest.path)
            && FileManager.default.fileExists(atPath: hooksJsonPath.path)
            && FileManager.default.isExecutableFile(atPath: shimPath.path)
    }

    static func hasCurrentInstalledConfigEntry(configText: String? = nil) -> Bool {
        configState(configText: configText).currentPluginEnabled == true
    }

    static func hasCurrentMarketplaceConfigEntry(configText: String? = nil) -> Bool {
        configState(configText: configText).currentMarketplaceConfigured
    }

    static func hasLegacyInstalledConfigEntry(configText: String? = nil) -> Bool {
        configState(configText: configText).legacyPluginEnabled
    }

    static func hasCurrentOrLegacyInstalledConfigEntry(configText: String? = nil) -> Bool {
        let state = configState(configText: configText)
        return state.currentPluginEnabled == true || state.legacyPluginEnabled
    }

    static func installationSnapshot(configText: String? = nil, bundle: Bundle = .main) -> CodexPluginPackageSnapshot {
        let state = configState(configText: configText)
        let filesInstalled = hasInstalledPluginFiles()
        let currentConfigInstalled = state.currentPluginEnabled == true
        let currentMarketplaceConfigured = state.currentMarketplaceConfigured
        let packageFilesNeedUpdate: Bool
        if currentConfigInstalled,
           currentMarketplaceConfigured,
           filesInstalled,
           let bundled = bundledPluginURL(bundle: bundle) {
            packageFilesNeedUpdate = needsUpdate(
                bundledPluginRoot: bundled,
                installedPluginRoot: pluginInstallRoot
            )
        } else {
            packageFilesNeedUpdate = false
        }

        return CodexPluginPackageSnapshot(
            installed: currentConfigInstalled && currentMarketplaceConfigured && filesInstalled,
            needsUpdate: state.legacyPluginEnabled
                || (currentConfigInstalled && !currentMarketplaceConfigured)
                || packageFilesNeedUpdate
        )
    }

    static func needsUpdate(bundledPluginRoot bundled: URL, installedPluginRoot installed: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: installed.path) else {
            return false
        }
        guard let bundledFingerprint = fingerprint(at: bundled) else {
            return false
        }
        guard let installedFingerprint = fingerprint(at: installed) else {
            return true
        }
        return bundledFingerprint != installedFingerprint
    }

    private static func configState(configText: String? = nil) -> CodexPluginConfigState {
        CodexPluginConfigEntryParser.state(
            configText: configText,
            context: CodexPluginConfigParserContext(
                configURL: CodexPluginInstaller.configTomlPath,
                marketplaceName: marketplaceName,
                marketplaceSource: marketplaceRoot.path,
                pluginSelector: pluginSelector,
                legacyPluginSelectors: legacyPluginSelectors
            )
        )
    }
}

extension CodexPluginPackageInstaller {
    private static func replaceDirectory(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.copyItem(at: source, to: destination)
    }

    private static func writeMarketplace() throws {
        try FileManager.default.createDirectory(
            at: marketplacePath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = FileManager.default.fileExists(atPath: marketplacePath.path)
            ? try Data(contentsOf: marketplacePath)
            : nil
        let payload = try mergedMarketplacePayload(existingData: existing)
        try payload.write(to: marketplacePath, options: .atomic)
    }

    private static func installConfigEntries() throws {
        let configURL = CodexPluginInstaller.configTomlPath
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = FileManager.default.fileExists(atPath: configURL.path)
            ? try String(contentsOf: configURL, encoding: .utf8)
            : ""
        let patched = configTomlInstallingPlugin(existing)
        if patched != existing {
            try patched.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    private static func removeConfigEntries() throws {
        let configURL = CodexPluginInstaller.configTomlPath
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let existing = try String(contentsOf: configURL, encoding: .utf8)
        let patched = configTomlRemovingPlugin(existing)
        if patched != existing {
            try patched.write(to: configURL, atomically: true, encoding: .utf8)
        }
    }

    static func configTomlInstallingPlugin(_ input: String) -> String {
        appendSections(
            [
                marketplaceConfigSection(),
                pluginConfigSection(),
            ],
            to: removingManagedConfigSections(from: input, removeMarketplace: true)
        )
    }

    static func configTomlRemovingPlugin(_ input: String) -> String {
        normalizedConfig(
            removingManagedConfigSections(
                from: input,
                removeMarketplace: hasCurrentMarketplaceConfigEntry(configText: input)
            )
        )
    }

    static func mergedMarketplacePayload(existingData: Data?) throws -> Data {
        var payload: [String: Any]
        if let existingData, !existingData.isEmpty {
            guard let parsed = try? JSONSerialization.jsonObject(with: existingData),
                  let parsedPayload = parsed as? [String: Any] else {
                throw InstallError.corruptMarketplace
            }
            payload = parsedPayload
        } else {
            payload = defaultMarketplace()
        }

        guard let name = payload["name"] as? String, !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw InstallError.corruptMarketplace
        }
        guard name == marketplaceName else {
            throw InstallError.incompatibleMarketplaceName(name)
        }

        // Preserve corrupt-file detection even though cctop rewrites this field below.
        if payload["interface"] != nil, payload["interface"] as? [String: Any] == nil {
            throw InstallError.corruptMarketplace
        }
        payload["interface"] = ["displayName": "cctop"]

        var plugins: [[String: Any]]
        if let existingPlugins = payload["plugins"] {
            guard let parsedPlugins = existingPlugins as? [[String: Any]] else {
                throw InstallError.corruptMarketplace
            }
            plugins = parsedPlugins
        } else {
            plugins = []
        }

        payload["plugins"] = mergingCctopPackageEntry(into: plugins)

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        return data + Data("\n".utf8)
    }

    private static func defaultMarketplace() -> [String: Any] {
        [
            "name": marketplaceName,
            "interface": [
                "displayName": "cctop",
            ],
            "plugins": [],
        ]
    }

    private static func marketplaceEntry() -> [String: Any] {
        [
            "name": pluginName,
            "source": [
                "source": "local",
                "path": "./plugins/cctop-codex",
            ],
            "policy": [
                "installation": "AVAILABLE",
                "authentication": "ON_INSTALL",
            ],
            "category": "Productivity",
        ]
    }

    private static func mergingCctopPackageEntry(into plugins: [[String: Any]]) -> [[String: Any]] {
        let namesToReplace = Set([pluginName, "cctop-codex"])
        var insertedCctopEntry = false
        var merged = plugins.compactMap { plugin -> [String: Any]? in
            guard let name = plugin["name"] as? String,
                  namesToReplace.contains(name) else {
                return plugin
            }
            if insertedCctopEntry {
                return nil
            }
            insertedCctopEntry = true
            return marketplaceEntry()
        }
        if !insertedCctopEntry {
            merged.append(marketplaceEntry())
        }
        return merged
    }

    private static func ensureBundledShimIsExecutable() throws {
        guard FileManager.default.fileExists(atPath: shimPath.path) else { return }
        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try FileManager.default.setAttributes(attrs, ofItemAtPath: shimPath.path)
    }

    private static func removeLegacyUserHooks() {
        if !CodexPluginInstaller.remove() {
            codexPluginPackageLogger.warning("Could not remove legacy user-level Codex hooks")
        }
    }

    private static func fingerprint(at root: URL) -> [String: Data]? {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else {
            return nil
        }

        var fingerprint: [String: Data] = [:]
        for case let relativePath as String in enumerator {
            if relativePath.hasSuffix(".DS_Store") {
                continue
            }
            let url = root.appendingPathComponent(relativePath)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                continue
            }
            guard let data = try? Data(contentsOf: url) else {
                return nil
            }
            fingerprint[relativePath] = data
        }
        return fingerprint
    }

    private static func marketplaceConfigSection() -> String {
        """
        [marketplaces.\(marketplaceName)]
        source_type = "local"
        source = \(tomlString(marketplaceRoot.path))
        """
    }

    private static func pluginConfigSection() -> String {
        """
        [plugins.\(tomlString(pluginSelector))]
        enabled = true
        """
    }

    private static func removingManagedConfigSections(from input: String, removeMarketplace: Bool) -> String {
        let marketplaceHeaders = removeMarketplace ? ["[marketplaces.\(marketplaceName)]"] : []
        let managedHeaders = Set(
            marketplaceHeaders
                + ([pluginSelector] + legacyPluginSelectors).map { "[plugins.\(tomlString($0))]" }
        )
        return removingSections(withHeaders: managedHeaders, from: input)
    }

    private static func removingSections(withHeaders headers: Set<String>, from input: String) -> String {
        var output: [String] = []
        var skipping = false
        for line in input.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isTomlSectionHeader(trimmed) {
                skipping = headers.contains(trimmed)
            }
            if !skipping {
                output.append(line)
            }
        }
        return output.joined(separator: "\n")
    }

    private static func appendSections(_ sections: [String], to input: String) -> String {
        let base = normalizedConfig(input)
        let suffix = sections.joined(separator: "\n\n")
        if base.isEmpty {
            return suffix + "\n"
        }
        return base + "\n\n" + suffix + "\n"
    }

    private static func normalizedConfig(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + "\n"
    }

    private static func isTomlSectionHeader(_ line: String) -> Bool {
        line.hasPrefix("[") && line.hasSuffix("]")
    }

    private static func tomlString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
