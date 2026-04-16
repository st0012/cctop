import XCTest
@testable import CctopMenubar

/// Tests for `CodexPluginInstaller.patchConfigToml` and `isFeatureFlagEnabled`.
/// Split out from `CodexPluginInstallerTests` to keep each file under the 400-line cap.
final class CodexPluginTomlTests: XCTestCase {

    // MARK: - patchConfigToml

    func testCreatesFeaturesSectionOnEmptyInput() {
        let result = CodexPluginInstaller.patchConfigToml("")
        XCTAssertTrue(result.contains("[features]"))
        XCTAssertTrue(result.contains("codex_hooks = true"))
    }

    func testIsNoOpWhenAlreadyEnabled() {
        let input = "[features]\ncodex_hooks = true"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testAcceptsCompactSpacing() {
        let input = "[features]\ncodex_hooks=true"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    func testReplacesFalseWithTrue() {
        let input = "[features]\ncodex_hooks = false"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertTrue(result.contains("codex_hooks = true"))
        XCTAssertFalse(result.contains("codex_hooks = false"))
    }

    func testInsertsIntoExistingFeaturesTable() {
        let input = "[features]\nother_flag = true"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertTrue(result.contains("codex_hooks = true"))
        XCTAssertTrue(result.contains("other_flag = true"))
    }

    func testAppendsFreshSectionWhenNoFeaturesTable() {
        let input = "[general]\nfoo = \"bar\""
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertTrue(result.contains("[general]"))
        XCTAssertTrue(result.contains("[features]"))
        XCTAssertTrue(result.contains("codex_hooks = true"))
    }

    func testIgnoresCommentedOutFlag() {
        let input = "[features]\n# codex_hooks = true"
        let result = CodexPluginInstaller.patchConfigToml(input)
        // Inserted line should be after [features], comment preserved intact.
        XCTAssertTrue(result.contains("codex_hooks = true"))
        XCTAssertTrue(result.contains("# codex_hooks = true"))
    }

    func testDoesNotMatchLookalikeKey() {
        let input = "[features]\ncodex_hooks_v2 = false"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertTrue(result.contains("codex_hooks_v2 = false"))
        XCTAssertTrue(result.contains("codex_hooks = true"))
    }

    func testHandlesFeaturesHeaderWithInlineComment() {
        let input = "[features]  # existing\nother_flag = true"
        let result = CodexPluginInstaller.patchConfigToml(input)
        // Must not duplicate the [features] header.
        XCTAssertEqual(result.components(separatedBy: "[features]").count - 1, 1)
        XCTAssertTrue(result.contains("codex_hooks = true"))
        XCTAssertTrue(result.contains("other_flag = true"))
    }

    func testAcceptsTrueWithTrailingComment() {
        let input = "[features]\ncodex_hooks = true  # enable hooks"
        XCTAssertEqual(CodexPluginInstaller.patchConfigToml(input), input)
    }

    // MARK: - Table-scope correctness

    func testDoesNotRewriteKeyInWrongTable() {
        // `codex_hooks` in an unrelated table must be left alone.
        let input = "[other]\ncodex_hooks = false"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertTrue(result.contains("[other]") && result.contains("codex_hooks = false"))
        XCTAssertTrue(result.contains("[features]"))
        // Two `codex_hooks` occurrences now: the untouched false + our new true.
        XCTAssertEqual(result.components(separatedBy: "codex_hooks").count - 1, 2)
    }

    func testDoesNotRewriteRootKey() {
        // Assignments before any [table] header are in the implicit root table,
        // not in [features]. Leave them alone.
        let input = "codex_hooks = false\n\n[features]"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertTrue(result.contains("codex_hooks = false"))
        let lines = result.components(separatedBy: "\n")
        guard let featuresIdx = lines.firstIndex(of: "[features]") else {
            XCTFail("lost [features] header"); return
        }
        XCTAssertTrue(lines[(featuresIdx + 1)...].contains("codex_hooks = true"))
    }

    func testDoesNotNoOpOnKeyInWrongTable() {
        // `codex_hooks = true` in some OTHER table doesn't count — Codex reads
        // [features].codex_hooks specifically.
        let input = "[other]\ncodex_hooks = true\n\n[features]"
        let result = CodexPluginInstaller.patchConfigToml(input)
        XCTAssertTrue(result.contains("[features]"))
        let lines = result.components(separatedBy: "\n")
        guard let featuresIdx = lines.firstIndex(of: "[features]") else {
            XCTFail("lost [features] header"); return
        }
        XCTAssertTrue(lines[(featuresIdx + 1)...].contains("codex_hooks = true"))
    }

    // MARK: - isFeatureFlagEnabled

    func testFlagEnabledRequiresFeaturesTable() {
        XCTAssertFalse(CodexPluginInstaller.isFeatureFlagEnabled(""))
        XCTAssertFalse(CodexPluginInstaller.isFeatureFlagEnabled("codex_hooks = true"))
        XCTAssertFalse(CodexPluginInstaller.isFeatureFlagEnabled("[other]\ncodex_hooks = true"))
        XCTAssertTrue(CodexPluginInstaller.isFeatureFlagEnabled("[features]\ncodex_hooks = true"))
    }

    func testFlagEnabledRejectsFalse() {
        XCTAssertFalse(CodexPluginInstaller.isFeatureFlagEnabled("[features]\ncodex_hooks = false"))
    }

    func testFlagEnabledSkipsCommentedOut() {
        XCTAssertFalse(CodexPluginInstaller.isFeatureFlagEnabled("[features]\n# codex_hooks = true"))
    }
}
