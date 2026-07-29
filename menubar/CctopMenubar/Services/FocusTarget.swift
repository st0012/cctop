import Foundation

/// One concrete session observation selected for focus. This is runtime-facing
/// metadata, not the permanent identity of the logical conversation.
struct FocusTarget {
    let observation: Session
}

enum FocusTargetResolver {
    /// A visible row already identifies the exact observation the user selected.
    static func exactObservation(_ observation: Session) -> FocusTarget {
        FocusTarget(observation: observation)
    }

    /// Resolve a permanent logical id only when it names one current canonical observation.
    /// The caller remains responsible for lifecycle filtering and canonical ordering.
    static func currentTarget(forCctopSessionID cctopSessionID: String, in observations: [Session]) -> FocusTarget? {
        guard Session.isValidCctopSessionId(cctopSessionID) else { return nil }

        var resolved: FocusTarget?
        for observation in observations where observation.cctopSessionId == cctopSessionID {
            guard resolved == nil else { return nil }
            resolved = FocusTarget(observation: observation)
        }
        return resolved
    }
}
