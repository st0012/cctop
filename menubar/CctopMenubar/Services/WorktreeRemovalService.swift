import Foundation

struct WorktreeRemovalService {
    enum RemovalResult: Equatable {
        case removed(GitCommandResult)
        case refused(WorktreeCleanupCandidate)
        case failed(GitCommandResult)
    }

    var scanner: WorktreeCleanupScanner
    var runGit: ([String]) -> GitCommandResult

    static func live() -> WorktreeRemovalService {
        WorktreeRemovalService(
            scanner: .live(),
            runGit: GitCommand.run(arguments:)
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
        guard inspection.branchName != nil else {
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
}
