import XCTest
@testable import CctopMenubar

final class CodexPluginInstallerTests: XCTestCase {

    // TOML patching + isFeatureFlagEnabled tests live in CodexPluginTomlTests.swift.

    // MARK: - shellQuote

    func testShellQuoteHandlesSpaces() {
        let quoted = CodexPluginInstaller.shellQuote("/Users/Foo Bar/.codex/cctop-shim.sh")
        XCTAssertEqual(quoted, "'/Users/Foo Bar/.codex/cctop-shim.sh'")
    }

    func testMergeHooksFileWritesUnescapedSlashes() throws {
        let dir = makeTempCodexDir()
        let template = try loadCodexHooksTemplate()
        try withHomeDir(dir.parent) {
            try CodexPluginInstaller.mergeHooksFile(template: template)
            let text = try String(contentsOf: CodexPluginInstaller.hooksJsonPath, encoding: .utf8)
            // Swift's JSONSerialization escapes `/` as `\/`; we post-process to strip
            // that so users reading the file see normal paths.
            XCTAssertFalse(text.contains("\\/"), "slashes should not be backslash-escaped")
            XCTAssertTrue(text.contains("cctop-shim.sh"))
        }
    }

    func testShellQuoteEscapesEmbeddedSingleQuotes() {
        let quoted = CodexPluginInstaller.shellQuote("/tmp/ca'fe/shim.sh")
        // POSIX single-quote escape: close quote, literal quote, reopen quote.
        XCTAssertEqual(quoted, "'/tmp/ca'\\''fe/shim.sh'")
    }

    // MARK: - hooks.json merge

    func testMergeHooksFileCreatesFileWithOurEntries() throws {
        let dir = makeTempCodexDir()
        let template = try loadCodexHooksTemplate()
        // Redirect to temp dir by pointing HOME at it.
        try withHomeDir(dir.parent) {
            try CodexPluginInstaller.mergeHooksFile(template: template)
            let produced = try readHooksFile()
            let hooks = try XCTUnwrap(produced["hooks"] as? [String: Any])
            for event in CodexPluginInstaller.registeredEvents {
                XCTAssertNotNil(hooks[event], "missing event: \(event)")
            }
        }
    }

    func testMergeHooksFilePreservesUserHooks() throws {
        let dir = makeTempCodexDir()
        let template = try loadCodexHooksTemplate()
        let userHooks: [String: Any] = [
            "hooks": [
                "Stop": [
                    [
                        "hooks": [
                            ["type": "command", "command": "~/.bin/my-own-script.sh"]
                        ]
                    ]
                ],
                "UnknownEvent": [
                    [
                        "hooks": [
                            ["type": "command", "command": "echo foo"]
                        ]
                    ]
                ]
            ]
        ]
        try writeHooksFile(userHooks, at: dir)
        try withHomeDir(dir.parent) {
            try CodexPluginInstaller.mergeHooksFile(template: template)
            let produced = try readHooksFile()
            let hooks = try XCTUnwrap(produced["hooks"] as? [String: Any])

            // User's Stop entry still present + our Stop entry added.
            let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
            XCTAssertTrue(stop.contains { containsCommandSubstring($0, "my-own-script.sh") })
            XCTAssertTrue(stop.contains { containsCommandSubstring($0, "cctop-shim.sh") })

            // Unknown event kept untouched.
            let unknown = try XCTUnwrap(hooks["UnknownEvent"] as? [[String: Any]])
            XCTAssertTrue(unknown.contains { containsCommandSubstring($0, "echo foo") })
        }
    }

    func testMergeHooksFileIsIdempotentOnReinstall() throws {
        let dir = makeTempCodexDir()
        let template = try loadCodexHooksTemplate()
        try withHomeDir(dir.parent) {
            try CodexPluginInstaller.mergeHooksFile(template: template)
            try CodexPluginInstaller.mergeHooksFile(template: template)
            let produced = try readHooksFile()
            let hooks = try XCTUnwrap(produced["hooks"] as? [String: Any])
            for event in CodexPluginInstaller.registeredEvents {
                let entries = try XCTUnwrap(hooks[event] as? [[String: Any]])
                let cctopEntries = entries.filter {
                    containsCommandSubstring($0, "cctop-shim.sh")
                }
                XCTAssertEqual(cctopEntries.count, 1, "duplicate cctop entries for \(event)")
            }
        }
    }

    func testRemoveHooksEntriesPreservesSharedMatcherCommands() throws {
        let dir = makeTempCodexDir()
        try withHomeDir(dir.parent) {
            // User has a matcher entry for Stop that contains BOTH a cctop command
            // and their own command. Removing should only strip cctop's command.
            let mixedHooks: [String: Any] = [
                "hooks": [
                    "Stop": [[
                        "matcher": "startup",
                        "hooks": [
                            [
                                "type": "command",
                                "command": "/Users/alice/.codex/cctop-shim.sh Stop"
                            ],
                            [
                                "type": "command",
                                "command": "/Users/alice/bin/my-stop-hook.sh"
                            ]
                        ]
                    ]]
                ]
            ]
            try writeHooksFile(mixedHooks, at: dir)
            try CodexPluginInstaller.removeHooksEntries()

            let produced = try readHooksFile()
            let hooks = try XCTUnwrap(produced["hooks"] as? [String: Any])
            let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])

            // The user's command must survive.
            XCTAssertEqual(stop.count, 1)
            let innerCmds = try XCTUnwrap(stop[0]["hooks"] as? [[String: Any]])
            XCTAssertEqual(innerCmds.count, 1)
            XCTAssertEqual(innerCmds[0]["command"] as? String, "/Users/alice/bin/my-stop-hook.sh")
        }
    }

    func testMergeHooksFileRefusesToOverwriteCorruptJson() throws {
        let dir = makeTempCodexDir()
        let template = try loadCodexHooksTemplate()
        try withHomeDir(dir.parent) {
            // Write a corrupt hooks.json (invalid JSON).
            let corrupt = Data("not json {{".utf8)
            try corrupt.write(to: dir.codex.appendingPathComponent("hooks.json"))

            XCTAssertThrowsError(try CodexPluginInstaller.mergeHooksFile(template: template)) { err in
                guard case CodexPluginInstaller.InstallError.corruptJson = err else {
                    XCTFail("expected corruptJson, got \(err)")
                    return
                }
            }

            // File must be untouched.
            let after = try Data(contentsOf: CodexPluginInstaller.hooksJsonPath)
            XCTAssertEqual(after, corrupt, "corrupt file must not be overwritten")
        }
    }

    func testRemoveHooksEntriesDropsOnlyCctopEntries() throws {
        let dir = makeTempCodexDir()
        let template = try loadCodexHooksTemplate()
        try withHomeDir(dir.parent) {
            // Seed user hook on Stop, then install ours, then remove.
            let userHooks: [String: Any] = [
                "hooks": [
                    "Stop": [[
                        "hooks": [["type": "command", "command": "~/.bin/my-script.sh"]]
                    ]]
                ]
            ]
            try writeHooksFile(userHooks, at: dir)
            try CodexPluginInstaller.mergeHooksFile(template: template)
            try CodexPluginInstaller.removeHooksEntries()

            let produced = try readHooksFile()
            let hooks = try XCTUnwrap(produced["hooks"] as? [String: Any])

            // User hook survives.
            let stop = try XCTUnwrap(hooks["Stop"] as? [[String: Any]])
            XCTAssertTrue(stop.contains { containsCommandSubstring($0, "my-script.sh") })
            XCTAssertFalse(stop.contains { containsCommandSubstring($0, "cctop-shim.sh") })

            // Events that had only cctop entries are gone.
            XCTAssertNil(hooks["UserPromptSubmit"])
            XCTAssertNil(hooks["PreToolUse"])
        }
    }

    // MARK: - isInstalled

    func testIsInstalledRejectsExplicitOptOut() throws {
        let dir = makeTempCodexDir()
        let template = try loadCodexHooksTemplate()
        let shim = try loadCodexShim()
        try withHomeDir(dir.parent) {
            XCTAssertTrue(
                CodexPluginInstaller.install(shimContents: shim, hooksTemplate: template)
            )
            // Codex defaults `hooks` to true, so a clean install (no config.toml
            // written) reports as installed.
            XCTAssertTrue(CodexPluginInstaller.isInstalled())

            // An explicit opt-out flips install state to false even though the
            // shim and hooks.json are still in place.
            try Data("[features]\nhooks = false\n".utf8)
                .write(to: CodexPluginInstaller.configTomlPath, options: .atomic)
            XCTAssertFalse(CodexPluginInstaller.isInstalled())

            // Deleting config.toml removes the opt-out; the Codex default
            // (`hooks = true`) kicks back in and install reads as installed.
            try FileManager.default.removeItem(at: CodexPluginInstaller.configTomlPath)
            XCTAssertTrue(CodexPluginInstaller.isInstalled())
        }
    }

    // MARK: - Test helpers

    private struct TempCodexDir {
        let codex: URL
        var parent: URL { codex.deletingLastPathComponent() }
    }

    private func makeTempCodexDir() -> TempCodexDir {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cctop-test-\(UUID().uuidString)")
        let codex = home.appendingPathComponent(".codex")
        try? FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return TempCodexDir(codex: codex)
    }

    /// Temporarily override HOME so `CodexPluginInstaller`'s path helpers point at the
    /// test's scratch directory. setenv affects the whole process, so serial test
    /// execution is assumed (XCTest default).
    private func withHomeDir(_ home: URL, _ body: () throws -> Void) throws {
        let previous = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        defer {
            if let previous { setenv("HOME", previous, 1) } else { unsetenv("HOME") }
        }
        try body()
    }

    private func loadCodexHooksTemplate() throws -> Data {
        try Data(contentsOf: repoRoot.appendingPathComponent("plugins/codex/hooks.json"))
    }

    private func loadCodexShim() throws -> Data {
        try Data(contentsOf: repoRoot.appendingPathComponent("plugins/codex/cctop-shim.sh"))
    }

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func writeHooksFile(_ json: [String: Any], at dir: TempCodexDir) throws {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
        try data.write(to: dir.codex.appendingPathComponent("hooks.json"), options: .atomic)
    }

    private func readHooksFile() throws -> [String: Any] {
        let data = try Data(contentsOf: CodexPluginInstaller.hooksJsonPath)
        return try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
    }

    private func containsCommandSubstring(_ entry: [String: Any], _ needle: String) -> Bool {
        guard let cmds = entry["hooks"] as? [[String: Any]] else { return false }
        return cmds.contains { ($0["command"] as? String)?.contains(needle) ?? false }
    }
}
