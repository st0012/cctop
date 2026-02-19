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

    func syncVisualState(_ mode: PanelMode) {
        switch mode {
        case .compactExpanded:
            isExpanded = true
        case .refocus(let origin) where origin.wasCompact:
            isExpanded = true
        default:
            isExpanded = false
        }
    }
}
