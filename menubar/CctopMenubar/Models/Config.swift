import Foundation

enum Config {
    static func sessionsDir() -> String {
        if let override = ProcessInfo.processInfo.environment["CCTOP_SESSIONS_DIR"],
           !override.isEmpty {
            ensureDirectoryExists(override)
            return override
        }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = (home as NSString).appendingPathComponent(".cctop/sessions")
        ensureDirectoryExists(dir)
        return dir
    }

    private static func ensureDirectoryExists(_ path: String) {
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            try? fm.createDirectory(
                atPath: path, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }
}
