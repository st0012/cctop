import KeyboardShortcuts

enum AppearanceMode: String, CaseIterable {
    case system, light, dark
    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel")
    static let refocus = Self("refocus")
}
