import Foundation

enum SessionIdentityPolicy {
    enum LogicalIdentity: Hashable {
        case permanent(UUID)
        case legacy(String)

        var cctopSessionID: String? {
            guard case .permanent(let id) = self else { return nil }
            return id.uuidString.lowercased()
        }
    }

    static let notificationSessionIDKey = "sessionID"
    static let notificationSessionPIDKey = "sessionPID"
    static let notificationCctopSessionIDKey = "cctopSessionID"

    /// Legacy grouping key used by pre-ID dedup and conservative compatibility paths.
    static func stableKey(for session: SessionData) -> String {
        if session.isCodex {
            return "codex:\(session.sessionId)"
        }
        if session.hostClass == .desktop {
            return "desktop:\(session.sessionId)"
        }
        return "active:\(session.id)"
    }

    /// Panel identity prefers cctop's permanent UUID. Legacy records retain the existing
    /// source- and host-aware key until a permanent ID becomes available.
    static func logicalIdentity(for session: SessionData) -> LogicalIdentity {
        if let cctopSessionID = session.cctopSessionId,
           CctopSessionID.isValid(cctopSessionID),
           let id = UUID(uuidString: cctopSessionID) {
            return .permanent(id)
        }
        return .legacy(stableKey(for: session))
    }

    /// Source-inventory migration helper. Current routing reads identity from `UserSession`.
    fileprivate static func permanentSessionID(for session: SessionData) -> String? {
        guard CctopSessionID.isValid(session.cctopSessionId) else { return nil }
        return session.cctopSessionId
    }

    static func notificationRequestIdentifier(forCctopSessionID cctopSessionID: String) -> String? {
        guard CctopSessionID.isValid(cctopSessionID) else { return nil }
        return "session-\(cctopSessionID)"
    }

    static func notificationUserInfo(forCctopSessionID cctopSessionID: String) -> [AnyHashable: Any]? {
        guard CctopSessionID.isValid(cctopSessionID) else { return nil }
        return [notificationCctopSessionIDKey: cctopSessionID]
    }

    /// Identifier used by already-delivered pre-migration notifications with durable
    /// Codex or desktop conversation identity. Process-scoped records are excluded.
    static func legacyNotificationRequestIdentifier(for session: SessionData) -> String? {
        guard session.isCodex || session.hostClass == .desktop,
              !notificationSessionID(for: session).isEmpty else { return nil }
        return "session-\(stableKey(for: session))"
    }

    static func cctopSessionID(matchingNotificationUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let cctopSessionID = nonEmptyString(userInfo[notificationCctopSessionIDKey]),
              CctopSessionID.isValid(cctopSessionID) else { return nil }
        return cctopSessionID
    }

    /// Recover a user session from a pre-migration notification even when the named
    /// session record has not been stamped yet. The user-session group remains authoritative.
    static func notificationCctopSessionID(
        matchingNotificationUserInfo userInfo: [AnyHashable: Any],
        in userSessions: [UserSession]
    ) -> String? {
        if let permanentValue = userInfo[notificationCctopSessionIDKey] {
            guard let cctopSessionID = nonEmptyString(permanentValue),
                  CctopSessionID.isValid(cctopSessionID) else { return nil }
            return cctopSessionID
        }

        guard let sessionIDValue = userInfo[notificationSessionIDKey],
              let sessionID = nonEmptyString(sessionIDValue) else { return nil }
        let matches = userSessions.filter { userSession in
            userSession.records.contains { record in
                let data = record.data
                return (data.isCodex || data.hostClass == .desktop)
                    && notificationSessionID(for: data) == sessionID
            }
        }
        guard !matches.isEmpty else { return nil }
        var permanentIDs: Set<String> = []
        for match in matches {
            guard let cctopSessionID = match.identity.cctopSessionID else { return nil }
            permanentIDs.insert(cctopSessionID)
        }
        guard permanentIDs.count == 1 else { return nil }
        return permanentIDs.first
    }

    private static func notificationSessionID(for session: SessionData) -> String {
        if session.isCodex || session.hostClass == .desktop {
            return session.sessionId
        }
        return session.id
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return string
    }

    /// Collapse multiple files for one conversation only for hosts with stable conversation identity.
    static func dedupedCandidatesByStableKey(_ candidates: [SessionRecord]) -> [SessionRecord] {
        var byKey: [String: SessionRecord] = [:]
        for candidate in candidates {
            let key = stableKey(for: candidate.data)
            if let existing = byKey[key], SessionLifecyclePolicy.prefers(existing, over: candidate) { continue }
            byKey[key] = candidate
        }
        return byKey.values.sorted { stableKey(for: $0.data) < stableKey(for: $1.data) }
    }

}

/// One pass's snapshot of every way a session can match a manual hide: migrated
/// permanent IDs, unresolved pre-release legacy keys, and the durable evidence those
/// keys imply. Built once per load/GC pass so the visibility filter, cleanup
/// retention, and file sweeps agree on the same answer.
struct ManualHideEvidence {
    let hiddenSessionIDs: Set<String>
    let legacyKeys: Set<String>
    let legacyEvidence: Set<String>

    var hasUnresolvedLegacyKeys: Bool { !legacyKeys.isEmpty }

    func matches(_ session: SessionData) -> Bool {
        if let cctopSessionID = session.cctopSessionId, hiddenSessionIDs.contains(cctopSessionID) {
            return true
        }
        if legacyKeys.contains(SessionIdentityPolicy.stableKey(for: session)) {
            return true
        }
        return CctopSessionIdentityStore.durableEvidence(for: session).map(legacyEvidence.contains) ?? false
    }
}

/// Persists manual visibility preferences independently from hook-owned session files.
/// The stored payload is intentionally limited to opaque cctop-owned session IDs.
struct ManualSessionVisibilityStore {
    static let defaultsKey = "manuallyHiddenCctopSessionIDs"
    // MIGRATION(permanent_identity): Only pre-release manual-hide builds wrote this key.
    // Reconsider after the first tagged release containing this migration, but remove it
    // only with an explicit decision to stop preserving those pre-release preferences.
    static let legacyDefaultsKey = "manuallyHiddenSessionStableKeys"
    static let live = ManualSessionVisibilityStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hiddenSessionIDs: Set<String> {
        Set((defaults.stringArray(forKey: Self.defaultsKey) ?? []).filter(CctopSessionID.isValid))
    }

    var hasStoredHideEvidence: Bool {
        !hiddenSessionIDs.isEmpty || !unresolvedDurableLegacyKeys.isEmpty
    }

    /// Durable legacy keys retained as display fallback until a complete, unambiguous inventory.
    /// A partial inventory may already have contributed a permanent ID. Process keys never participate.
    var unresolvedDurableLegacyKeys: Set<String> {
        legacyStableKeys.filter(Self.isDurableLegacyKey)
    }

    /// Snapshot manual-hide match state for one pass over the given session inventory.
    /// The inventory only contributes durable evidence for sessions still matching an
    /// unresolved legacy key; permanent IDs and legacy keys come from the store itself.
    func manualHideEvidence(in sessions: [SessionData]) -> ManualHideEvidence {
        let legacyKeys = unresolvedDurableLegacyKeys
        var evidence = Set(legacyKeys.compactMap(Self.durableEvidence(forLegacyKey:)))
        evidence.formUnion(sessions
            .filter { legacyKeys.contains(SessionIdentityPolicy.stableKey(for: $0)) }
            .compactMap(CctopSessionIdentityStore.durableEvidence(for:)))
        return ManualHideEvidence(
            hiddenSessionIDs: hiddenSessionIDs,
            legacyKeys: legacyKeys,
            legacyEvidence: evidence
        )
    }

    func isHidden(cctopSessionID: String) -> Bool {
        guard CctopSessionID.isValid(cctopSessionID) else { return false }
        return hiddenSessionIDs.contains(cctopSessionID)
    }

    func hide(cctopSessionID: String) {
        guard CctopSessionID.isValid(cctopSessionID) else { return }
        var sessionIDs = hiddenSessionIDs
        sessionIDs.insert(cctopSessionID)
        save(sessionIDs)
    }

    /// Upgrade exact, unambiguous durable matches, but retire their fallback only after
    /// the persisted inventory confirms the same identity. Retain partial or ambiguous keys.
    /// Process-scoped `active:<pid>` keys are retired rather than rebound to a new process generation.
    @discardableResult
    func migrateLegacyStableKeys(
        using sessions: [SessionData],
        persistedSessions: [SessionData],
        inventoryComplete: Bool
    ) -> Set<String> {
        let legacyKeys = legacyStableKeys
        guard !legacyKeys.isEmpty else { return hiddenSessionIDs }

        // A disk-stamped peer may supply a hide candidate when the legacy key itself
        // contains the same durable source and session UUID evidence.
        let persistedMatches = Self.persistedLegacyMigrationMatches(in: persistedSessions, legacyKeys: legacyKeys)

        var unresolvedMatchedKeys: Set<String> = []
        var sessionIDsByKey: [String: Set<String>] = [:]
        for session in sessions {
            let key = SessionIdentityPolicy.stableKey(for: session)
            guard legacyKeys.contains(key) else { continue }
            let matches = Self.legacyMigrationCandidateIDs(
                for: session, persistedSessionIDsByEvidence: persistedMatches.sessionIDsByEvidence
            )
            if matches.isEmpty {
                unresolvedMatchedKeys.insert(key)
            } else {
                sessionIDsByKey[key, default: []].formUnion(matches)
            }
        }

        var migratedSessionIDs = hiddenSessionIDs
        var remainingLegacyKeys = legacyKeys
        for key in legacyKeys.sorted() {
            guard Self.isDurableLegacyKey(key) else {
                if inventoryComplete { remainingLegacyKeys.remove(key) }
                continue
            }

            let legacyEvidence = Self.durableEvidence(forLegacyKey: key)
            let persistedEvidenceSessionIDs = legacyEvidence.map { persistedMatches.sessionIDsByEvidence[$0] ?? [] } ?? []
            var matches = sessionIDsByKey[key] ?? []
            matches.formUnion(persistedEvidenceSessionIDs)
            let isUnambiguous = matches.count == 1 && !unresolvedMatchedKeys.contains(key)
            if isUnambiguous, let match = matches.first { migratedSessionIDs.insert(match) }
            let persistedSessionIDs = persistedMatches.sessionIDsByKey[key] ?? []
            let persistedConfirmationIDs = persistedSessionIDs.isEmpty ? persistedEvidenceSessionIDs : persistedSessionIDs
            let hasUnresolvedPersistedEvidence = legacyEvidence
                .map(persistedMatches.unresolvedEvidence.contains) ?? false
            let hasPersistedEvidence = !persistedEvidenceSessionIDs.isEmpty || hasUnresolvedPersistedEvidence
            let isPersistedUnambiguous = isUnambiguous && persistedConfirmationIDs == matches
                && !persistedMatches.unresolvedMatchedKeys.contains(key)
                && !hasUnresolvedPersistedEvidence
            let isProvenMissing = matches.isEmpty && !unresolvedMatchedKeys.contains(key) && persistedSessionIDs.isEmpty
                && !persistedMatches.unresolvedMatchedKeys.contains(key)
                && !hasPersistedEvidence
            if inventoryComplete && (isPersistedUnambiguous || isProvenMissing) {
                remainingLegacyKeys.remove(key)
            }
        }

        if migratedSessionIDs != hiddenSessionIDs { save(migratedSessionIDs) }
        saveLegacy(remainingLegacyKeys)
        return migratedSessionIDs
    }

    /// What the persisted (disk-stamped) inventory says about legacy hide keys:
    /// which permanent IDs each durable evidence or legacy key maps to, and which
    /// evidence/keys matched a record that has no permanent ID yet.
    private struct PersistedLegacyMatches {
        var sessionIDsByEvidence: [String: Set<String>] = [:]
        var unresolvedEvidence: Set<String> = []
        var unresolvedMatchedKeys: Set<String> = []
        var sessionIDsByKey: [String: Set<String>] = [:]
    }

    private static func persistedLegacyMigrationMatches(
        in sessions: [SessionData],
        legacyKeys: Set<String>
    ) -> PersistedLegacyMatches {
        var matches = PersistedLegacyMatches()
        for session in sessions {
            let cctopSessionID = SessionIdentityPolicy.permanentSessionID(for: session)
            if let evidence = CctopSessionIdentityStore.durableEvidence(for: session) {
                if let cctopSessionID {
                    matches.sessionIDsByEvidence[evidence, default: []].insert(cctopSessionID)
                } else {
                    matches.unresolvedEvidence.insert(evidence)
                }
            }

            let key = SessionIdentityPolicy.stableKey(for: session)
            guard legacyKeys.contains(key) else { continue }
            if let cctopSessionID {
                matches.sessionIDsByKey[key, default: []].insert(cctopSessionID)
            } else {
                matches.unresolvedMatchedKeys.insert(key)
            }
        }
        return matches
    }

    private static func legacyMigrationCandidateIDs(
        for session: SessionData,
        persistedSessionIDsByEvidence: [String: Set<String>]
    ) -> Set<String> {
        var matches: Set<String> = []
        if let cctopSessionID = SessionIdentityPolicy.permanentSessionID(for: session) {
            matches.insert(cctopSessionID)
        }
        if let evidence = CctopSessionIdentityStore.durableEvidence(for: session) {
            matches.formUnion(persistedSessionIDsByEvidence[evidence] ?? [])
        }
        return matches
    }

    static func durableEvidence(forLegacyKey key: String) -> String? {
        let components = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let source: String
        switch components[0] {
        case "codex": source = SessionData.codexSource
        case "desktop": source = SessionData.ccSource
        default: return nil
        }
        let sessionID = String(components[1])
        return CctopSessionIdentityStore.durableEvidence(
            source: source,
            harnessSessionId: sessionID,
            legacySessionId: sessionID
        )
    }

    /// Remove IDs only after the caller has completed an authoritative local inventory.
    func prune(retaining validSessionIDs: Set<String>) {
        let current = hiddenSessionIDs
        let retained = current.intersection(validSessionIDs)
        guard retained != current else { return }
        save(retained)
    }

    private func save(_ sessionIDs: Set<String>) {
        if sessionIDs.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(sessionIDs.sorted(), forKey: Self.defaultsKey)
        }
    }

    private var legacyStableKeys: Set<String> {
        Set(defaults.stringArray(forKey: Self.legacyDefaultsKey) ?? [])
    }

    private static func isDurableLegacyKey(_ key: String) -> Bool {
        key.hasPrefix("codex:") || key.hasPrefix("desktop:")
    }

    private func saveLegacy(_ keys: Set<String>) {
        guard keys != legacyStableKeys else { return }
        if keys.isEmpty {
            defaults.removeObject(forKey: Self.legacyDefaultsKey)
        } else {
            defaults.set(keys.sorted(), forKey: Self.legacyDefaultsKey)
        }
    }
}
