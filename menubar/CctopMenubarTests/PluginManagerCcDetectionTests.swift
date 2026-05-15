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
