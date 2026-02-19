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

    /// Toggle between compact and normal mode. Persisted via @AppStorage.
    func toggle() {
        compactMode.toggle()
        isExpanded = false
    }

    /// Temporarily expand the compact panel to show full content.
    func expand() {
        guard compactMode, !isExpanded else { return }
        isExpanded = true
    }

    /// Collapse back to compact (if compact mode is on and currently expanded).
    func collapse() {
        guard compactMode, isExpanded else { return }
        isExpanded = false
    }
}
