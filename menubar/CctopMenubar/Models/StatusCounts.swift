/// Aggregated session status counts used by the menubar icon, notch pill, and accessibility labels.
struct StatusCounts: Equatable {
    /// Semantic identity of a status-bar segment. Renderers resolve the
    /// theme color for a kind at render time (see `StatusColors.color(for:)`).
    enum SegmentKind: Equatable {
        case permission, attention, working, idle

        /// Whether this segment represents sessions needing user action.
        var needsAction: Bool { self == .permission || self == .attention }
    }

    let permission: Int
    let attention: Int
    let working: Int
    let idle: Int

    static let zero = StatusCounts(permission: 0, attention: 0, working: 0, idle: 0)

    init(permission: Int, attention: Int, working: Int, idle: Int) {
        self.permission = permission
        self.attention = attention
        self.working = working
        self.idle = idle
    }

    /// Create counts by aggregating session statuses.
    init(sessions: [Session]) {
        var perm = 0, attn = 0, work = 0, idleCount = 0
        // Only live (active) sessions drive the menubar badge. Dormant cards are reachable
        // history, not live work, so they never inflate counts or trigger the attention pill.
        for session in sessions where session.lifecycle == .active {
            switch session.status {
            case .idle: idleCount += 1
            case .working, .compacting: work += 1
            case .waitingPermission: perm += 1
            case .waitingInput, .needsAttention: attn += 1
            }
        }
        self.permission = perm
        self.attention = attn
        self.working = work
        self.idle = idleCount
    }

    var total: Int { permission + attention + working + idle }
    var needsAction: Int { permission + attention }

    /// Proportional bar segments: (fraction of total, semantic kind).
    /// Used by both MenubarIconRenderer (AppKit) and NotchStatusView (SwiftUI).
    var barSegments: [(proportion: Double, kind: SegmentKind)] {
        guard total > 0 else { return [] }
        var segs: [(Double, SegmentKind)] = []
        if permission > 0 {
            segs.append((Double(permission) / Double(total), .permission))
        }
        if attention > 0 {
            segs.append((Double(attention) / Double(total), .attention))
        }
        if working > 0 {
            segs.append((Double(working) / Double(total), .working))
        }
        if idle > 0 {
            segs.append((Double(idle) / Double(total), .idle))
        }
        return segs
    }

    /// Minimum width in points for action-needing segments (permission, attention).
    private static let minActionWidth: Double = 5

    /// Bar segments with minimum width enforcement for action-needing segments.
    /// Steals space proportionally from non-action segments (working, idle).
    func barSegments(forWidth barWidth: Double) -> [(proportion: Double, kind: SegmentKind)] {
        let raw = barSegments
        guard !raw.isEmpty, barWidth > 0 else { return raw }

        let minProportion = Self.minActionWidth / barWidth

        var deficit = 0.0
        var nonActionTotal = 0.0
        var totalActionClamped = 0.0
        for seg in raw {
            if seg.kind.needsAction {
                totalActionClamped += max(seg.proportion, minProportion)
                if seg.proportion < minProportion {
                    deficit += minProportion - seg.proportion
                }
            } else {
                nonActionTotal += seg.proportion
            }
        }

        guard deficit > 0, nonActionTotal > 0 else { return raw }

        // Safety: if clamped action segments would exceed 80% of bar, skip enforcement
        guard totalActionClamped <= 0.8 else { return raw }

        var result = raw.map { seg in
            if seg.kind.needsAction && seg.proportion < minProportion {
                return (minProportion, seg.kind)
            } else if !seg.kind.needsAction {
                let shrink = deficit * (seg.proportion / nonActionTotal)
                return (max(seg.proportion - shrink, 0), seg.kind)
            }
            return seg
        }

        // Normalize to exactly 1.0 to prevent floating-point accumulation drift
        let sum = result.map { $0.0 }.reduce(0, +)
        if sum > 0 && abs(sum - 1.0) > 1e-10 {
            result = result.map { ($0.0 / sum, $0.1) }
        }

        return result
    }

    /// Human-readable summary for VoiceOver / accessibility labels.
    var accessibilityLabel: String {
        guard total > 0 else { return "cctop, no sessions" }
        var parts: [String] = []
        if permission > 0 {
            parts.append("\(permission) \(permission == 1 ? "needs" : "need") permission")
        }
        if attention > 0 {
            parts.append("\(attention) \(attention == 1 ? "needs" : "need") attention")
        }
        if working > 0 { parts.append("\(working) working") }
        if idle > 0 { parts.append("\(idle) idle") }
        return "cctop, " + parts.joined(separator: ", ")
    }
}
