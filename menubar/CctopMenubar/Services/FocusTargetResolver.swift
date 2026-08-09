import Foundation

enum FocusTargetResolver {
    /// Resolve permanent identity through the canonical user-session projection.
    static func currentSession(
        forCctopSessionID cctopSessionID: String,
        in userSessions: [UserSession]
    ) -> SessionData? {
        guard CctopSessionID.isValid(cctopSessionID) else { return nil }
        return userSessions.first { $0.identity.cctopSessionID == cctopSessionID }?.focusTarget
    }

    /// Resolve panel/navigation identity through the canonical user-session projection.
    /// Permanent IDs use the canonical group; legacy identities remain unique or fail closed.
    static func currentSession(
        for identity: SessionIdentityPolicy.LogicalIdentity,
        in userSessions: [UserSession]
    ) -> SessionData? {
        if let cctopSessionID = identity.cctopSessionID {
            return currentSession(forCctopSessionID: cctopSessionID, in: userSessions)
        }

        guard case .legacy(let stableKey) = identity else { return nil }
        let matches = userSessions.filter { userSession in
            userSession.records.contains { record in
                SessionIdentityPolicy.stableKey(for: record.data) == stableKey
            }
        }
        guard matches.count == 1 else { return nil }
        return matches[0].focusTarget
    }
}
