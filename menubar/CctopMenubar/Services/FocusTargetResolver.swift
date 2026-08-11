import Foundation

enum FocusTargetResolver {
    /// Resolve permanent identity through the canonical user-session projection.
    static func currentUserSession(
        forCctopSessionID cctopSessionID: String,
        in userSessions: [UserSession]
    ) -> UserSession? {
        guard CctopSessionID.isValid(cctopSessionID) else { return nil }
        return userSessions.first { $0.identity.cctopSessionID == cctopSessionID }
    }

    /// Resolve panel/navigation identity through the canonical user-session projection.
    /// Permanent IDs use the canonical group; legacy identities remain unique or fail closed.
    static func currentUserSession(
        for identity: SessionIdentityPolicy.LogicalIdentity,
        in userSessions: [UserSession]
    ) -> UserSession? {
        if let cctopSessionID = identity.cctopSessionID {
            return currentUserSession(forCctopSessionID: cctopSessionID, in: userSessions)
        }

        guard case .legacy(let stableKey) = identity else { return nil }
        let matches = userSessions.filter { userSession in
            userSession.records.contains { record in
                SessionIdentityPolicy.stableKey(for: record.data) == stableKey
            }
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }
}
