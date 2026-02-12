import SwiftUI

extension SessionStatus {
    var color: Color {
        switch self {
        case .waitingPermission: return .red
        case .waitingInput, .needsAttention: return Color.amber
        case .working: return .green
        case .compacting: return .purple
        case .idle: return .gray
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
