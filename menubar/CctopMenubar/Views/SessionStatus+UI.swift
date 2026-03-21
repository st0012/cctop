import SwiftUI

extension SessionStatus {
    var color: Color {
        switch self {
        case .waitingPermission: return Color.statusPermission
        case .waitingInput, .needsAttention: return Color.statusAttention
        case .working: return Color.statusGreen
        case .compacting:
            return Color(nsColor: NSColor(name: nil) { appearance in
                ThemeManager.shared.current.agentBadge.resolve(appearance)
            })
        case .idle:
            return Color(nsColor: NSColor(name: nil) { appearance in
                ThemeManager.shared.current.statusIdle.resolve(appearance)
            })
        }
    }

    var label: String {
        switch self {
        case .waitingPermission: return "PERMISSION"
        case .waitingInput, .needsAttention: return "WAITING"
        case .working: return "WORKING"
        case .compacting: return "COMPACTING"
        case .idle: return "IDLE"
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .waitingPermission: return "waiting for permission"
        case .waitingInput: return "waiting for input"
        case .needsAttention: return "needs attention"
        case .working: return "working"
        case .compacting: return "compacting context"
        case .idle: return "idle"
        }
    }
}
