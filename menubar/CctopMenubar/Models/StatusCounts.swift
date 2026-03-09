/// Aggregated session status counts used by the menubar icon, notch pill, and accessibility labels.
struct StatusCounts: Equatable {
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
        for session in sessions {
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

    /// Proportional bar segments: (fraction of total, color).
    /// Used by both MenubarIconRenderer (AppKit) and NotchStatusView (SwiftUI).
    var barSegments: [(proportion: Double, color: StatusColors.RGBColor)] {
        guard total > 0 else { return [] }
        var segs: [(Double, StatusColors.RGBColor)] = []
        if permission > 0 {
            segs.append((Double(permission) / Double(total), StatusColors.permission))
        }
        if attention > 0 {
            segs.append((Double(attention) / Double(total), StatusColors.attention))
        }
        if working > 0 {
            segs.append((Double(working) / Double(total), StatusColors.working))
        }
        if idle > 0 {
            segs.append((Double(idle) / Double(total), StatusColors.idle))
        }
        return segs
    }

    /// Minimum width in points for action-needing segments (permission, attention).
    private static let minActionWidth: Double = 5
    private static let actionColors: Set<StatusColors.RGBColor> = [
        StatusColors.permission, StatusColors.attention,
    ]

    /// Bar segments with minimum width enforcement for action-needing segments.
    /// Steals space proportionally from non-action segments (working, idle).
    func barSegments(forWidth barWidth: Double) -> [(proportion: Double, color: StatusColors.RGBColor)] {
        let raw = barSegments
        guard !raw.isEmpty, barWidth > 0 else { return raw }

        let minProportion = Self.minActionWidth / barWidth

        var deficit = 0.0
        var nonActionTotal = 0.0
        var totalActionClamped = 0.0
        for seg in raw {
            if Self.actionColors.contains(seg.color) {
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
            if Self.actionColors.contains(seg.color) && seg.proportion < minProportion {
                return (minProportion, seg.color)
            } else if !Self.actionColors.contains(seg.color) {
                let shrink = deficit * (seg.proportion / nonActionTotal)
                return (max(seg.proportion - shrink, 0), seg.color)
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
