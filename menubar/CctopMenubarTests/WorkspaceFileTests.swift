import XCTest
@testable import CctopMenubar

final class WorkspaceFileTests: XCTestCase {
    var tempDir: String!

    override func setUp() {
        super.setUp()
        tempDir = NSTemporaryDirectory() + "cctop-focus-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempDir)
        super.tearDown()
    }

    func testFindsWorkspaceFileWhenSingleExists() throws {
        let wsPath = (tempDir as NSString).appendingPathComponent("project.code-workspace")
        FileManager.default.createFile(atPath: wsPath, contents: Data("{}".utf8))

        let result = Session.findWorkspaceFile(in: tempDir)
        XCTAssertEqual(result, wsPath)
    }

    func testReturnsNilWhenNoWorkspaceFile() {
        let result = Session.findWorkspaceFile(in: tempDir)
        XCTAssertNil(result)
    }

    func testReturnsNilForNonexistentDirectory() {
        let result = Session.findWorkspaceFile(in: "/nonexistent/path/\(UUID().uuidString)")
        XCTAssertNil(result)
    }

    func testPrefersMatchingProjectNameWhenMultiple() throws {
        let projectName = URL(fileURLWithPath: tempDir).lastPathComponent
        let matchPath = (tempDir as NSString).appendingPathComponent("\(projectName).code-workspace")
        let otherPath = (tempDir as NSString).appendingPathComponent("other.code-workspace")
        FileManager.default.createFile(atPath: matchPath, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: otherPath, contents: Data("{}".utf8))

        let result = Session.findWorkspaceFile(in: tempDir)
        XCTAssertEqual(result, matchPath)
    }

    func testReturnsNilWhenMultipleAndNoneMatchProjectName() throws {
        let path1 = (tempDir as NSString).appendingPathComponent("alpha.code-workspace")
        let path2 = (tempDir as NSString).appendingPathComponent("beta.code-workspace")
        FileManager.default.createFile(atPath: path1, contents: Data("{}".utf8))
        FileManager.default.createFile(atPath: path2, contents: Data("{}".utf8))

        let result = Session.findWorkspaceFile(in: tempDir)
        XCTAssertNil(result)
    }

    func testIgnoresNonWorkspaceFiles() throws {
        let txtPath = (tempDir as NSString).appendingPathComponent("notes.txt")
        let swiftPath = (tempDir as NSString).appendingPathComponent("main.swift")
        FileManager.default.createFile(atPath: txtPath, contents: Data("".utf8))
        FileManager.default.createFile(atPath: swiftPath, contents: Data("".utf8))

        let result = Session.findWorkspaceFile(in: tempDir)
        XCTAssertNil(result)
    }
}
