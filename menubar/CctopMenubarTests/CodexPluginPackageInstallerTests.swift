import XCTest
@testable import CctopMenubar

final class CodexPluginPackageInstallerTests: XCTestCase {
    func testUsesCctopMarketplaceIdentity() {
        XCTAssertEqual(CodexPluginPackageInstaller.pluginName, "cctop")
        XCTAssertEqual(CodexPluginPackageInstaller.marketplaceName, "cctop")
        XCTAssertEqual(CodexPluginPackageInstaller.pluginSelector, "cctop@cctop")
    }

    func testCurrentInstalledConfigEntryRequiresCurrentSelector() {
        let config = """
        [plugins."cctop@personal"]
        enabled = true
        """
        XCTAssertFalse(CodexPluginPackageInstaller.hasCurrentInstalledConfigEntry(configText: config))
        XCTAssertTrue(CodexPluginPackageInstaller.hasLegacyInstalledConfigEntry(configText: config))
    }

    func testCurrentInstalledConfigEntryAcceptsCurrentSelector() {
        let config = """
        [plugins."cctop@cctop"]
        enabled = true
        """
        XCTAssertTrue(CodexPluginPackageInstaller.hasCurrentInstalledConfigEntry(configText: config))
    }

    func testRejectsDisabledPluginConfigEntry() {
        let config = """
        [plugins."cctop@cctop"]
        enabled = false
        """
        XCTAssertFalse(CodexPluginPackageInstaller.hasCurrentInstalledConfigEntry(configText: config))
    }

    func testCurrentInstalledConfigEntryRejectsLegacyCodexPluginSelector() {
        let config = """
        [plugins."cctop-codex@personal"]
        enabled = true
        """
        XCTAssertFalse(CodexPluginPackageInstaller.hasCurrentInstalledConfigEntry(configText: config))
        XCTAssertTrue(CodexPluginPackageInstaller.hasLegacyInstalledConfigEntry(configText: config))
    }

    func testCurrentInstalledConfigEntryRejectsEnabledLegacyPluginSelectors() {
        let config = """
        [plugins."cctop@personal"]
        enabled = true

        [plugins."cctop-codex@personal"]
        enabled = false
        """
        XCTAssertFalse(CodexPluginPackageInstaller.hasCurrentInstalledConfigEntry(configText: config))
        XCTAssertTrue(CodexPluginPackageInstaller.hasLegacyInstalledConfigEntry(configText: config))
    }

    func testDisabledCurrentConfigDoesNotCountAsCurrentInstallEvenWithLegacyEntry() {
        let config = """
        [plugins."cctop@cctop"]
        enabled = false

        [plugins."cctop-codex@personal"]
        enabled = true
        """
        XCTAssertFalse(CodexPluginPackageInstaller.hasCurrentInstalledConfigEntry(configText: config))
        XCTAssertTrue(CodexPluginPackageInstaller.hasLegacyInstalledConfigEntry(configText: config))
    }

    func testRejectsDifferentMarketplace() {
        let config = """
        [plugins."cctop@other"]
        enabled = true
        """
        XCTAssertFalse(CodexPluginPackageInstaller.hasCurrentOrLegacyInstalledConfigEntry(configText: config))
    }

    func testRejectsDisabledTargetPluginEvenWhenAnotherPluginIsEnabled() {
        let config = """
        [plugins."cctop@cctop"]
        enabled = false

        [plugins."other@personal"]
        enabled = true
        """
        XCTAssertFalse(CodexPluginPackageInstaller.hasCurrentOrLegacyInstalledConfigEntry(configText: config))
    }

    func testCurrentMarketplaceConfigEntryRequiresAppOwnedSource() {
        let config = """
        [marketplaces.cctop]
        source_type = "local"
        source = "\(CodexPluginPackageInstaller.marketplaceRoot.path)"
        """

        XCTAssertTrue(CodexPluginPackageInstaller.hasCurrentMarketplaceConfigEntry(configText: config))
        XCTAssertFalse(CodexPluginPackageInstaller.hasCurrentMarketplaceConfigEntry(configText: "[marketplaces.cctop]\nsource = \"/tmp/other\""))
    }

    func testInstallationSnapshotReportsLegacySelectorAsRepairNeeded() {
        let config = """
        [plugins."cctop-codex@personal"]
        enabled = true
        """

        let snapshot = CodexPluginPackageInstaller.installationSnapshot(configText: config)

        XCTAssertFalse(snapshot.installed)
        XCTAssertTrue(snapshot.needsUpdate)
    }

    func testInstallationSnapshotRequiresMarketplaceConfigEntry() throws {
        try withTemporaryHomeAndPath { home in
            try writeInstalledCodexPluginFiles(home: home)
            try writeCodexConfig(
                """
                [plugins."cctop@cctop"]
                enabled = true
                """,
                home: home
            )
            let config = try String(contentsOf: CodexPluginInstaller.configTomlPath, encoding: .utf8)

            let snapshot = CodexPluginPackageInstaller.installationSnapshot(configText: config)

            XCTAssertFalse(snapshot.installed)
            XCTAssertTrue(snapshot.needsUpdate)
        }
    }

    func testMergedMarketplacePreservesExistingPluginAndAddsCctop() throws {
        let existing = """
        {
          "name": "cctop",
          "interface": {
            "displayName": "My Tools"
          },
          "plugins": [
            {
              "name": "other-plugin",
              "source": {
                "source": "local",
                "path": "./plugins/other-plugin"
              },
              "policy": {
                "installation": "AVAILABLE",
                "authentication": "ON_INSTALL"
              },
              "category": "Productivity"
            }
          ]
        }
        """

        let payload = try parseMarketplace(
            CodexPluginPackageInstaller.mergedMarketplacePayload(existingData: Data(existing.utf8))
        )

        let interface = try XCTUnwrap(payload["interface"] as? [String: Any])
        XCTAssertEqual(interface["displayName"] as? String, "cctop")
        XCTAssertEqual(payload["name"] as? String, "cctop")
        let plugins = try XCTUnwrap(payload["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.compactMap { $0["name"] as? String }, ["other-plugin", "cctop"])
    }

    func testMergedMarketplaceReplacesExistingCctopEntry() throws {
        let existing = """
        {
          "name": "cctop",
          "plugins": [
            {
              "name": "cctop",
              "source": {
                "source": "local",
                "path": "./stale"
              }
            }
          ]
        }
        """

        let payload = try parseMarketplace(
            CodexPluginPackageInstaller.mergedMarketplacePayload(existingData: Data(existing.utf8))
        )

        let plugins = try XCTUnwrap(payload["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.count, 1)
        let source = try XCTUnwrap(plugins[0]["source"] as? [String: Any])
        XCTAssertEqual(source["path"] as? String, "./plugins/cctop-codex")
    }

    func testMergedMarketplaceMigratesLegacyCctopCodexEntry() throws {
        let existing = """
        {
          "name": "cctop",
          "plugins": [
            {
              "name": "cctop-codex",
              "source": {
                "source": "local",
                "path": "./plugins/cctop-codex"
              }
            }
          ]
        }
        """

        let payload = try parseMarketplace(
            CodexPluginPackageInstaller.mergedMarketplacePayload(existingData: Data(existing.utf8))
        )

        let plugins = try XCTUnwrap(payload["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.compactMap { $0["name"] as? String }, ["cctop"])
    }

    func testMergedMarketplaceDeduplicatesCurrentAndLegacyCctopEntries() throws {
        let existing = """
        {
          "name": "cctop",
          "plugins": [
            {
              "name": "cctop-codex",
              "source": {
                "source": "local",
                "path": "./legacy"
              }
            },
            {
              "name": "other-plugin",
              "source": {
                "source": "local",
                "path": "./plugins/other-plugin"
              }
            },
            {
              "name": "cctop",
              "source": {
                "source": "local",
                "path": "./stale"
              }
            }
          ]
        }
        """

        let payload = try parseMarketplace(
            CodexPluginPackageInstaller.mergedMarketplacePayload(existingData: Data(existing.utf8))
        )

        let plugins = try XCTUnwrap(payload["plugins"] as? [[String: Any]])
        XCTAssertEqual(plugins.compactMap { $0["name"] as? String }, ["cctop", "other-plugin"])
        let cctop = try XCTUnwrap(plugins.first)
        let source = try XCTUnwrap(cctop["source"] as? [String: Any])
        XCTAssertEqual(source["path"] as? String, "./plugins/cctop-codex")
    }

    func testMergedMarketplaceRejectsDifferentMarketplaceName() {
        let existing = #"{"name":"work","plugins":[]}"#
        XCTAssertThrowsError(
            try CodexPluginPackageInstaller.mergedMarketplacePayload(existingData: Data(existing.utf8))
        )
    }

    func testMergedMarketplaceRejectsCorruptJson() {
        XCTAssertThrowsError(
            try CodexPluginPackageInstaller.mergedMarketplacePayload(existingData: Data("{{".utf8))
        )
    }

    func testNeedsUpdateDetectsInstalledPackageDrift() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cctop-codex-package-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appendingPathComponent("bundled/cctop-codex-plugin")
        let installed = home.appendingPathComponent("installed/cctop-codex-plugin")

        try writePluginFile("same", relativePath: ".codex-plugin/plugin.json", root: bundled)
        try writePluginFile("same", relativePath: ".codex-plugin/plugin.json", root: installed)
        try writePluginFile("new", relativePath: "skills/cctop-diagnostics/SKILL.md", root: bundled)
        try writePluginFile("old", relativePath: "skills/cctop-diagnostics/SKILL.md", root: installed)

        XCTAssertTrue(
            CodexPluginPackageInstaller.needsUpdate(
                bundledPluginRoot: bundled,
                installedPluginRoot: installed
            )
        )
    }

    func testNeedsUpdateIgnoresMatchingInstalledPackage() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cctop-codex-package-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appendingPathComponent("bundled/cctop-codex-plugin")
        let installed = home.appendingPathComponent("installed/cctop-codex-plugin")

        try writePluginFile("same", relativePath: ".codex-plugin/plugin.json", root: bundled)
        try writePluginFile("same", relativePath: ".codex-plugin/plugin.json", root: installed)
        try writePluginFile("same", relativePath: "skills/cctop-diagnostics/SKILL.md", root: bundled)
        try writePluginFile("same", relativePath: "skills/cctop-diagnostics/SKILL.md", root: installed)

        XCTAssertFalse(
            CodexPluginPackageInstaller.needsUpdate(
                bundledPluginRoot: bundled,
                installedPluginRoot: installed
            )
        )
    }

    func testNeedsUpdateTreatsUnreadableInstalledPackageAsDrift() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cctop-codex-package-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let bundled = home.appendingPathComponent("bundled/cctop-codex-plugin")
        let installed = home.appendingPathComponent("installed/cctop-codex-plugin")

        try writePluginFile("same", relativePath: ".codex-plugin/plugin.json", root: bundled)
        try writePluginFile("same", relativePath: ".codex-plugin/plugin.json", root: installed)
        let unreadable = installed.appendingPathComponent(".codex-plugin/plugin.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path)
        }

        XCTAssertTrue(
            CodexPluginPackageInstaller.needsUpdate(
                bundledPluginRoot: bundled,
                installedPluginRoot: installed
            )
        )
    }

    func testInstallPluginPackageWritesCodexConfigWithoutInvokingCodexCLI() throws {
        try withTemporaryHomeAndPath { home in
            let source = home.appendingPathComponent("source/cctop-codex-plugin")
            try writeCodexPluginFiles(root: source)
            let codexInvocationMarker = try writeFakeCodexCLI(home: home)
            try writeCodexConfig(
                """
                [features]
                hooks = false

                [plugins."cctop@personal"]
                enabled = true
                """,
                home: home
            )

            XCTAssertTrue(CodexPluginPackageInstaller.installPluginPackage(from: source))

            let config = try String(contentsOf: CodexPluginInstaller.configTomlPath, encoding: .utf8)
            XCTAssertTrue(CodexPluginPackageInstaller.hasCurrentMarketplaceConfigEntry(configText: config))
            XCTAssertTrue(CodexPluginPackageInstaller.hasCurrentInstalledConfigEntry(configText: config))
            XCTAssertFalse(CodexPluginPackageInstaller.hasLegacyInstalledConfigEntry(configText: config))
            XCTAssertTrue(CodexPluginInstaller.isFeatureFlagEnabled(config))
            XCTAssertTrue(CodexPluginPackageInstaller.hasInstalledPluginFiles())
            XCTAssertFalse(FileManager.default.fileExists(atPath: codexInvocationMarker.path))
        }
    }

    func testRemoveBundledPluginRemovesCodexConfigAndFilesWithoutCodexCLI() throws {
        try withTemporaryHomeAndPath { home in
            try writeCodexConfig(
                """
                [marketplaces.cctop]
                source_type = "local"
                source = "\(home.path)/.cctop/codex-plugin-marketplace"

                [plugins."cctop@cctop"]
                enabled = true

                [plugins."other@personal"]
                enabled = true
                """,
                home: home
            )
            try writeInstalledCodexPluginFiles(home: home)

            XCTAssertTrue(CodexPluginPackageInstaller.removeBundledPlugin())

            let config = try String(contentsOf: CodexPluginInstaller.configTomlPath, encoding: .utf8)
            XCTAssertFalse(config.contains("[marketplaces.cctop]"))
            XCTAssertFalse(config.contains("[plugins.\"cctop@cctop\"]"))
            XCTAssertTrue(config.contains("[plugins.\"other@personal\"]"))
            XCTAssertFalse(CodexPluginPackageInstaller.hasInstalledPluginFiles())
        }
    }

    func testRemoveBundledPluginPreservesNonAppOwnedCctopMarketplaceConfig() throws {
        try withTemporaryHomeAndPath { home in
            try writeCodexConfig(
                """
                [marketplaces.cctop]
                source_type = "local"
                source = "/tmp/some-other-marketplace"

                [plugins."cctop@cctop"]
                enabled = true
                """,
                home: home
            )
            try writeInstalledCodexPluginFiles(home: home)

            XCTAssertTrue(CodexPluginPackageInstaller.removeBundledPlugin())

            let config = try String(contentsOf: CodexPluginInstaller.configTomlPath, encoding: .utf8)
            XCTAssertTrue(config.contains("[marketplaces.cctop]"))
            XCTAssertTrue(config.contains("/tmp/some-other-marketplace"))
            XCTAssertFalse(CodexPluginPackageInstaller.hasCurrentInstalledConfigEntry(configText: config))
        }
    }

    private func parseMarketplace(_ data: Data) throws -> [String: Any] {
        let parsed = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(parsed as? [String: Any])
    }

    private func writePluginFile(_ contents: String, relativePath: String, root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    private func withTemporaryHomeAndPath(_ body: (URL) throws -> Void) throws {
        let originalHome = ProcessInfo.processInfo.environment["HOME"]
        let originalPath = ProcessInfo.processInfo.environment["PATH"]
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cctop-codex-package-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("HOME", home.path, 1)
        setenv("PATH", home.appendingPathComponent("bin").path, 1)
        defer {
            if let originalHome {
                setenv("HOME", originalHome, 1)
            } else {
                unsetenv("HOME")
            }
            if let originalPath {
                setenv("PATH", originalPath, 1)
            } else {
                unsetenv("PATH")
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
        let root = home.appendingPathComponent(".cctop/codex-plugin-marketplace/plugins/cctop-codex")
        try writeCodexPluginFiles(root: root)
    }

    private func writeCodexPluginFiles(root: URL) throws {
        try writePluginFile("{}", relativePath: ".codex-plugin/plugin.json", root: root)
        try writePluginFile("{}", relativePath: "hooks/hooks.json", root: root)
        let shim = root.appendingPathComponent("hooks/cctop-shim.sh")
        try "#!/bin/sh\n".write(to: shim, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)
    }

    private func writeFakeCodexCLI(home: URL) throws -> URL {
        let bin = home.appendingPathComponent("bin")
        let marker = home.appendingPathComponent("codex-was-invoked")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let codex = bin.appendingPathComponent("codex")
        try "#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n".write(to: codex, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
        return marker
    }

}
