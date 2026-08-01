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

    /// Stable grouping key shared by dedup and notification transition guards.
    static func stableKey(for session: Session) -> String {
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
    static func logicalIdentity(for session: Session) -> LogicalIdentity {
        if let cctopSessionID = session.cctopSessionId,
           Session.isValidCctopSessionId(cctopSessionID),
           let id = UUID(uuidString: cctopSessionID) {
            return .permanent(id)
        }
        return .legacy(stableKey(for: session))
    }

    static func notificationRequestIdentifier(forCctopSessionID cctopSessionID: String) -> String? {
        guard Session.isValidCctopSessionId(cctopSessionID) else { return nil }
        return "session-\(cctopSessionID)"
    }

    static func notificationUserInfo(forCctopSessionID cctopSessionID: String) -> [AnyHashable: Any]? {
        guard Session.isValidCctopSessionId(cctopSessionID) else { return nil }
        return [notificationCctopSessionIDKey: cctopSessionID]
    }

    /// Identifier used by already-delivered pre-migration notifications with durable
    /// Codex or desktop conversation identity. Process-scoped observations are excluded.
    static func legacyNotificationRequestIdentifier(for session: Session) -> String? {
        guard session.isCodex || session.hostClass == .desktop,
              !notificationSessionID(for: session).isEmpty else { return nil }
        return "session-\(stableKey(for: session))"
    }

    static func cctopSessionID(matchingNotificationUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let cctopSessionID = nonEmptyString(userInfo[notificationCctopSessionIDKey]),
              Session.isValidCctopSessionId(cctopSessionID) else { return nil }
        return cctopSessionID
    }

    /// Recover permanent identity from an already-delivered pre-migration payload.
    /// A present permanent-ID field is authoritative; invalid or missing targets fail closed.
    static func notificationCctopSessionID(
        matchingNotificationUserInfo userInfo: [AnyHashable: Any],
        in sessions: [Session]
    ) -> String? {
        if let permanentValue = userInfo[notificationCctopSessionIDKey] {
            guard let cctopSessionID = nonEmptyString(permanentValue),
                  Session.isValidCctopSessionId(cctopSessionID) else { return nil }
            return cctopSessionID
        }

        guard let sessionIDValue = userInfo[notificationSessionIDKey],
              let sessionID = nonEmptyString(sessionIDValue) else { return nil }
        let candidates = sessions.filter {
            ($0.isCodex || $0.hostClass == .desktop)
                && notificationSessionID(for: $0) == sessionID
        }

        guard !candidates.isEmpty else { return nil }
        var permanentIDs: Set<String> = []
        for candidate in candidates {
            guard let cctopSessionID = logicalIdentity(for: candidate).cctopSessionID else { return nil }
            permanentIDs.insert(cctopSessionID)
        }
        guard permanentIDs.count == 1 else { return nil }
        return permanentIDs.first
    }

    private static func notificationSessionID(for session: Session) -> String {
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
    static func dedupedCandidatesByStableKey(_ candidates: [DedupCandidate]) -> [DedupCandidate] {
        var byKey: [String: DedupCandidate] = [:]
        for candidate in candidates {
            let key = stableKey(for: candidate.session)
            if let existing = byKey[key], SessionLifecyclePolicy.prefers(existing, over: candidate) { continue }
            byKey[key] = candidate
        }
        return byKey.values.sorted { stableKey(for: $0.session) < stableKey(for: $1.session) }
    }

    /// Collapse visible observations that resolve to one logical panel row. The first
    /// occurrence owns the row position while the lifecycle policy chooses its observation.
    static func dedupedCandidatesByLogicalIdentity(_ candidates: [DedupCandidate]) -> [DedupCandidate] {
        var result: [DedupCandidate] = []
        var indexByIdentity: [LogicalIdentity: Int] = [:]

        for candidate in candidates {
            let identity = logicalIdentity(for: candidate.session)
            if let index = indexByIdentity[identity] {
                if SessionLifecyclePolicy.prefers(candidate, over: result[index]) {
                    result[index] = candidate
                }
            } else {
                indexByIdentity[identity] = result.count
                result.append(candidate)
            }
        }
        return result
    }
}

/// Persists manual visibility preferences independently from hook-owned session files.
/// The stored payload is intentionally limited to opaque cctop-owned session IDs.
struct ManualSessionVisibilityStore {
    static let defaultsKey = "manuallyHiddenCctopSessionIDs"
    static let legacyDefaultsKey = "manuallyHiddenSessionStableKeys"
    static let live = ManualSessionVisibilityStore(defaults: .standard)

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var hiddenSessionIDs: Set<String> {
        Set((defaults.stringArray(forKey: Self.defaultsKey) ?? []).filter(Session.isValidCctopSessionId))
    }

    var hasStoredHideEvidence: Bool {
        !hiddenSessionIDs.isEmpty || !unresolvedDurableLegacyKeys.isEmpty
    }

    /// Durable legacy keys retained as display fallback until a complete, unambiguous inventory.
    /// A partial inventory may already have contributed a permanent ID. Process keys never participate.
    var unresolvedDurableLegacyKeys: Set<String> {
        legacyStableKeys.filter(Self.isDurableLegacyKey)
    }

    func isHidden(_ session: Session) -> Bool {
        guard let cctopSessionID = session.cctopSessionId,
              Session.isValidCctopSessionId(cctopSessionID) else { return false }
        return hiddenSessionIDs.contains(cctopSessionID)
    }

    func hide(_ session: Session) {
        guard let cctopSessionID = session.cctopSessionId,
              Session.isValidCctopSessionId(cctopSessionID) else { return }
        var sessionIDs = hiddenSessionIDs
        sessionIDs.insert(cctopSessionID)
        save(sessionIDs)
    }

    /// Upgrade exact, unambiguous durable matches, but retire their fallback only after
    /// the persisted inventory confirms the same identity. Retain partial or ambiguous keys.
    /// Process-scoped `active:<pid>` keys are retired rather than rebound to a new process generation.
    @discardableResult
    func migrateLegacyStableKeys(
        using sessions: [Session],
        persistedSessions: [Session],
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

    private static func persistedLegacyMigrationMatches(
        in sessions: [Session],
        legacyKeys: Set<String>
    ) -> (
        sessionIDsByEvidence: [String: Set<String>],
        unresolvedEvidence: Set<String>,
        unresolvedMatchedKeys: Set<String>,
        sessionIDsByKey: [String: Set<String>]
    ) {
        var sessionIDsByEvidence: [String: Set<String>] = [:]
        var unresolvedEvidence: Set<String> = []
        var unresolvedMatchedKeys: Set<String> = []
        var sessionIDsByKey: [String: Set<String>] = [:]
        for session in sessions {
            let cctopSessionID = SessionIdentityPolicy.logicalIdentity(for: session).cctopSessionID
            if let evidence = CctopSessionIdentityStore.durableEvidence(
                source: session.source,
                harnessSessionId: session.harnessSessionId,
                legacySessionId: session.sessionId
            ) {
                if let cctopSessionID {
                    sessionIDsByEvidence[evidence, default: []].insert(cctopSessionID)
                } else {
                    unresolvedEvidence.insert(evidence)
                }
            }

            let key = SessionIdentityPolicy.stableKey(for: session)
            guard legacyKeys.contains(key) else { continue }
            if let cctopSessionID {
                sessionIDsByKey[key, default: []].insert(cctopSessionID)
            } else {
                unresolvedMatchedKeys.insert(key)
            }
        }
        return (sessionIDsByEvidence, unresolvedEvidence, unresolvedMatchedKeys, sessionIDsByKey)
    }

    private static func legacyMigrationCandidateIDs(
        for session: Session,
        persistedSessionIDsByEvidence: [String: Set<String>]
    ) -> Set<String> {
        var matches: Set<String> = []
        if let cctopSessionID = SessionIdentityPolicy.logicalIdentity(for: session).cctopSessionID {
            matches.insert(cctopSessionID)
        }
        if let evidence = CctopSessionIdentityStore.durableEvidence(
            source: session.source,
            harnessSessionId: session.harnessSessionId,
            legacySessionId: session.sessionId
        ) {
            matches.formUnion(persistedSessionIDsByEvidence[evidence] ?? [])
        }
        return matches
    }

    static func durableEvidence(forLegacyKey key: String) -> String? {
        let components = key.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let source: String
        switch components[0] {
        case "codex": source = Session.codexSource
        case "desktop": source = Session.ccSource
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
