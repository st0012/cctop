import Foundation
import os.log

private let worktreeCleanupLogger = Logger(
    subsystem: "com.st0012.CctopMenubar",
    category: "WorktreeCleanupManager"
)

@MainActor
class WorktreeCleanupManager: ObservableObject {
    @Published var candidates: [WorktreeCleanupCandidate] = []

    private let scanner: WorktreeCleanupScanner
    private var refreshGeneration = 0
    private var lastRefreshSignature: WorktreeCleanupRefreshSignature?

    init(scanner: WorktreeCleanupScanner = .live()) {
        self.scanner = scanner
    }

    func refresh(from sourceSessions: [Session], activeProjectPaths: Set<String>, force: Bool = false) {
        let signature = WorktreeCleanupRefreshSignature(
            sourceSessions: sourceSessions,
            activeProjectPaths: activeProjectPaths
        )
        guard force || signature != lastRefreshSignature else { return }
        lastRefreshSignature = signature

        refreshGeneration += 1
        let generation = refreshGeneration
        let scanner = scanner
        DispatchQueue.global(qos: .utility).async {
            let next = scanner
                .candidates(from: sourceSessions, activeProjectPaths: activeProjectPaths)
                .filter(\.state.isActionable)
            DispatchQueue.main.async {
                guard generation == self.refreshGeneration else { return }
                if next != self.candidates {
                    worktreeCleanupLogger.info("cleanup candidates \(self.candidates.count) -> \(next.count)")
                    self.candidates = next
                }
            }
        }
    }
}

struct WorktreeCleanupRefreshSignature: Equatable {
    private let endedCandidatePaths: [String]
    private let activeProjectPaths: [String]

    init(sourceSessions: [Session], activeProjectPaths: Set<String>) {
        self.endedCandidatePaths = sourceSessions
            .filter { $0.endedAt != nil }
            .map { WorktreeCleanupScanner.standardizedPath($0.projectPath) }
            .sorted()
        self.activeProjectPaths = activeProjectPaths
            .map(WorktreeCleanupScanner.standardizedPath)
            .sorted()
    }
}
