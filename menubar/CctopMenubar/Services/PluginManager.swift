import Foundation
import os.log

private let logger = Logger(subsystem: "com.st0012.CctopMenubar", category: "PluginManager")

@MainActor
class PluginManager: ObservableObject {
    @Published var ccInstalled: Bool = false
    @Published var ocInstalled: Bool = false
    @Published var ocNeedsUpdate: Bool = false
    @Published var ocConfigExists: Bool = false
    @Published var piInstalled: Bool = false
    @Published var piConfigExists: Bool = false

    private static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let ocPluginPath = home.appendingPathComponent(
        ".config/opencode/plugins/cctop.js"
    )
    private static let piPluginPath = home.appendingPathComponent(
        ".pi/agent/extensions/cctop.ts"
    )

    init() {
        refresh()
    }

    func refresh() {
        let fm = FileManager.default
        let home = Self.home

        let ccDir = home.appendingPathComponent(".claude/plugins/cache/cctop")
        var isDir: ObjCBool = false
        ccInstalled = fm.fileExists(atPath: ccDir.path, isDirectory: &isDir)
            && isDir.boolValue

        let ocConfigDir = home.appendingPathComponent(".config/opencode")
        ocConfigExists = fm.fileExists(atPath: ocConfigDir.path)
        ocInstalled = fm.fileExists(atPath: Self.ocPluginPath.path)
        ocNeedsUpdate = ocInstalled && Self.installedPluginOutdated()

        let piConfigDir = home.appendingPathComponent(".pi")
        piConfigExists = fm.fileExists(atPath: piConfigDir.path)
        piInstalled = fm.fileExists(atPath: Self.piPluginPath.path)
    }

    private static func installedPluginOutdated() -> Bool {
        guard let bundledURL = Bundle.main.url(forResource: "opencode-plugin", withExtension: "js"),
              let bundledData = try? Data(contentsOf: bundledURL),
              let installedData = try? Data(contentsOf: ocPluginPath) else {
            return false
        }
        return bundledData != installedData
    }

    func installOpenCodePlugin() -> Bool {
        installBundledPlugin(
            resource: "opencode-plugin", ext: "js",
            destination: Self.ocPluginPath, name: "opencode"
        )
    }

    func removeOpenCodePlugin() -> Bool {
        removeBundledPlugin(path: Self.ocPluginPath, name: "opencode")
    }

    func installPiPlugin() -> Bool {
        installBundledPlugin(
            resource: "pi-plugin", ext: "ts",
            destination: Self.piPluginPath, name: "pi"
        )
    }

    func removePiPlugin() -> Bool {
        removeBundledPlugin(path: Self.piPluginPath, name: "pi")
    }

    // MARK: - Private

    private func installBundledPlugin(
        resource: String, ext: String, destination: URL, name: String
    ) -> Bool {
        defer { refresh() }

        guard let bundledPlugin = Bundle.main.url(
            forResource: resource, withExtension: ext
        ),
            let bundledData = try? Data(contentsOf: bundledPlugin)
        else {
            logger.error("Could not read bundled \(name) plugin")
            return false
        }

        let pluginsDir = destination.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(
                at: pluginsDir, withIntermediateDirectories: true
            )
            try bundledData.write(to: destination, options: .atomic)
            logger.info(
                "Installed \(name) plugin to \(destination.path, privacy: .public)"
            )
            return true
        } catch {
            logger.error(
                "Failed to install \(name) plugin: \(error, privacy: .public)"
            )
            return false
        }
    }

    private func removeBundledPlugin(path: URL, name: String) -> Bool {
        defer { refresh() }

        do {
            try FileManager.default.removeItem(at: path)
            logger.info(
                "Removed \(name) plugin from \(path.path, privacy: .public)"
            )
            return true
        } catch {
            logger.error(
                "Failed to remove \(name) plugin: \(error, privacy: .public)"
            )
            return false
        }
    }
}
