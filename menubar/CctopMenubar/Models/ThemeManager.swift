import Foundation
import Combine

@MainActor
class ThemeManager: ObservableObject {
    static let shared = ThemeManager()

    @Published private(set) var current: AppTheme

    init() {
        let saved = UserDefaults.standard.string(forKey: "colorTheme") ?? "claude"
        self.current = AppTheme(rawValue: saved) ?? .claude
    }

    var themeId: String { current.rawValue }

    func setTheme(_ theme: AppTheme) {
        current = theme
        UserDefaults.standard.set(theme.rawValue, forKey: "colorTheme")
    }
}
