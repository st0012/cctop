import XCTest
@testable import CctopMenubar

final class CodexIntegrationManagerTests: XCTestCase {
    private let hooksPath = "/Users/tester/.codex/hooks.json"

    func testSnapshotReportsUntrustedHooksAsInstalledButNeedingTrust() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: true,
            needsUpdate: false,
            configText: makeTrustedConfig(events: CodexIntegrationManager.trustStateEventKeys.dropLast()),
            legacyConfigKey: false,
            hooksJsonPath: hooksPath
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
            configText: makeTrustedConfig(events: CodexIntegrationManager.trustStateEventKeys),
            legacyConfigKey: false,
            hooksJsonPath: hooksPath
        ))

        XCTAssertEqual(snapshot.hookStatus, .trusted)
        XCTAssertFalse(snapshot.hookStatus.needsTrust)
        XCTAssertTrue(snapshot.installed)
        XCTAssertFalse(snapshot.needsUpdate)
    }

    func testSnapshotTreatsTrustForDifferentHooksPathAsUntrusted() {
        // Fully-trusted records keyed to another hooks.json file must not
        // count for the observed install — trust is per hooks-file path.
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: true,
            needsUpdate: false,
            configText: trustStateConfig(
                hooksPath: "/Users/tester/elsewhere/.codex/hooks.json",
                events: CodexIntegrationManager.trustStateEventKeys
            ),
            legacyConfigKey: false,
            hooksJsonPath: hooksPath
        ))

        XCTAssertEqual(snapshot.hookStatus, .installedUntrusted)
        XCTAssertTrue(snapshot.hookStatus.needsTrust)
    }

    func testSnapshotTreatsStaleInstallAsNeedsUpdate() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: true,
            featureEnabled: true,
            needsUpdate: true,
            configText: makeTrustedConfig(events: CodexIntegrationManager.trustStateEventKeys),
            legacyConfigKey: false,
            hooksJsonPath: hooksPath
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
            configText: nil,
            legacyConfigKey: false,
            hooksJsonPath: hooksPath
        ))

        XCTAssertEqual(snapshot.hookStatus, .hooksDisabled)
        XCTAssertFalse(snapshot.installed)
        XCTAssertFalse(snapshot.needsUpdate)
    }

    func testSnapshotReportsMissingHookFilesAsNotInstalled() {
        // Even a fully-trusted config must not count when the hook files are
        // gone — stale trust entries don't make a deleted install "trusted".
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: false,
            featureEnabled: true,
            needsUpdate: false,
            configText: makeTrustedConfig(events: CodexIntegrationManager.trustStateEventKeys),
            legacyConfigKey: false,
            hooksJsonPath: hooksPath
        ))

        XCTAssertEqual(snapshot.hookStatus, .notInstalled)
        XCTAssertFalse(snapshot.installed)
    }

    func testSnapshotPassesLegacyConfigKeyThrough() {
        let snapshot = CodexIntegrationManager.snapshot(CodexIntegrationObservation(
            configExists: true,
            hookFilesInstalled: false,
            featureEnabled: true,
            needsUpdate: false,
            configText: nil,
            legacyConfigKey: true,
            hooksJsonPath: hooksPath
        ))

        XCTAssertTrue(snapshot.legacyConfigKey)
    }

    // MARK: - Trust-record parsing

    func testTrustStateEventKeysPinCodexTrustRecordFormat() {
        // Derived from CodexPluginInstaller.registeredEvents; pin the exact
        // snake_case output so the derivation can never silently mangle a
        // key Codex writes into [hooks.state].
        XCTAssertEqual(
            CodexIntegrationManager.trustStateEventKeys,
            ["session_start", "user_prompt_submit", "pre_tool_use", "post_tool_use", "stop"]
        )
    }

    func testHasTrustedCctopHookStateRequiresAllRegisteredEvents() {
        let config = trustStateConfig(
            hooksPath: hooksPath, events: CodexIntegrationManager.trustStateEventKeys
        )
        XCTAssertTrue(CodexIntegrationManager.hasTrustedCctopHookState(in: config, hooksPath: hooksPath))
    }

    func testHasTrustedCctopHookStateRejectsMissingEvent() {
        let events = CodexIntegrationManager.trustStateEventKeys.filter { $0 != "stop" }
        let config = trustStateConfig(hooksPath: hooksPath, events: events)
        XCTAssertFalse(CodexIntegrationManager.hasTrustedCctopHookState(in: config, hooksPath: hooksPath))
    }

    func testHasTrustedCctopHookStateIgnoresOtherHooksFiles() {
        // Shapes seen in real configs that must not match: an unrelated user
        // hooks file, a project-level file with the same trailing
        // `/.codex/hooks.json`, and a plugin-bundled source whose key
        // contains its own colon before the event segment.
        let nearMissSources = [
            "/tmp/other/hooks.json",
            "/Users/alice/projects/demo/.codex/hooks.json",
            "security-guidance@claude-plugins-official:hooks/hooks.json",
        ]
        for source in nearMissSources {
            let config = trustStateConfig(
                hooksPath: source, events: CodexIntegrationManager.trustStateEventKeys
            )
            XCTAssertFalse(
                CodexIntegrationManager.hasTrustedCctopHookState(in: config, hooksPath: hooksPath),
                "trust entries for \(source) must not count for \(hooksPath)"
            )
        }
    }

    func testHasTrustedCctopHookStateRejectsDisabledTrustedEntries() {
        // Disabling a trusted hook in Codex upserts `enabled = false` into
        // the same [hooks.state] table, keeping the old trusted_hash. The
        // flag must win wherever it sits in the table, so cover both line
        // orders within a section.
        for flagBeforeHash in [true, false] {
            var lines: [String] = []
            for event in CodexIntegrationManager.trustStateEventKeys {
                lines.append("[hooks.state.\"\(hooksPath):\(event):0:0\"]")
                if event == "stop" && flagBeforeHash {
                    lines.append("enabled = false")
                }
                lines.append("trusted_hash = \"sha256:abc123\"")
                if event == "stop" && !flagBeforeHash {
                    lines.append("enabled = false")
                }
            }
            XCTAssertFalse(
                CodexIntegrationManager.hasTrustedCctopHookState(
                    in: lines.joined(separator: "\n"), hooksPath: hooksPath
                ),
                "a disabled hook must not count as trusted "
                    + "(enabled = false \(flagBeforeHash ? "before" : "after") the hash)"
            )
        }
    }

    func testHasTrustedCctopHookStateAcceptsSingleQuotedKeys() {
        // TOML permits single-quoted (literal) keys; a formatter or future
        // Codex version may emit them. Both styles must match.
        var lines: [String] = []
        for event in CodexIntegrationManager.trustStateEventKeys {
            lines.append("[hooks.state.'\(hooksPath):\(event):0:0']")
            lines.append("trusted_hash = \"sha256:abc123\"")
        }
        XCTAssertTrue(
            CodexIntegrationManager.hasTrustedCctopHookState(
                in: lines.joined(separator: "\n"), hooksPath: hooksPath
            )
        )
    }

    func testHasTrustedCctopHookStateAcceptsExplicitlyEnabledEntries() {
        var lines: [String] = []
        for event in CodexIntegrationManager.trustStateEventKeys {
            lines.append("[hooks.state.\"\(hooksPath):\(event):0:0\"]")
            lines.append("trusted_hash = \"sha256:abc123\"")
            lines.append("enabled = true")
        }
        XCTAssertTrue(
            CodexIntegrationManager.hasTrustedCctopHookState(
                in: lines.joined(separator: "\n"), hooksPath: hooksPath
            )
        )
    }

    func testHasTrustedCctopHookStateDoesNotCarryEventAcrossUnrelatedSections() {
        var lines = ["[hooks.state]"]
        for event in CodexIntegrationManager.trustStateEventKeys {
            lines.append("")
            lines.append("[hooks.state.\"\(hooksPath):\(event):0:0\"]")
            if event != "stop" {
                lines.append("trusted_hash = \"sha256:abc123\"")
            }
        }
        lines.append("")
        lines.append("[hooks.state.\"/tmp/other/hooks.json:stop:0:0\"]")
        lines.append("trusted_hash = \"sha256:abc123\"")

        XCTAssertFalse(
            CodexIntegrationManager.hasTrustedCctopHookState(
                in: lines.joined(separator: "\n"), hooksPath: hooksPath
            )
        )
    }

    func testHookStatusClassifiesObservableStates() {
        let trustedConfig = makeTrustedConfig(events: CodexIntegrationManager.trustStateEventKeys)
        let partialConfig = makeTrustedConfig(events: CodexIntegrationManager.trustStateEventKeys.dropLast())

        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: false, featureEnabled: true, needsUpdate: false,
                configText: nil, hooksJsonPath: hooksPath
            ),
            .notInstalled
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: false, featureEnabled: false, needsUpdate: false,
                configText: nil, hooksJsonPath: hooksPath
            ),
            .hooksDisabled
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: true, needsUpdate: true,
                configText: trustedConfig, hooksJsonPath: hooksPath
            ),
            .needsUpdate
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: false, needsUpdate: false,
                configText: trustedConfig, hooksJsonPath: hooksPath
            ),
            .hooksDisabled
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: false, needsUpdate: true,
                configText: trustedConfig, hooksJsonPath: hooksPath
            ),
            .hooksDisabled
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: true, needsUpdate: false,
                configText: partialConfig, hooksJsonPath: hooksPath
            ),
            .installedUntrusted
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: true, needsUpdate: false,
                configText: nil, hooksJsonPath: hooksPath
            ),
            .installedUntrusted
        )
        XCTAssertEqual(
            CodexIntegrationManager.hookStatus(
                installed: true, featureEnabled: true, needsUpdate: false,
                configText: trustedConfig, hooksJsonPath: hooksPath
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

    /// Builds config.toml trust entries keyed to the same fixed `hooksPath`
    /// the tests pass as the observed hooks.json path.
    private func makeTrustedConfig(events: some Sequence<String>) -> String {
        trustStateConfig(hooksPath: hooksPath, events: events)
    }

    private func trustStateConfig(hooksPath: String, events: some Sequence<String>) -> String {
        var lines = ["[hooks.state]"]
        for event in events {
            lines.append("")
            lines.append("[hooks.state.\"\(hooksPath):\(event):0:0\"]")
            lines.append("trusted_hash = \"sha256:abc123\"")
        }
        return lines.joined(separator: "\n")
    }
}
