import XCTest
@testable import CctopMenubar

final class CodexIntegrationManagerTests: XCTestCase {
    func testSnapshotReportsUntrustedHooksAsInstalledButNeedingTrust() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: true,
            needsUpdate: false,
            configText: makeTrustedConfig(events: CodexPluginInstaller.trustStateEventKeys.dropLast())
        ))

        XCTAssertEqual(snapshot.hookStatus, .installedUntrusted)
        XCTAssertTrue(snapshot.hookStatus.needsTrust)
        XCTAssertTrue(snapshot.installed)
        XCTAssertFalse(snapshot.needsUpdate)
    }

    func testSnapshotReportsFullyTrustedHooks() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: true,
            needsUpdate: false,
            configText: makeTrustedConfig(events: CodexPluginInstaller.trustStateEventKeys)
        ))

        XCTAssertEqual(snapshot.hookStatus, .trusted)
        XCTAssertFalse(snapshot.hookStatus.needsTrust)
        XCTAssertTrue(snapshot.installed)
        XCTAssertFalse(snapshot.needsUpdate)
    }

    func testSnapshotTreatsStaleInstallAsNeedsUpdate() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: true,
            needsUpdate: true,
            configText: makeTrustedConfig(events: CodexPluginInstaller.trustStateEventKeys)
        ))

        XCTAssertEqual(snapshot.hookStatus, .needsUpdate)
        XCTAssertTrue(snapshot.installed)
        XCTAssertTrue(snapshot.needsUpdate)
    }

    func testSnapshotLetsExplicitOptOutWinOverStaleInstall() {
        // hooks = false + stale shim: "Enable Hooks" must win over "Update
        // Hooks" so the UI never re-enables an explicit opt-out under an
        // update label. The published update flag is suppressed to match.
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: false,
            needsUpdate: true,
            configText: nil
        ))

        XCTAssertEqual(snapshot.hookStatus, .hooksDisabled)
        XCTAssertFalse(snapshot.installed)
        XCTAssertFalse(snapshot.needsUpdate)
    }

    func testSnapshotReportsMissingHookFilesAsNotInstalled() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: false,
            featureEnabled: true,
            needsUpdate: false,
            configText: nil
        ))

        XCTAssertEqual(snapshot.hookStatus, .notInstalled)
        XCTAssertFalse(snapshot.installed)
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
                installed: true, featureEnabled: false, needsUpdate: true, configText: trustedConfig
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
                installed: true, featureEnabled: true, needsUpdate: false, configText: nil
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

    func testHookStatusInstalledFlagMatchesUserVisibleInstallState() {
        XCTAssertFalse(CodexHookStatus.notInstalled.isInstalled)
        XCTAssertFalse(CodexHookStatus.hooksDisabled.isInstalled)
        XCTAssertTrue(CodexHookStatus.needsUpdate.isInstalled)
        XCTAssertTrue(CodexHookStatus.installedUntrusted.isInstalled)
        XCTAssertTrue(CodexHookStatus.trusted.isInstalled)
    }

    // MARK: - Test helpers

    /// Builds config.toml trust entries for the path `hookStatus` checks at
    /// runtime (`CodexPluginInstaller.hooksJsonPath`).
    private func makeTrustedConfig(events: some Sequence<String>) -> String {
        let hooksPath = CodexPluginInstaller.hooksJsonPath.path
        var lines = ["[hooks.state]"]
        for event in events {
            lines.append("")
            lines.append("[hooks.state.\"\(hooksPath):\(event):0:0\"]")
            lines.append("trusted_hash = \"sha256:abc123\"")
        }
        return lines.joined(separator: "\n")
    }
}
