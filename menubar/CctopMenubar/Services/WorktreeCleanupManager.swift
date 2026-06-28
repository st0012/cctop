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
    private let sourceSessions: [CleanupSourceSessionSignature]
    private let activeProjectPaths: [String]

    init(sourceSessions: [Session], activeProjectPaths: Set<String>) {
        self.sourceSessions = sourceSessions
            .map(CleanupSourceSessionSignature.init)
            .sorted()
        self.activeProjectPaths = activeProjectPaths
            .map(WorktreeCleanupScanner.standardizedPath)
            .sorted()
    }
}

private struct CleanupSourceSessionSignature: Equatable, Comparable {
    let sessionId: String
    let projectPath: String
    let displayName: String
    let branch: String
    let effectiveEndDate: Date
    let lifecycle: SessionLifecycle
    let isHostedByDesktopApp: Bool

    init(session: Session) {
        sessionId = session.sessionId
        projectPath = WorktreeCleanupScanner.standardizedPath(session.projectPath)
        displayName = session.displayName
        branch = session.branch
        effectiveEndDate = session.effectiveEndDate
        lifecycle = session.lifecycle
        isHostedByDesktopApp = session.isHostedByDesktopApp
    }

    static func < (lhs: CleanupSourceSessionSignature, rhs: CleanupSourceSessionSignature) -> Bool {
        if lhs.projectPath != rhs.projectPath { return lhs.projectPath < rhs.projectPath }
        if lhs.sessionId != rhs.sessionId { return lhs.sessionId < rhs.sessionId }
        return lhs.effectiveEndDate < rhs.effectiveEndDate
    }
}
