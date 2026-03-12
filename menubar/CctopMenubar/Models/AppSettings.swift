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
    // Storage key is "refocus" (the old name) for backward compatibility with existing user shortcuts.
    static let navigate = Self("refocus", default: .init(.n, modifiers: [.control, .command]))
}
