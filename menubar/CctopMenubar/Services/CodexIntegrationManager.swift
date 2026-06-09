import Foundation

/// User-visible state of the Codex hook integration. Installed hook files
/// alone do not mean Codex runs them — Codex only executes hooks after the
/// user reviews and trusts them, so `installedUntrusted` and `trusted` are
/// separate states.
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
    let hookStatus: CodexHookStatus
    let needsUpdate: Bool

    var installed: Bool {
        hookStatus.isInstalled
    }
}

/// Pure input shape for deriving user-visible Codex setup state. Keeping this
/// separate from file-system reads lets tests cover hook state combinations.
struct CodexIntegrationObservation: Equatable {
    let configExists: Bool
    let hookFilesInstalled: Bool
    let featureEnabled: Bool
    let needsUpdate: Bool
    let configText: String?
}

enum CodexIntegrationManager {
    static func snapshot(_ observation: CodexIntegrationObservation) -> CodexIntegrationSnapshot {
        let status = hookStatus(
            installed: observation.hookFilesInstalled,
            featureEnabled: observation.featureEnabled,
            needsUpdate: observation.needsUpdate,
            configText: observation.configText
        )
        // Derive the published update flag from the status so every UI
        // surface agrees with the status-driven Settings row.
        return CodexIntegrationSnapshot(
            configExists: observation.configExists,
            hookStatus: status,
            needsUpdate: status == .needsUpdate
        )
    }

    /// An explicit `hooks = false` opt-out wins over staleness: offering
    /// "Update Hooks" there would silently re-enable the user's opt-out,
    /// while "Enable Hooks" names the action actually taken.
    static func hookStatus(
        installed: Bool,
        featureEnabled: Bool,
        needsUpdate: Bool,
        configText: String?
    ) -> CodexHookStatus {
        guard installed else {
            return featureEnabled ? .notInstalled : .hooksDisabled
        }
        guard featureEnabled else {
            return .hooksDisabled
        }
        if needsUpdate {
            return .needsUpdate
        }
        if let configText,
           CodexPluginInstaller.hasTrustedCctopHookState(
               in: configText, hooksPath: CodexPluginInstaller.hooksJsonPath.path
           ) {
            return .trusted
        }
        return .installedUntrusted
    }
}
