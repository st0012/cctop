import Foundation
import os.log

private let worktreeInspectorLogger = Logger(
    subsystem: "com.st0012.CctopMenubar",
    category: "GitWorktreeInspector"
)

struct GitWorktreeInspector {
    var runGit: (String, [String]) -> GitCommandResult = GitCommand.run
    var runGitWithInput: (String, [String], String) -> GitCommandResult = GitCommand.run
    var worktreeFileMode: (String) -> String? = Self.gitWorktreeFileMode
    var symlinkDestination: (String) -> String? = Self.symlinkDestination

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
        detectIndexHiddenTrackedFiles(path: path, failures: &failures)
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
        let result = runGit(path, ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=traditional"])
        guard result.exitCode == 0 else {
            failures.append("Git status could not be read")
            return nil
        }
        return Self.parseStatusEntries(result.stdout)
    }

    private func detectIndexHiddenTrackedFiles(path: String, failures: inout [String]) {
        let result = runGit(path, ["ls-files", "-s", "-v", "-z"])
        guard result.exitCode == 0 else { return }
        let entries = Self.indexHiddenTrackedEntries(result.stdout)
        let sparseIndexOnlyPaths = sparseCheckoutIndexOnlyPaths(path: path, entries: entries)
        let hasHiddenTrackedEdits = entries.contains { entry in
            hasWorktreeContentChangedFromIndex(path: path, entry: entry, sparseIndexOnlyPaths: sparseIndexOnlyPaths)
        }
        if hasHiddenTrackedEdits {
            failures.append(WorktreeCleanupCandidate.indexHiddenTrackedFilesReason)
        }
    }

    private func hasWorktreeContentChangedFromIndex(
        path: String,
        entry: IndexHiddenTrackedEntry,
        sparseIndexOnlyPaths: Set<String>
    ) -> Bool {
        if sparseIndexOnlyPaths.contains(entry.path) {
            return false
        }
        guard let worktreeObjectID = worktreeObjectID(path: path, entry: entry) else {
            return true
        }
        guard worktreeObjectID == entry.objectID else { return true }
        guard let worktreeMode = worktreeFileMode(Self.absolutePath(path, entry.path)) else { return true }
        return worktreeMode != entry.mode
    }

    private func worktreeObjectID(path: String, entry: IndexHiddenTrackedEntry) -> String? {
        if entry.mode == "120000" {
            guard let destination = symlinkDestination(Self.absolutePath(path, entry.path)) else {
                return nil
            }
            let result = runGitWithInput(path, ["hash-object", "--stdin"], destination)
            guard result.exitCode == 0 else { return nil }
            return Config.nonEmpty(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let result = runGit(path, ["hash-object", "--path=\(entry.path)", "--", entry.path])
        guard result.exitCode == 0 else { return nil }
        return Config.nonEmpty(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func sparseCheckoutIndexOnlyPaths(path: String, entries: [IndexHiddenTrackedEntry]) -> Set<String> {
        let absentSkippedPaths = entries
            .filter { entry in
                (entry.marker == "S" || entry.marker == "s")
                    && worktreeFileMode(Self.absolutePath(path, entry.path)) == nil
            }
            .map(\.path)
        guard !absentSkippedPaths.isEmpty else { return [] }
        let input = absentSkippedPaths.joined(separator: "\u{0}") + "\u{0}"
        let result = runGitWithInput(path, ["sparse-checkout", "check-rules", "-z"], input)
        guard result.exitCode == 0 else { return [] }
        let includedPaths = Set(Self.parseStatusEntries(result.stdout))
        return Set(absentSkippedPaths).subtracting(includedPaths)
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

    private static func indexHiddenTrackedEntries(_ output: String) -> [IndexHiddenTrackedEntry] {
        parseStatusEntries(output).compactMap { entry in
            guard let marker = entry.first,
                  marker == "S" || marker == "s" || marker == "h" else {
                return nil
            }
            let separatorIndex = entry.index(after: entry.startIndex)
            guard separatorIndex < entry.endIndex,
                  entry[separatorIndex] == " " else {
                return nil
            }
            let pathIndex = entry.index(after: separatorIndex)
            guard pathIndex < entry.endIndex else { return nil }
            let remainder = entry[pathIndex...]
            let parts = remainder.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let fields = parts[0].split(separator: " ")
            guard fields.count >= 3 else { return nil }
            return IndexHiddenTrackedEntry(marker: String(marker), mode: String(fields[0]), path: String(parts[1]), objectID: String(fields[1]))
        }
    }

    private static func absolutePath(_ root: String, _ relativePath: String) -> String {
        URL(fileURLWithPath: root, isDirectory: true)
            .appendingPathComponent(relativePath)
            .path
    }

    private static func gitWorktreeFileMode(at path: String) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let type = attributes[.type] as? FileAttributeType else {
            return nil
        }
        if type == .typeSymbolicLink {
            return "120000"
        }
        guard type == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber else {
            return nil
        }
        return permissions.intValue & 0o111 == 0 ? "100644" : "100755"
    }

    private static func symlinkDestination(at path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
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

private struct IndexHiddenTrackedEntry {
    let marker: String
    let mode: String
    let path: String
    let objectID: String
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

    static func run(cwd: String, arguments: [String], stdin: String) -> GitCommandResult {
        runProcess(arguments: ["-C", cwd] + arguments, stdin: stdin)
    }

    private static func runProcess(arguments: [String], stdin: String? = nil) -> GitCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        let inputPipe = Pipe()
        if stdin != nil {
            process.standardInput = inputPipe
        }

        do {
            try process.run()
        } catch {
            worktreeInspectorLogger.debug("git failed to launch: \(error.localizedDescription, privacy: .public)")
            return GitCommandResult(exitCode: 127, stdout: "", stderr: error.localizedDescription)
        }
        // Drain stdout/stderr before writing stdin: if the child fills a pipe that
        // nobody reads while it still waits for input, both processes block forever.
        let group = DispatchGroup()
        let stdoutReader = PipeOutputReader(fileHandle: stdout.fileHandleForReading)
        let stderrReader = PipeOutputReader(fileHandle: stderr.fileHandleForReading)
        stdoutReader.start(group: group)
        stderrReader.start(group: group)
        if let stdin {
            inputPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inputPipe.fileHandleForWriting.closeFile()
        }
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
