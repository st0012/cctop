import Combine
import Foundation
import SwiftUI

class CompactModeController: ObservableObject {
    @AppStorage("compactMode") var compactMode = false {
        didSet { objectWillChange.send() }
    }
    @Published var isExpanded = false

    /// Whether the panel should show compact (header-only) content.
    var isCompact: Bool { compactMode && !isExpanded }

    /// Sync only the visual expansion state from a `PanelMode`.
    /// The `compactMode` preference is set separately by `handleEvent`.
    func syncVisualState(_ mode: PanelMode) {
        let newExpanded: Bool = {
            switch mode {
            case .compactExpanded:
                return true
            case .refocus(let origin) where origin.wasCompact:
                return true
            default:
                return false
            }
        }()
        isExpanded = newExpanded
    }
}
