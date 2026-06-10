import XCTest
@testable import CctopMenubar

final class PluginManagerCcDetectionTests: XCTestCase {

    func testReturnsFalseWhenCacheDirMissing() {
        let dir = makeTempDir().appendingPathComponent("missing")
        XCTAssertFalse(PluginManager.hasActiveClaudeCodePluginVersion(in: dir))
    }

    func testReturnsFalseWhenCacheDirEmpty() {
        let dir = makeTempDir()
        XCTAssertFalse(PluginManager.hasActiveClaudeCodePluginVersion(in: dir))
    }

    func testReturnsFalseWhenOnlyOrphanedVersion() throws {
        let dir = makeTempDir()
        try makeVersion(in: dir, name: "0.11.0", orphaned: true, manifest: true)
        XCTAssertFalse(PluginManager.hasActiveClaudeCodePluginVersion(in: dir))
    }

    func testReturnsFalseWhenVersionMissingManifest() throws {
        let dir = makeTempDir()
        try makeVersion(in: dir, name: "0.11.0", orphaned: false, manifest: false)
        XCTAssertFalse(PluginManager.hasActiveClaudeCodePluginVersion(in: dir))
    }

    func testReturnsTrueForActiveVersion() throws {
        let dir = makeTempDir()
        try makeVersion(in: dir, name: "0.15.3", orphaned: false, manifest: true)
        XCTAssertTrue(PluginManager.hasActiveClaudeCodePluginVersion(in: dir))
    }

    func testReturnsTrueWhenMixedOrphanedAndActive() throws {
        let dir = makeTempDir()
        try makeVersion(in: dir, name: "0.11.0", orphaned: true, manifest: true)
        try makeVersion(in: dir, name: "0.15.3", orphaned: false, manifest: true)
        XCTAssertTrue(PluginManager.hasActiveClaudeCodePluginVersion(in: dir))
    }

    // MARK: - Helpers

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-cc-detect-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func makeVersion(
        in baseDir: URL, name: String, orphaned: Bool, manifest: Bool
    ) throws {
        let versionDir = baseDir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: versionDir, withIntermediateDirectories: true
        )
        if manifest {
            let manifestURL = versionDir.appendingPathComponent(PluginManager.ccPluginManifestPath)
            try FileManager.default.createDirectory(
                at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "{}".write(to: manifestURL, atomically: true, encoding: .utf8)
        }
        if orphaned {
            try "2026-05-15T00:00:00Z".write(
                to: versionDir.appendingPathComponent(PluginManager.ccOrphanedMarker),
                atomically: true, encoding: .utf8
            )
        }
    }
}

/// Integration coverage for `refresh()` against a staged home directory.
/// Only the oc/pi/cc flags are asserted: Codex detection reads `~/.codex`
/// through `CodexPluginInstaller`, which is not derived from the injected
/// home directory.
@MainActor
final class PluginManagerRefreshTests: XCTestCase {

    func testRefreshDetectsPluginsInStagedHomeDirectory() throws {
        let home = makeTempHome()
        try stage(home, file: ".config/opencode/plugins/cctop.js", contents: "// plugin")
        try stage(home, file: ".pi/agent/extensions/cctop.ts", contents: "// extension")
        try stage(
            home,
            file: ".claude/plugins/cache/cctop/cctop/0.15.3/\(PluginManager.ccPluginManifestPath)",
            contents: "{}"
        )

        let manager = PluginManager(homeDirectory: home)

        XCTAssertTrue(manager.ccInstalled)
        XCTAssertTrue(manager.ocConfigExists)
        XCTAssertTrue(manager.ocInstalled)
        XCTAssertTrue(manager.piConfigExists)
        XCTAssertTrue(manager.piInstalled)
    }

    func testRefreshAgainstEmptyHomeReportsNothingInstalled() {
        let manager = PluginManager(homeDirectory: makeTempHome())

        XCTAssertFalse(manager.ccInstalled)
        XCTAssertFalse(manager.ocConfigExists)
        XCTAssertFalse(manager.ocInstalled)
        XCTAssertFalse(manager.ocNeedsUpdate)
        XCTAssertFalse(manager.piConfigExists)
        XCTAssertFalse(manager.piInstalled)
    }

    func testInertManagerStartsWithAllFlagsFalse() {
        // The preview/snapshot construction: no refresh, no home-dir IO, so
        // every published flag starts deterministically false regardless of
        // what is installed on the machine running the tests.
        let manager = PluginManager(
            homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false
        )

        XCTAssertFalse(manager.ccInstalled)
        XCTAssertFalse(manager.ocInstalled)
        XCTAssertFalse(manager.ocNeedsUpdate)
        XCTAssertFalse(manager.ocConfigExists)
        XCTAssertFalse(manager.piInstalled)
        XCTAssertFalse(manager.piConfigExists)
        XCTAssertFalse(manager.codexInstalled)
        XCTAssertFalse(manager.codexNeedsUpdate)
        XCTAssertFalse(manager.codexConfigExists)
        XCTAssertFalse(manager.codexLegacyConfigKey)
        XCTAssertEqual(manager.codexHookStatus, .notInstalled)
    }

    // MARK: - Helpers

    private func makeTempHome() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cctop-home-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func stage(_ home: URL, file relativePath: String, contents: String) throws {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
