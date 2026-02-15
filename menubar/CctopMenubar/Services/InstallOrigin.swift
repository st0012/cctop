import Foundation

enum InstallOrigin {
    /// Detect Homebrew cask install by checking if a Caskroom directory exists for cctop.
    /// Homebrew cask copies the .app to /Applications/ (not a symlink), so path-based
    /// detection on the bundle URL does not work. Instead, check for the Caskroom receipt.
    static func isHomebrewCask() -> Bool {
        let fm = FileManager.default
        let paths = ["/opt/homebrew/Caskroom/cctop", "/usr/local/Caskroom/cctop"]
        return paths.contains { fm.fileExists(atPath: $0) }
    }
}
