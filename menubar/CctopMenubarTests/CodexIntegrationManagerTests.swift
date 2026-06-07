import XCTest
@testable import CctopMenubar

final class CodexIntegrationManagerTests: XCTestCase {
    func testSnapshotReportsUntrustedHooksAndPluginPackageStateSeparately() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: true,
            needsUpdate: false,
            configText: makeTrustedConfig(events: CodexPluginInstaller.trustStateEventKeys.dropLast()),
            pluginPackageInstalled: false
        ))

        XCTAssertEqual(snapshot.hookStatus, .installedUntrusted)
        XCTAssertTrue(snapshot.installed)
        XCTAssertFalse(snapshot.pluginPackageInstalled)
        XCTAssertFalse(snapshot.needsUpdate)
    }

    func testSnapshotReportsTrustedHooksWithInstalledPluginPackage() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: true,
            needsUpdate: false,
            configText: makeTrustedConfig(events: CodexPluginInstaller.trustStateEventKeys),
            pluginPackageInstalled: true
        ))

        XCTAssertEqual(snapshot.hookStatus, .trusted)
        XCTAssertTrue(snapshot.installed)
        XCTAssertTrue(snapshot.pluginPackageInstalled)
        XCTAssertFalse(snapshot.needsUpdate)
    }

    func testSnapshotTreatsPluginPackageAsInstalledWithoutLegacyHookFiles() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: false,
            featureEnabled: true,
            needsUpdate: false,
            configText: nil,
            pluginPackageInstalled: true
        ))

        XCTAssertEqual(snapshot.hookStatus, .installedUntrusted)
        XCTAssertTrue(snapshot.installed)
        XCTAssertTrue(snapshot.pluginPackageInstalled)
        XCTAssertFalse(snapshot.needsUpdate)
    }

    func testSnapshotTreatsRepairNeededStateAsNeedsUpdate() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: false,
            featureEnabled: true,
            needsUpdate: true,
            configText: nil,
            pluginPackageInstalled: false
        ))

        XCTAssertEqual(snapshot.hookStatus, .needsUpdate)
        XCTAssertTrue(snapshot.installed)
        XCTAssertFalse(snapshot.pluginPackageInstalled)
        XCTAssertTrue(snapshot.needsUpdate)
    }

    func testSnapshotRecognizesTrustedPluginBundledHookSource() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: false,
            featureEnabled: true,
            needsUpdate: false,
            configText: makeTrustedPluginConfig(events: CodexPluginInstaller.trustStateEventKeys),
            pluginPackageInstalled: true
        ))

        XCTAssertEqual(snapshot.hookStatus, .trusted)
        XCTAssertTrue(snapshot.installed)
        XCTAssertTrue(snapshot.pluginPackageInstalled)
    }

    func testSnapshotDoesNotLetPluginTrustSatisfyLegacyHookInstall() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: true,
            needsUpdate: false,
            configText: makeTrustedPluginConfig(events: CodexPluginInstaller.trustStateEventKeys),
            pluginPackageInstalled: false
        ))

        XCTAssertEqual(snapshot.hookStatus, .installedUntrusted)
        XCTAssertTrue(snapshot.installed)
        XCTAssertFalse(snapshot.pluginPackageInstalled)
    }

    func testSnapshotDoesNotLetLegacyTrustSatisfyPluginPackageInstall() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: false,
            featureEnabled: true,
            needsUpdate: false,
            configText: makeTrustedConfig(events: CodexPluginInstaller.trustStateEventKeys),
            pluginPackageInstalled: true
        ))

        XCTAssertEqual(snapshot.hookStatus, .installedUntrusted)
        XCTAssertTrue(snapshot.installed)
        XCTAssertTrue(snapshot.pluginPackageInstalled)
    }

    func testHookStatusClassifiesObservableStates() {
        let trustedConfig = makeTrustedConfig(events: CodexPluginInstaller.trustStateEventKeys)
        let partialConfig = makeTrustedConfig(events: CodexPluginInstaller.trustStateEventKeys.dropLast())

        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: false, featureEnabled: true, needsUpdate: false, configText: nil
            ),
            .notInstalled
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: false, featureEnabled: false, needsUpdate: false, configText: nil
            ),
            .hooksDisabled
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: true, needsUpdate: true, configText: trustedConfig
            ),
            .needsUpdate
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: false, needsUpdate: false, configText: trustedConfig
            ),
            .hooksDisabled
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: true, needsUpdate: false, configText: partialConfig
            ),
            .installedUntrusted
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: true, needsUpdate: false, configText: trustedConfig
            ),
            .trusted
        )
    }

    func testLegacyCodexConfigNeedsRepairTreatsLegacyConfigAsUpdate() {
        XCTAssertTrue(
            CodexIntegrationManager.legacyCodexConfigNeedsRepair(configText: "[features]\ncodex_hooks = true\n")
        )
    }

    func testCurrentSnapshotFlagsLegacyHookFilesForCleanupWhenPluginPackageIsInstalled() throws {
        try withTemporaryHome { home in
            try writeCodexConfig(
                """
                [marketplaces.cctop]
                source_type = "local"
                source = "\(home.path)/.cctop/codex-plugin-marketplace"

                [plugins."cctop@cctop"]
                enabled = true
                """,
                home: home
            )
            try writeInstalledCodexPluginFiles(home: home)
            try writeLegacyUserHookFiles(home: home)

            let snapshot = CodexIntegrationManager.currentSnapshot()

            XCTAssertTrue(snapshot.pluginPackageInstalled)
            XCTAssertTrue(snapshot.needsUpdate)
            XCTAssertEqual(snapshot.hookStatus, .needsUpdate)
        }
    }

    func testCurrentSnapshotFlagsLegacyPluginSelectorForMigration() throws {
        try withTemporaryHome { home in
            try writeCodexConfig(
                """
                [plugins."cctop-codex@personal"]
                enabled = true
                """,
                home: home
            )
            try writeInstalledCodexPluginFiles(home: home)

            let snapshot = CodexIntegrationManager.currentSnapshot()

            XCTAssertFalse(snapshot.pluginPackageInstalled)
            XCTAssertTrue(snapshot.needsUpdate)
            XCTAssertEqual(snapshot.hookStatus, .needsUpdate)
        }
    }

    private func makeTrustedConfig<S: Sequence>(events: S) -> String where S.Element == String {
        let hooksPath = CodexPluginInstaller.hooksJsonPath.path
        return events.enumerated().flatMap { index, event in
            [
                "[hooks.state.\"\(hooksPath):\(event):0:\(index)\"]",
                "trusted_hash = \"sha256:abc123\"",
            ]
        }.joined(separator: "\n")
    }

    private func makeTrustedPluginConfig<S: Sequence>(events: S) -> String where S.Element == String {
        let hooksPath = CodexPluginPackageInstaller.hooksJsonPath.path
        return events.enumerated().flatMap { index, event in
            [
                "[hooks.state.\"\(hooksPath):\(event):0:\(index)\"]",
                "trusted_hash = \"sha256:abc123\"",
            ]
        }.joined(separator: "\n")
    }

    private func withTemporaryHome(_ body: (URL) throws -> Void) throws {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cctop-codex-integration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("HOME", home.path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
            try? FileManager.default.removeItem(at: home)
        }
        try body(home)
    }

    private func writeCodexConfig(_ text: String, home: URL) throws {
        let config = home.appendingPathComponent(".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: config, atomically: true, encoding: .utf8)
    }

    private func writeInstalledCodexPluginFiles(home: URL) throws {
        let root = CodexPluginPackageInstaller.pluginInstallRoot
        if let bundled = CodexPluginPackageInstaller.bundledPluginURL() {
            try FileManager.default.createDirectory(at: root.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: bundled, to: root)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: root.appendingPathComponent("hooks/cctop-shim.sh").path
            )
            return
        }

        try writePluginFile("{}", relativePath: ".codex-plugin/plugin.json", root: root)
        try writePluginFile("{}", relativePath: "hooks/hooks.json", root: root)
        let shim = root.appendingPathComponent("hooks/cctop-shim.sh")
        try "#!/bin/sh\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    }

    private func writeLegacyUserHookFiles(home: URL) throws {
        let codexDir = home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codexDir, withIntermediateDirectories: true)
        let shim = codexDir.appendingPathComponent("cctop-shim.sh")
        try "#!/bin/sh\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        let hooksByEvent: [String: Any] = Dictionary(
            uniqueKeysWithValues: CodexPluginInstaller.registeredEvents.map { event in
                (
                    event,
                    [
                        [
                            "matcher": "",
                            "hooks": [
                                [
                                    "type": "command",
                                    "command": "\(shim.path) \(event)",
                                ],
                            ],
                        ],
                    ]
                )
            }
        )
        let data = try JSONSerialization.data(withJSONObject: ["hooks": hooksByEvent], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: codexDir.appendingPathComponent("hooks.json"), options: .atomic)
    }

    private func writePluginFile(_ contents: String, relativePath: String, root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }
}
