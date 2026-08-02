import XCTest
@testable import CctopMenubar

@MainActor
final class PluginManagerStreamDeckTests: XCTestCase {
    func testDetectsStreamDeckAndItsInstalledPlugin() throws {
        let home = makeTempDirectory()
        let manager = withTemporaryHomeDirectory(home) { PluginManager(homeDirectory: home) }
        XCTAssertFalse(manager.sdConfigExists)

        let support = home.appendingPathComponent(
            "Library/Application Support/com.elgato.StreamDeck"
        )
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        withTemporaryHomeDirectory(home) { manager.refresh() }
        XCTAssertTrue(manager.sdConfigExists)
        XCTAssertFalse(manager.sdInstalled)

        let plugin = support.appendingPathComponent("Plugins/\(PluginManager.sdPluginDirName)")
        try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
        try Data(#"{"Version":"0.19.5.0"}"#.utf8)
            .write(to: plugin.appendingPathComponent("manifest.json"))
        withTemporaryHomeDirectory(home) { manager.refresh() }

        XCTAssertTrue(manager.sdInstalled)
    }

    func testBundleComparisonRepairsSameVersionDifferentOrMissingRuntime() throws {
        let directory = makeTempDirectory()
        let bundled = directory.appendingPathComponent("bundled.sdPlugin")
        let installed = directory.appendingPathComponent("installed.sdPlugin")
        for plugin in [bundled, installed] {
            try FileManager.default.createDirectory(
                at: plugin.appendingPathComponent("bin"),
                withIntermediateDirectories: true
            )
            try Data(#"{"Version":"0.19.5.0","CodePath":"bin/plugin.mjs"}"#.utf8)
                .write(to: plugin.appendingPathComponent("manifest.json"))
        }
        try Data("current runtime".utf8).write(to: bundled.appendingPathComponent("bin/plugin.mjs"))
        try Data("broken old runtime".utf8).write(to: installed.appendingPathComponent("bin/plugin.mjs"))

        XCTAssertTrue(PluginManager.streamDeckInstallOutdated(
            bundledDirectory: bundled,
            installedDirectory: installed
        ))
        try Data("current runtime".utf8).write(to: installed.appendingPathComponent("bin/plugin.mjs"))
        try Data("Stream Deck-owned cache".utf8).write(to: installed.appendingPathComponent("runtime-cache"))
        XCTAssertFalse(PluginManager.streamDeckInstallOutdated(
            bundledDirectory: bundled,
            installedDirectory: installed
        ))
        try FileManager.default.removeItem(at: installed.appendingPathComponent("bin/plugin.mjs"))
        XCTAssertTrue(PluginManager.streamDeckInstallOutdated(
            bundledDirectory: bundled,
            installedDirectory: installed
        ))
    }

    func testDirectoryReplacementChangesOnlyCctopPlugin() throws {
        let directory = makeTempDirectory()
        let source = directory.appendingPathComponent("source.sdPlugin")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        try Data("new".utf8).write(to: source.appendingPathComponent("manifest.json"))
        try Data("code".utf8).write(to: source.appendingPathComponent("bin/plugin.mjs"))

        let plugins = directory.appendingPathComponent("Plugins")
        let destination = plugins.appendingPathComponent(PluginManager.sdPluginDirName)
        let unrelated = plugins.appendingPathComponent("com.example.unrelated.sdPlugin")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("manifest.json"))
        try Data("keep".utf8).write(to: unrelated.appendingPathComponent("manifest.json"))

        try PluginManager.replaceDirectory(at: destination, with: source)

        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("manifest.json"), encoding: .utf8),
            "new"
        )
        XCTAssertEqual(
            try String(contentsOf: unrelated.appendingPathComponent("manifest.json"), encoding: .utf8),
            "keep"
        )
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: plugins.path)
            .filter { $0.contains(".staging-") || $0.contains(".backup-") }
        XCTAssertEqual(leftovers, [])
    }

    func testFailedStagingLeavesExistingInstallUntouched() throws {
        let directory = makeTempDirectory()
        let destination = directory.appendingPathComponent("Plugins/\(PluginManager.sdPluginDirName)")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: destination.appendingPathComponent("manifest.json"))

        XCTAssertThrowsError(try PluginManager.replaceDirectory(
            at: destination,
            with: directory.appendingPathComponent("missing.sdPlugin")
        ))
        XCTAssertEqual(
            try String(contentsOf: destination.appendingPathComponent("manifest.json"), encoding: .utf8),
            "old"
        )
    }

    private func makeTempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-streamdeck-manager-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
