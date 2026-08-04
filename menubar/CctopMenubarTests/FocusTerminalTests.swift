import XCTest
@testable import CctopMenubar

final class FocusTerminalTests: XCTestCase {

    func testRestoreAppAndOpenURLReportsMissingApplication() throws {
        let completion = expectation(description: "reports missing application")

        restoreAppAndOpenURL(
            bundleID: "com.st0012.cctop.tests.definitely-missing",
            url: try XCTUnwrap(URL(string: "codex://threads/019e1eff-3374-74b0-8d3d-6fba94e7d75f"))
        ) { failure in
            XCTAssertEqual(failure, .codexAppNotInstalled)
            completion.fulfill()
        }

        wait(for: [completion], timeout: 1)
    }

    // MARK: - GUID extraction: standard format

    func testGUIDExtractionStandardFormat() {
        let result = extractITermGUID(from: "w0t0p0:2A4B6C8D-1234-5678-9ABC-DEF012345678")
        XCTAssertEqual(result, "2A4B6C8D-1234-5678-9ABC-DEF012345678")
    }

    func testGUIDExtractionDifferentWindowTabPane() {
        let result = extractITermGUID(from: "w3t1p2:SOME-GUID-HERE")
        XCTAssertEqual(result, "SOME-GUID-HERE")
    }

    // MARK: - GUID extraction: edge cases

    func testGUIDExtractionNoColon() {
        let result = extractITermGUID(from: "just-a-plain-guid")
        XCTAssertEqual(result, "just-a-plain-guid")
    }

    func testGUIDExtractionNilInput() {
        let result = extractITermGUID(from: nil)
        XCTAssertNil(result)
    }

    func testGUIDExtractionEmptyString() {
        let result = extractITermGUID(from: "")
        XCTAssertNil(result)
    }

    func testGUIDExtractionMultipleColons() {
        // split(separator: ":").last gives the part after the last colon
        let result = extractITermGUID(from: "w0t0p0:some:complex:id")
        XCTAssertEqual(result, "id")
    }

    // MARK: - Session.mock() terminal parameter

    func testMockDefaultTerminalIsCode() {
        let session = Session.mock()
        XCTAssertEqual(session.terminal?.program, "Code")
        XCTAssertNil(session.terminal?.sessionId)
    }

    func testMockWithITerm2Terminal() {
        let session = Session.mock(
            terminal: TerminalInfo(
                program: "iTerm.app",
                sessionId: "w0t0p0:TEST-GUID",
                tty: "/dev/ttys001"
            )
        )
        XCTAssertEqual(session.terminal?.program, "iTerm.app")
        XCTAssertEqual(session.terminal?.sessionId, "w0t0p0:TEST-GUID")
        XCTAssertEqual(session.terminal?.tty, "/dev/ttys001")
    }

    func testMockWithNilTerminal() {
        let session = Session.mock(terminal: nil)
        XCTAssertNil(session.terminal)
    }

    // MARK: - Activation-name launch fallback

    // When a .activateByName app isn't running, execution recovers its bundle ID
    // via HostApp.from(editorName:) to launch it. Lock the round trip so every
    // activation name maps back to its own HostApp (and thus a bundle ID).
    func testActivationNamesRoundTripToHostAppWithBundleID() {
        for app in HostApp.allCases {
            guard let name = app.activationName else { continue }
            XCTAssertEqual(HostApp.from(editorName: name), app, "activation name '\(name)' should map back to \(app)")
            XCTAssertNotNil(app.bundleID, "\(app) has an activation name but no bundle ID to launch")
        }
    }

    // MARK: - Recent project opener matching

    func testRecentProjectProgramNameRecognizesWarpTerminal() {
        XCTAssertEqual(HostApp.projectOpener(fromProgramName: "WarpTerminal"), .warp)
        XCTAssertEqual(HostApp.projectOpener(fromProgramName: "warpterminal"), .warp)
    }

    func testRecentProjectProgramNameRejectsAgentLikeStrings() {
        let agentLikeNames = [
            "Codex",
            "Claude Code",
            "OpenAI Codex",
            "opencode",
            "Codex WarpTerminal",
        ]

        for name in agentLikeNames {
            XCTAssertNil(HostApp.projectOpener(fromProgramName: name), name)
        }
    }

    // MARK: - Recent project open strategy

    func testRecentProjectWithoutEditorOpensProjectInFinder() {
        let project = RecentProject.mock(editor: nil)
        XCTAssertEqual(
            resolveRecentProjectOpenStrategy(project: project),
            .openInFinder(project.projectPath)
        )
    }

    func testRecentProjectUnknownEditorOpensProjectInFinder() {
        let project = RecentProject.mock(editor: "Codex")
        XCTAssertEqual(
            resolveRecentProjectOpenStrategy(project: project),
            .openInFinder(project.projectPath)
        )
    }

    func testRecentProjectKnownTerminalOpensProjectPathWithApp() {
        let project = RecentProject.mock(editor: "Ghostty")
        XCTAssertEqual(
            resolveRecentProjectOpenStrategy(project: project),
            .openWithApp(bundleID: "com.mitchellh.ghostty", target: project.projectPath)
        )
    }

    func testRecentProjectKnownEditorOpensWorkspaceFileWithApp() {
        let workspaceFile = "/Users/dev/projects/my-project/my-project.code-workspace"
        let project = RecentProject.mock(editor: "Cursor", workspaceFile: workspaceFile)
        XCTAssertEqual(
            resolveRecentProjectOpenStrategy(project: project),
            .openWithApp(bundleID: "com.todesktop.230313mzl4w4u92", target: workspaceFile)
        )
    }

    func testRecentProjectKnownEditorFallsBackToProjectPath() {
        let project = RecentProject.mock(editor: "Code")
        XCTAssertEqual(
            resolveRecentProjectOpenStrategy(project: project),
            .openWithApp(bundleID: "com.microsoft.VSCode", target: project.projectPath)
        )
    }

    func testRecentResumeTargetProjectDelegatesToProjectOpenStrategy() {
        let project = RecentProject.mock(editor: "Ghostty")
        let target = RecentResumeTarget.project(project)

        XCTAssertEqual(
            resolveRecentResumeTargetOpenStrategy(target: target),
            .openWithApp(bundleID: "com.mitchellh.ghostty", target: project.projectPath)
        )
    }

    func testRecentResumeTargetClaudeDesktopActivatesAppOnly() {
        let uuid = "39253133-4a65-48fb-af2b-844463d3b5bb"
        let target = RecentResumeTarget.desktopThread(.init(
            sessionId: uuid,
            title: "Run plugin node:test suites in CI",
            projectPath: "/Users/dev/projects/cctop",
            projectName: "cctop",
            lastActiveAt: Date()
        ))

        XCTAssertEqual(
            resolveRecentResumeTargetOpenStrategy(target: target),
            .activateByBundleID(HostApp.claudeDesktop.bundleID!)
        )
    }
}
