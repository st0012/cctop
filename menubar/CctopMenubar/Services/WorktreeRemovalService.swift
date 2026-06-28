import Foundation

struct WorktreeRemovalService {
    struct GitResult: Equatable {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum RemovalResult: Equatable {
        case removed(GitResult)
        case refused(WorktreeCleanupCandidate)
        case failed(GitResult)
    }

    var scanner: WorktreeCleanupScanner
    var runGit: ([String]) -> GitResult

    static func live() -> WorktreeRemovalService {
        WorktreeRemovalService(
            scanner: .live(),
            runGit: Self.runGit(arguments:)
        )
    }

    func remove(
        _ candidate: WorktreeCleanupCandidate,
        sourceSessions: [Session],
        activeProjectPaths: Set<String>
    ) -> RemovalResult {
        guard candidate.state.isActionable else {
            return .refused(candidate)
        }

        guard let preflightCandidate = scanner
            .candidates(from: sourceSessions, activeProjectPaths: activeProjectPaths)
            .first(where: { $0.id == candidate.id }) else {
            return .refused(candidate)
        }

        guard preflightCandidate.state.isActionable else {
            return .refused(preflightCandidate)
        }

        if candidate.state.isClean && !preflightCandidate.state.isClean {
            return .refused(preflightCandidate)
        }

        let inspection = scanner.inspectGit(preflightCandidate.worktreePath)
        guard let mainWorktreePath = inspection.mainWorktreePath,
              inspection.isRegisteredWorktree,
              inspection.isLinkedWorktree else {
            return .refused(preflightCandidate)
        }

        let result = runGit([
            "-C",
            mainWorktreePath,
            "worktree",
            "remove",
            preflightCandidate.worktreePath,
        ])
        guard result.exitCode == 0 else {
            return .failed(result)
        }
        return .removed(result)
    }

    private static func runGit(arguments: [String]) -> GitResult {
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
            return GitResult(exitCode: 127, stdout: "", stderr: error.localizedDescription)
        }

        let group = DispatchGroup()
        let stdoutReader = RemovalPipeOutputReader(fileHandle: stdout.fileHandleForReading)
        let stderrReader = RemovalPipeOutputReader(fileHandle: stderr.fileHandleForReading)
        stdoutReader.start(group: group)
        stderrReader.start(group: group)
        process.waitUntilExit()
        group.wait()

        return GitResult(
            exitCode: process.terminationStatus,
            stdout: stdoutReader.stringValue,
            stderr: stderrReader.stringValue
        )
    }
}

private final class RemovalPipeOutputReader {
    private let fileHandle: FileHandle
    private let queue = DispatchQueue(label: "com.st0012.CctopMenubar.WorktreeRemovalService.PipeOutputReader")
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
