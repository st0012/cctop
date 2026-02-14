import Foundation
import os.log

private let logger = Logger(subsystem: "com.st0012.CctopMenubar", category: "PluginManager")

@MainActor
class PluginManager: ObservableObject {
    @Published var ccInstalled: Bool = false
    @Published var ocInstalled: Bool = false
    @Published var ocConfigExists: Bool = false

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let ccDir = home.appendingPathComponent(".claude/plugins/cache/cctop")
        var isDir: ObjCBool = false
        ccInstalled = fm.fileExists(atPath: ccDir.path, isDirectory: &isDir) && isDir.boolValue

        let ocConfigDir = home.appendingPathComponent(".config/opencode")
        ocConfigExists = fm.fileExists(atPath: ocConfigDir.path)

        let ocPlugin = home.appendingPathComponent(".config/opencode/plugins/cctop.js")
        ocInstalled = fm.fileExists(atPath: ocPlugin.path)
    }

    func installOpenCodePlugin() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        guard let bundledPlugin = Bundle.main.url(forResource: "opencode-plugin", withExtension: "js"),
              let bundledData = try? Data(contentsOf: bundledPlugin) else {
            logger.error("Could not read bundled opencode plugin")
            return false
        }

        let pluginsDir = home.appendingPathComponent(".config/opencode/plugins")
        let destPath = pluginsDir.appendingPathComponent("cctop.js")

        do {
            try fm.createDirectory(at: pluginsDir, withIntermediateDirectories: true)
            try bundledData.write(to: destPath, options: .atomic)
            logger.info("Installed opencode plugin to \(destPath.path, privacy: .public)")
            refresh()
            return true
        } catch {
            logger.error("Failed to install opencode plugin: \(error, privacy: .public)")
            refresh()
            return false
        }
    }

    func removeOpenCodePlugin() -> Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let destPath = home.appendingPathComponent(".config/opencode/plugins/cctop.js")

        do {
            try fm.removeItem(at: destPath)
            logger.info("Removed opencode plugin from \(destPath.path, privacy: .public)")
            refresh()
            return true
        } catch {
            logger.error("Failed to remove opencode plugin: \(error, privacy: .public)")
            refresh()
            return false
        }
    }
}
