import XCTest
@testable import CctopMenubar

/// Tests for `CodexPluginInstaller.patchConfigToml`, `isFeatureFlagEnabled`,
/// and `configTomlHasLegacyKey`. Split out from `CodexPluginInstallerTests`
/// to keep each file under the 400-line cap.
///
/// Contract for the writer: cctop only modifies config.toml when it has to.
/// Codex defaults `[features].hooks` to true, so a clean config is left
/// alone. Two cases trigger an edit:
///   1. Removing a deprecated `[features].codex_hooks` line (any value).
///   2. Overriding an explicit `[features].hooks = false` to `true`.
final class CodexPluginTomlTests: XCTestCase {

    // MARK: - patchConfigToml: clean configs are left alone

    func testEmptyInputIsUnchanged() {
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(""), "")
    }

    func testCleanConfigIsUnchanged() {
        let input = "[features]\nother_flag = true"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testConfigWithoutFeaturesIsUnchanged() {
        let input = "[general]\nfoo = \"bar\""
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testIsNoOpWhenAlreadyEnabled() {
        let input = "[features]\nhooks = true"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testIgnoresCommentedOutFlag() {
        let input = "[features]\n# hooks = true"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testDoesNotMatchLookalikeKey() {
        let input = "[features]\nhooks_v2 = false"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testAcceptsTrueWithTrailingComment() {
        let input = "[features]\nhooks = true  # enable hooks"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    // MARK: - patchConfigToml: opt-out override

    func testReplacesFalseWithTrue() {
        let input = "[features]\nhooks = false"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertEqual(result, "[features]\nhooks = true")
    }

    func testReplacesFalseWithTruePreservingNeighbors() {
        let input = "[features]\nother = true\nhooks = false\nmore = 1"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertEqual(result, "[features]\nother = true\nhooks = true\nmore = 1")
    }

    // MARK: - patchConfigToml: legacy codex_hooks migration

    func testRemovesLegacyTrueLine() {
        let input = "[features]\ncodex_hooks = true"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertEqual(result, "[features]")
        XCTAssertFalse(result.contains("codex_hooks"))
    }

    func testRemovesLegacyFalseLine() {
        // Even `codex_hooks = false` must go — Codex defaults the new key to
        // true, so removing the legacy line silently re-enables hooks. That
        // matches the pre-rename install contract (install force-enables).
        let input = "[features]\ncodex_hooks = false"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertEqual(result, "[features]")
        XCTAssertFalse(result.contains("codex_hooks"))
    }

    func testRemovesLegacyPreservingNeighbors() {
        let input = "[features]\nother = true\ncodex_hooks = true\nmore = 1"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertEqual(result, "[features]\nother = true\nmore = 1")
        XCTAssertFalse(result.contains("codex_hooks"))
    }

    func testRemovesLegacyWhenHooksTrueAlsoPresent() {
        let input = "[features]\ncodex_hooks = true\nhooks = true"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertEqual(result, "[features]\nhooks = true")
    }

    func testOverridesFalseAndRemovesLegacy() {
        // Both apply: drop the legacy line AND override the explicit opt-out.
        let input = "[features]\nhooks = false\ncodex_hooks = true"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertEqual(result, "[features]\nhooks = true")
    }

    func testRemovesLegacyWithInlineComment() {
        let input = "[features]\ncodex_hooks = true  # ancient cctop install"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertEqual(result, "[features]")
        XCTAssertFalse(result.contains("codex_hooks"))
    }

    // MARK: - patchConfigToml: table-scope correctness

    func testLeavesLegacyKeyInUnrelatedTableAlone() {
        let input = "[other]\ncodex_hooks = true\n\n[features]\nfoo = 1"
        let result = CodexPluginInstaller.patchConfigToml(input)
        // Unrelated table preserved verbatim; clean [features] left alone.
        XCTAssertEqual(result, input)
    }

    func testLeavesFalseInUnrelatedTableAlone() {
        let input = "[other]\nhooks = false"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testLeavesRootLevelKeyAlone() {
        // Assignments before any [table] header are in the implicit root
        // table, not in [features]. The writer must not touch them.
        let input = "hooks = false\n\n[features]"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testIgnoresFalseInsideArrayOfTables() {
        // `[[notifications]]` opens a different scope. A `hooks = false`
        // inside it is not under [features] and must not trigger the
        // opt-out override.
        let input = "[features]\nother = 1\n[[notifications]]\nhooks = false"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testIgnoresLegacyKeyInsideArrayOfTables() {
        let input = "[features]\nother = 1\n[[notifications]]\ncodex_hooks = true"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    // MARK: - isFeatureFlagEnabled: default is enabled

    func testFlagEnabledOnEmptyInput() {
        // No config = Codex default = hooks enabled.
        XCTAssertTrue(CodexPluginInstaller.isFeatureFlagEnabled(""))
    }

    func testFlagEnabledWhenNoFeaturesTable() {
        XCTAssertTrue(CodexPluginInstaller.isFeatureFlagEnabled("[general]\nfoo = 1"))
    }

    func testFlagEnabledWhenFeaturesTableButNoHooksKey() {
        XCTAssertTrue(CodexPluginInstaller.isFeatureFlagEnabled("[features]\nother = true"))
    }

    func testFlagEnabledWhenHooksIsTrue() {
        XCTAssertTrue(CodexPluginInstaller.isFeatureFlagEnabled("[features]\nhooks = true"))
    }

    func testFlagEnabledWhenCommentedOut() {
        // Commented-out lines don't count as set — default applies.
        XCTAssertTrue(CodexPluginInstaller.isFeatureFlagEnabled("[features]\n# hooks = false"))
    }

    func testFlagEnabledIgnoresWrongTable() {
        // Wrong-table flags don't count, so default applies.
        XCTAssertTrue(
            CodexPluginInstaller.isFeatureFlagEnabled("[other]\nhooks = false")
        )
    }

    func testFlagEnabledIgnoresArrayOfTables() {
        // `hooks = false` inside `[[notifications]]` isn't under [features].
        XCTAssertTrue(CodexPluginInstaller.isFeatureFlagEnabled(
            "[features]\n[[notifications]]\nhooks = false"
        ))
    }

    // MARK: - isFeatureFlagEnabled: explicit opt-out

    func testFlagDisabledWhenHooksIsFalse() {
        XCTAssertFalse(CodexPluginInstaller.isFeatureFlagEnabled("[features]\nhooks = false"))
    }

    func testFlagDisabledOnLegacyFalse() {
        XCTAssertFalse(
            CodexPluginInstaller.isFeatureFlagEnabled("[features]\ncodex_hooks = false")
        )
    }

    func testFlagEnabledOnLegacyTrue() {
        XCTAssertTrue(
            CodexPluginInstaller.isFeatureFlagEnabled("[features]\ncodex_hooks = true")
        )
    }

    func testNewKeyWinsWhenBothPresent() {
        // `hooks = false` overrides legacy `codex_hooks = true` (matches
        // Codex's own resolution: documented key beats deprecated alias).
        XCTAssertFalse(CodexPluginInstaller.isFeatureFlagEnabled(
            "[features]\nhooks = false\ncodex_hooks = true"
        ))
        XCTAssertTrue(CodexPluginInstaller.isFeatureFlagEnabled(
            "[features]\nhooks = true\ncodex_hooks = false"
        ))
    }

    // MARK: - configTomlHasLegacyKey

    func testHasLegacyKeyDetectsTrue() {
        XCTAssertTrue(
            CodexPluginInstaller.configTomlHasLegacyKey("[features]\ncodex_hooks = true")
        )
    }

    func testHasLegacyKeyDetectsFalse() {
        // Even `codex_hooks = false` triggers the deprecation warning — both
        // values should surface the "Update Available" prompt.
        XCTAssertTrue(
            CodexPluginInstaller.configTomlHasLegacyKey("[features]\ncodex_hooks = false")
        )
    }

    func testHasLegacyKeyIgnoresWrongTable() {
        XCTAssertFalse(
            CodexPluginInstaller.configTomlHasLegacyKey("[other]\ncodex_hooks = true")
        )
    }

    func testHasLegacyKeyIgnoresArrayOfTables() {
        XCTAssertFalse(CodexPluginInstaller.configTomlHasLegacyKey(
            "[features]\n[[notifications]]\ncodex_hooks = true"
        ))
    }

    func testHasLegacyKeyIgnoresCommented() {
        XCTAssertFalse(
            CodexPluginInstaller.configTomlHasLegacyKey("[features]\n# codex_hooks = true")
        )
    }

    func testHasLegacyKeyFalseOnCleanConfig() {
        XCTAssertFalse(
            CodexPluginInstaller.configTomlHasLegacyKey("[features]\nhooks = true")
        )
        XCTAssertFalse(CodexPluginInstaller.configTomlHasLegacyKey(""))
    }

    // MARK: - migrateLegacyKey: value-preserving rename, never an enable

    func testMigrateIsNoOpWithoutLegacyKey() {
        let clean = "[features]\nhooks = false"
        XCTAssertEqual(CodexConfigToml.migrateLegacyKey(clean), clean)
        XCTAssertEqual(CodexConfigToml.migrateLegacyKey(""), "")
    }

    func testMigrateDropsTrueLegacyKeyWithoutWritingNoiseFlag() {
        let migrated = CodexConfigToml.migrateLegacyKey("[features]\ncodex_hooks = true\nother = 1")
        XCTAssertEqual(migrated, "[features]\nother = 1")
        // Effective value preserved: true via the Codex default.
        XCTAssertTrue(CodexConfigToml.isHooksEnabled(migrated))
    }

    func testMigratePreservesOptOutUnderNewName() {
        let migrated = CodexConfigToml.migrateLegacyKey("[features]\ncodex_hooks = false")
        XCTAssertEqual(migrated, "[features]\nhooks = false")
        XCTAssertFalse(CodexConfigToml.isHooksEnabled(migrated))
    }

    func testMigrateDropsLegacyKeyWhenHooksKeyAlreadyWins() {
        // `hooks` beats the alias in Codex's resolution, so the alias can go
        // even when the values disagree.
        let migrated = CodexConfigToml.migrateLegacyKey(
            "[features]\nhooks = false\ncodex_hooks = true"
        )
        XCTAssertEqual(migrated, "[features]\nhooks = false")
        XCTAssertFalse(CodexConfigToml.isHooksEnabled(migrated))
    }

    func testMigrateIgnoresLegacyKeyOutsideFeatures() {
        let input = "[other]\ncodex_hooks = true"
        XCTAssertEqual(CodexConfigToml.migrateLegacyKey(input), input)
    }
}
