import Foundation

/// One user-visible work session formed from one or more related `SessionRecord` values.
/// A stable-key winner establishes identity. Older related records remain as evidence.
struct UserSession {
    let identity: SessionIdentityPolicy.LogicalIdentity
    let records: [SessionRecord]
    let displayRecord: SessionRecord

    /// Indirect actions currently follow the same canonical record as the panel.
    /// Direct row actions continue to use the exact row session they received.
    var focusTarget: SessionData { displayRecord.data }

    func replacingDisplayData(_ data: SessionData) -> UserSession {
        UserSession(
            identity: identity,
            records: records,
            displayRecord: displayRecord.replacingData(data)
        )
    }

    /// Preserve stable-key dedup before grouping permanent logical identity. The identified
    /// winner still controls each stable-key group. All retained records stay available for
    /// later routing decisions.
    static func grouping(
        winners: [SessionRecord],
        records: [SessionRecord]
    ) -> [UserSession] {
        let recordsByStableKey = Dictionary(grouping: records) {
            SessionIdentityPolicy.stableKey(for: $0.data)
        }
        var result: [UserSession] = []
        var indexByIdentity: [SessionIdentityPolicy.LogicalIdentity: Int] = [:]

        for winner in winners {
            let stableKey = SessionIdentityPolicy.stableKey(for: winner.data)
            let groupedRecords = (recordsByStableKey[stableKey] ?? [winner]).map {
                $0.path == winner.path ? winner : $0
            }
            let identity = SessionIdentityPolicy.logicalIdentity(for: winner.data)

            if let index = indexByIdentity[identity] {
                let current = result[index]
                let display = SessionLifecyclePolicy.prefers(winner, over: current.displayRecord)
                    ? winner
                    : current.displayRecord
                result[index] = UserSession(
                    identity: identity,
                    records: current.records + groupedRecords,
                    displayRecord: display
                )
            } else {
                indexByIdentity[identity] = result.count
                result.append(UserSession(
                    identity: identity,
                    records: groupedRecords,
                    displayRecord: winner
                ))
            }
        }
        return result
    }
}
