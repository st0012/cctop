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
    /// A deprecated `[features].codex_hooks` key is present — Codex warns on
    /// every load until it's migrated to the current `hooks` name.
    let legacyConfigKey: Bool

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
    let legacyConfigKey: Bool
    /// Absolute path of the observed hooks.json. Codex keys its trust
    /// records by this path, so it is part of the observation instead of
    /// being read from the installer at derivation time.
    let hooksJsonPath: String
}

enum CodexIntegrationManager {
    static func snapshot(_ observation: CodexIntegrationObservation) -> CodexIntegrationSnapshot {
        let status = hookStatus(
            installed: observation.hookFilesInstalled,
            featureEnabled: observation.featureEnabled,
            needsUpdate: observation.needsUpdate,
            configText: observation.configText,
            hooksJsonPath: observation.hooksJsonPath
        )
        // Derive the published update flag from the status so every UI
        // surface agrees with the status-driven Settings row.
        return CodexIntegrationSnapshot(
            configExists: observation.configExists,
            hookStatus: status,
            needsUpdate: status == .needsUpdate,
            legacyConfigKey: observation.legacyConfigKey
        )
    }

    /// An explicit `hooks = false` opt-out wins over staleness: offering
    /// "Update Hooks" there would silently re-enable the user's opt-out,
    /// while "Enable Hooks" names the action actually taken.
    static func hookStatus(
        installed: Bool,
        featureEnabled: Bool,
        needsUpdate: Bool,
        configText: String?,
        hooksJsonPath: String
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
           hasTrustedCctopHookState(in: configText, hooksPath: hooksJsonPath) {
            return .trusted
        }
        return .installedUntrusted
    }

    // MARK: - Codex trust records

    /// Snake-case event keys Codex uses for `[hooks.state]` trust entries
    /// (an empirical observation of Codex's format), derived from
    /// `CodexPluginInstaller.registeredEvents` so the two lists cannot drift.
    static let trustStateEventKeys: [String] =
        CodexPluginInstaller.registeredEvents.map(snakeCased)

    /// PascalCase -> snake_case as Codex writes its trust-record keys:
    /// SessionStart -> session_start, PreToolUse -> pre_tool_use.
    private static func snakeCased(_ pascal: String) -> String {
        var result = ""
        for character in pascal {
            if character.isUppercase && !result.isEmpty {
                result.append("_")
            }
            result.append(character.lowercased())
        }
        return result
    }

    /// Codex records reviewed command hooks under `[hooks.state]` in
    /// config.toml. Reading them is a conservative UI signal only: cctop
    /// never writes these entries and does not try to reproduce Codex's
    /// private trust-hash calculation. True when every registered cctop
    /// event has a `trusted_hash` entry for `hooksPath` and none of them
    /// is switched off — disabling a trusted hook in Codex upserts
    /// `enabled = false` into the same table while keeping the old hash.
    static func hasTrustedCctopHookState(in configText: String, hooksPath: String) -> Bool {
        var trustedEvents: Set<String> = []
        var currentCctopEvent: String?
        var currentTrusted = false
        var currentDisabled = false

        func commitCurrentSection() {
            if let event = currentCctopEvent, currentTrusted, !currentDisabled {
                trustedEvents.insert(event)
            }
            currentCctopEvent = nil
            currentTrusted = false
            currentDisabled = false
        }

        for line in configText.components(separatedBy: "\n") {
            if isTomlSectionHeader(line) {
                commitCurrentSection()
                currentCctopEvent = parseCctopHookStateEvent(line, hooksPath: hooksPath)
                continue
            }
            guard currentCctopEvent != nil else { continue }
            if isTrustedHashLine(line) { currentTrusted = true }
            if isDisabledLine(line) { currentDisabled = true }
        }
        commitCurrentSection()

        return Set(trustStateEventKeys).isSubset(of: trustedEvents)
    }

    private static func isTomlSectionHeader(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]")
    }

    /// Parses a `[hooks.state."<hooksPath>:<event>:..."]` header. Returns the
    /// cctop event key when the source path matches `hooksPath`, else nil.
    /// TOML allows both quote styles for keys, so strip `'` as well as `"`.
    private static func parseCctopHookStateEvent(_ line: String, hooksPath: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("[hooks.state.") && trimmed.hasSuffix("]") else { return nil }
        let key = trimmed
            .dropFirst("[hooks.state.".count)
            .dropLast()
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        for event in trustStateEventKeys {
            let marker = ":\(event):"
            guard let markerRange = key.range(of: marker) else { continue }
            if String(key[..<markerRange.lowerBound]) == hooksPath {
                return event
            }
        }
        return nil
    }

    private static func isTrustedHashLine(_ line: String) -> Bool {
        let trimmed = CodexConfigToml.stripCommentAndTrim(line)
        guard trimmed.hasPrefix("trusted_hash") else { return false }
        return trimmed.contains("=") && trimmed.contains("\"sha256:")
    }

    private static func isDisabledLine(_ line: String) -> Bool {
        CodexConfigToml.stripCommentAndTrim(line).filter { !$0.isWhitespace } == "enabled=false"
    }
}
