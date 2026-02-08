import SwiftUI

enum SessionStatus: String, Codable {
    case idle
    case working
    case waitingPermission = "waiting_permission"
    case waitingInput = "waiting_input"
    case needsAttention = "needs_attention"

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = SessionStatus(rawValue: raw) ?? .needsAttention
    }

    var needsAttention: Bool {
        switch self {
        case .waitingPermission, .waitingInput, .needsAttention: return true
        default: return false
        }
    }

    var color: Color {
        switch self {
        case .waitingPermission: return .red
        case .waitingInput, .needsAttention: return .orange
        case .working: return .green
        case .idle: return .gray
        }
    }

    var label: String {
        switch self {
        case .waitingPermission: return "PERMISSION"
        case .waitingInput, .needsAttention: return "WAITING"
        case .working: return "WORKING"
        case .idle: return "IDLE"
        }
    }

    var sortOrder: Int {
        switch self {
        case .waitingPermission: return 0
        case .waitingInput, .needsAttention: return 1
        case .working: return 2
        case .idle: return 3
        }
    }
}
