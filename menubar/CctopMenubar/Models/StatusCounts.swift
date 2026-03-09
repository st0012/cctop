/// Aggregated session status counts used by the menubar icon, notch pill, and accessibility labels.
struct StatusCounts: Equatable {
    let permission: Int
    let attention: Int
    let working: Int
    let idle: Int

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
