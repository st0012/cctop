import Foundation
import os.log

private let worktreeInspectorLogger = Logger(
    subsystem: "com.st0012.CctopMenubar",
    category: "GitWorktreeInspector"
)

struct GitWorktreeInspector {
    var runGit: (String, [String]) -> GitCommandResult = GitCommand.run

    func listWorktrees(from path: String) -> [GitWorktreeListEntry]? {
        let list = runGit(path, ["worktree", "list", "--porcelain", "-z"])
        guard list.exitCode == 0 else { return nil }
        return Self.parseWorktreeList(list.stdout)
    }

    func worktreeRoot(containing path: String) -> String? {
        guard let entries = listWorktrees(from: path) else { return nil }
        let comparablePath = Self.comparablePath(path)
        return entries
            .map(\.path)
            .filter { Self.path(comparablePath, isSameAsOrDescendantOf: Self.comparablePath($0)) }
            .max { lhs, rhs in lhs.count < rhs.count }
    }

    func inspect(path: String) -> GitWorktreeInspection {
        var failures: [String] = []

        guard let entries = listWorktrees(from: path) else {
            return GitWorktreeInspection(
                isRegisteredWorktree: false,
                isLinkedWorktree: false,
                isLocked: false,
                mainWorktreePath: nil,
                branchName: nil,
                statusEntries: nil,
                uniqueCommitCount: nil,
                failureReasons: ["Path is not a registered Git worktree"]
            )
        }

        let comparablePath = Self.comparablePath(path)
        let mainWorktreePath = entries.first?.path
        guard let matchIndex = entries.firstIndex(where: { Self.comparablePath($0.path) == comparablePath }) else {
            return GitWorktreeInspection(
                isRegisteredWorktree: false,
                isLinkedWorktree: false,
                isLocked: false,
                mainWorktreePath: mainWorktreePath,
                branchName: nil,
                statusEntries: nil,
                uniqueCommitCount: nil,
                failureReasons: ["Path is not listed by Git worktree metadata"]
            )
        }

        let branch = branchName(path: path, fallback: entries[matchIndex].branchName, failures: &failures)
        let statusEntries = statusEntries(path: path, failures: &failures)
        let uniqueCommitCount = uniqueCommitCount(path: path, branchKnown: branch != nil, failures: &failures)
        detectInitializedSubmodules(path: path, failures: &failures)

        return GitWorktreeInspection(
            isRegisteredWorktree: true,
            isLinkedWorktree: matchIndex > 0,
            isLocked: entries[matchIndex].isLocked,
            mainWorktreePath: mainWorktreePath,
            branchName: branch,
            statusEntries: statusEntries,
            uniqueCommitCount: uniqueCommitCount,
            failureReasons: failures
        )
    }

    private func branchName(path: String, fallback: String?, failures: inout [String]) -> String? {
        let result = runGit(path, ["branch", "--show-current"])
        if result.exitCode == 0, let branch = Config.nonEmpty(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return branch
        }
        if let fallback, !fallback.isEmpty {
            return fallback
        }
        failures.append("Branch is unknown or detached")
        return nil
    }

    private func statusEntries(path: String, failures: inout [String]) -> [String]? {
        let result = runGit(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching"])
        guard result.exitCode == 0 else {
            failures.append("Git status could not be read")
            return nil
        }
        return Self.parseStatusEntries(result.stdout)
    }

    private func detectInitializedSubmodules(path: String, failures: inout [String]) {
        let result = runGit(path, ["submodule", "status", "--recursive"])
        guard result.exitCode == 0 else { return }
        let hasInitializedSubmodules = result.stdout
            .split(whereSeparator: \.isNewline)
            .contains { line in
                guard let marker = line.first else { return false }
                return marker != "-"
            }
        if hasInitializedSubmodules {
            failures.append(WorktreeCleanupCandidate.initializedSubmodulesReason)
        }
    }

    private func uniqueCommitCount(path: String, branchKnown: Bool, failures: inout [String]) -> Int? {
        guard branchKnown else { return nil }
        let upstream = runGit(path, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        guard upstream.exitCode == 0 else {
            failures.append("No upstream branch")
            return nil
        }
        let result = runGit(path, ["rev-list", "--count", "@{u}..HEAD"])
        guard result.exitCode == 0,
              let count = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            failures.append("Branch unique commits could not be verified")
            return nil
        }
        return count
    }

    static func parseWorktreeList(_ output: String) -> [GitWorktreeListEntry] {
        var entries: [GitWorktreeListEntry] = []
        var path: String?
        var branch: String?
        var isPrunable = false
        var isLocked = false

        func flush() {
            guard let currentPath = path else { return }
            entries.append(
                GitWorktreeListEntry(
                    path: currentPath,
                    branchName: branch,
                    isPrunable: isPrunable,
                    isLocked: isLocked
                )
            )
            path = nil
            branch = nil
            isPrunable = false
            isLocked = false
        }

        let separator: Character = output.contains("\u{0}") ? "\u{0}" : "\n"
        for line in output.split(separator: separator, omittingEmptySubsequences: false).map(String.init) {
            if line.isEmpty {
                flush()
            } else if line.hasPrefix("worktree ") {
                flush()
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch refs/heads/") {
                branch = String(line.dropFirst("branch refs/heads/".count))
            } else if line.hasPrefix("prunable") {
                isPrunable = true
            } else if line.hasPrefix("locked") {
                isLocked = true
            }
        }
        flush()
        return entries
    }

    static func parseStatusEntries(_ output: String) -> [String] {
        output
            .split(separator: "\u{0}", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func path(_ path: String, isSameAsOrDescendantOf root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : "\(root)/")
    }

    private static func comparablePath(_ path: String) -> String {
        Config.standardizedPath((path as NSString).resolvingSymlinksInPath)
    }
}

struct GitWorktreeListEntry: Equatable {
    let path: String
    let branchName: String?
    let isPrunable: Bool
    let isLocked: Bool
}

struct GitCommandResult: Equatable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

enum GitCommand {
    static func run(arguments: [String]) -> GitCommandResult {
        runProcess(arguments: arguments)
    }

    static func run(cwd: String, arguments: [String]) -> GitCommandResult {
        runProcess(arguments: ["-C", cwd] + arguments)
    }

    private static func runProcess(arguments: [String]) -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            worktreeInspectorLogger.debug("git failed to launch: \(error.localizedDescription, privacy: .public)")
            return GitCommandResult(exitCode: 127, stdout: "", stderr: error.localizedDescription)
        }

        let group = DispatchGroup()
        let stdoutReader = PipeOutputReader(fileHandle: stdout.fileHandleForReading)
        let stderrReader = PipeOutputReader(fileHandle: stderr.fileHandleForReading)
        stdoutReader.start(group: group)
        stderrReader.start(group: group)
        process.waitUntilExit()
        group.wait()

        return GitCommandResult(
            exitCode: process.terminationStatus,
            stdout: stdoutReader.stringValue,
            stderr: stderrReader.stringValue
        )
    }
}

private final class PipeOutputReader {
    private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "com.st0012.CctopMenubar.GitCommand.PipeOutputReader")
    private var data = Data()

    init(fileHandle: FileHandle) {
        self.fileHandle = fileHandle
    }

    var stringValue: String {
        String(data: data, encoding: .utf8) ?? ""
    }

    func start(group: DispatchGroup) {
        group.enter()
        queue.async {
            self.data = self.fileHandle.readDataToEndOfFile()
            group.leave()
        }
    }
}
