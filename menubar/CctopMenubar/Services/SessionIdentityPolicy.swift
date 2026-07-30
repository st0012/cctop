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

    static func notificationRequestIdentifier(for session: Session) -> String {
        "session-\(stableKey(for: session))"
    }

    static func notificationUserInfo(for session: Session) -> [AnyHashable: Any] {
        var userInfo: [AnyHashable: Any] = [
            notificationSessionIDKey: notificationSessionID(for: session),
            notificationSessionPIDKey: session.pid.map(String.init) ?? "",
        ]
        if let cctopSessionID = session.cctopSessionId,
           Session.isValidCctopSessionId(cctopSessionID) {
            userInfo[notificationCctopSessionIDKey] = cctopSessionID
        }
        return userInfo
    }

    static func cctopSessionID(matchingNotificationUserInfo userInfo: [AnyHashable: Any]) -> String? {
        guard let cctopSessionID = nonEmptyString(userInfo[notificationCctopSessionIDKey]),
              Session.isValidCctopSessionId(cctopSessionID) else { return nil }
        return cctopSessionID
    }

    static func session(
        matchingNotificationUserInfo userInfo: [AnyHashable: Any],
        in sessions: [Session]
    ) -> Session? {
        if let sessionID = nonEmptyString(userInfo[notificationSessionIDKey]) {
            if let match = sessions.first(where: { notificationSessionID(for: $0) == sessionID }) {
                return match
            }
            return sessions.first { $0.id == sessionID }
        }

        guard let pid = nonEmptyString(userInfo[notificationSessionPIDKey]) else { return nil }
        return sessions.first {
            $0.id == pid || $0.pid.map(String.init) == pid
        }
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

    /// Upgrade exact, unambiguous durable matches and retain partial or ambiguous keys as fallback.
    /// Process-scoped `active:<pid>` keys are retired rather than rebound to a new process generation.
    @discardableResult
    func migrateLegacyStableKeys(using sessions: [Session], inventoryComplete: Bool) -> Set<String> {
        let legacyKeys = legacyStableKeys
        guard !legacyKeys.isEmpty else { return hiddenSessionIDs }

        var unresolvedMatchedKeys: Set<String> = []
        var sessionIDsByKey: [String: Set<String>] = [:]
        for session in sessions {
            let key = SessionIdentityPolicy.stableKey(for: session)
            guard legacyKeys.contains(key) else { continue }
            if let cctopSessionID = SessionIdentityPolicy.logicalIdentity(for: session).cctopSessionID {
                sessionIDsByKey[key, default: []].insert(cctopSessionID)
            } else {
                unresolvedMatchedKeys.insert(key)
            }
        }

        var migratedSessionIDs = hiddenSessionIDs
        var remainingLegacyKeys = legacyKeys
        for key in legacyKeys.sorted() {
            guard Self.isDurableLegacyKey(key) else {
                if inventoryComplete { remainingLegacyKeys.remove(key) }
                continue
            }

            let matches = sessionIDsByKey[key] ?? []
            let isUnambiguous = matches.count == 1 && !unresolvedMatchedKeys.contains(key)
            if isUnambiguous, let match = matches.first {
                migratedSessionIDs.insert(match)
            }
            let isProvenMissing = matches.isEmpty && !unresolvedMatchedKeys.contains(key)
            if inventoryComplete && (isUnambiguous || isProvenMissing) {
                remainingLegacyKeys.remove(key)
            }
        }

        if migratedSessionIDs != hiddenSessionIDs { save(migratedSessionIDs) }
        saveLegacy(remainingLegacyKeys)
        return migratedSessionIDs
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
