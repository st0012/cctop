import Foundation

enum CodexHookStatus: Equatable {
    case notInstalled
    case hooksDisabled
    case needsUpdate
    case installedUntrusted
    case trusted

    var isInstalled: Bool {
        switch self {
        case .notInstalled, .hooksDisabled:
            return false
        case .needsUpdate, .installedUntrusted, .trusted:
            return true
        }
    }

    var needsTrust: Bool {
        self == .installedUntrusted
    }
}

struct CodexIntegrationSnapshot: Equatable {
    let configExists: Bool
    let pluginPackageInstalled: Bool
    let hookStatus: CodexHookStatus
    let needsUpdate: Bool

    var installed: Bool {
        hookStatus.isInstalled
    }
}

/// Pure input shape for deriving user-visible Codex setup state. Keeping this
/// separate from file-system reads lets tests cover hook/plugin combinations.
struct CodexIntegrationObservation: Equatable {
    let configExists: Bool
    let hookFilesInstalled: Bool
    let featureEnabled: Bool
    let needsUpdate: Bool
    let configText: String?
    let pluginPackageInstalled: Bool
}

enum CodexIntegrationManager {
    static func currentSnapshot() -> CodexIntegrationSnapshot {
        let configExists = CodexPluginInstaller.codexConfigExists()
        let configText: String? = configExists
            ? (try? String(contentsOf: CodexPluginInstaller.configTomlPath, encoding: .utf8))
            : nil
        let hookFilesInstalled = CodexPluginInstaller.hasInstalledHookFiles()
        let featureEnabled = configText.map(CodexPluginInstaller.isFeatureFlagEnabled) ?? true
        let pluginPackageSnapshot = CodexPluginPackageInstaller.installationSnapshot(configText: configText)
        let needsUpdate = hookFilesInstalled
            || pluginPackageSnapshot.needsUpdate
            || legacyCodexConfigNeedsRepair(configText: configText)

        return snapshot(CodexIntegrationObservation(
            configExists: configExists,
            hookFilesInstalled: hookFilesInstalled,
            featureEnabled: featureEnabled,
            needsUpdate: needsUpdate,
            configText: configText,
            pluginPackageInstalled: pluginPackageSnapshot.installed
        ))
    }

    static func snapshot(_ observation: CodexIntegrationObservation) -> CodexIntegrationSnapshot {
        let hasRepairableInstall = observation.hookFilesInstalled
            || observation.pluginPackageInstalled
            || observation.needsUpdate
        let trustedHookSources = trustedHookSources(
            hookFilesInstalled: observation.hookFilesInstalled,
            pluginPackageInstalled: observation.pluginPackageInstalled
        )

        return CodexIntegrationSnapshot(
            configExists: observation.configExists,
            pluginPackageInstalled: observation.pluginPackageInstalled,
            hookStatus: hookStatus(
                installed: hasRepairableInstall,
                featureEnabled: observation.featureEnabled,
                needsUpdate: observation.needsUpdate,
                configText: observation.configText,
                trustedHookSources: trustedHookSources
            ),
            needsUpdate: observation.needsUpdate
        )
    }

    static func hookStatus(
        installed: Bool,
        featureEnabled: Bool,
        needsUpdate: Bool,
        configText: String?,
        trustedHookSources: [String] = allKnownCctopHookSources()
    ) -> CodexHookStatus {
        guard installed else {
            return featureEnabled ? .notInstalled : .hooksDisabled
        }
        if needsUpdate {
            return .needsUpdate
        }
        guard featureEnabled else {
            return .hooksDisabled
        }
        if let configText,
           !trustedHookSources.isEmpty,
           CodexPluginInstaller.hasTrustedCctopHookState(in: configText, hooksPaths: trustedHookSources) {
            return .trusted
        }
        return .installedUntrusted
    }

    static func legacyCodexConfigNeedsRepair(configText: String?) -> Bool {
        guard let text = configText else { return false }
        return CodexPluginInstaller.configTomlHasLegacyKey(text)
    }

    static func trustedHookSources(hookFilesInstalled: Bool, pluginPackageInstalled: Bool) -> [String] {
        var sources: [String] = []
        if hookFilesInstalled {
            sources.append(CodexPluginInstaller.hooksJsonPath.path)
        }
        if pluginPackageInstalled {
            sources.append(contentsOf: [
                CodexPluginPackageInstaller.pluginHookSource,
                CodexPluginPackageInstaller.hooksJsonPath.path,
            ])
        }
        return sources
    }

    private static func allKnownCctopHookSources() -> [String] {
        [
            CodexPluginInstaller.hooksJsonPath.path,
            CodexPluginPackageInstaller.pluginHookSource,
            CodexPluginPackageInstaller.hooksJsonPath.path,
        ]
    }
}
