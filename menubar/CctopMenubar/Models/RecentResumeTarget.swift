import Foundation

enum RecentResumeTarget: Identifiable, Equatable {
    struct DesktopThread: Equatable {
        let sessionId: String
        let title: String
        let projectPath: String
        let projectName: String
        let sourceApp: HostApp
        let lastActiveAt: Date
    }

    case project(RecentProject)
    case desktopThread(DesktopThread)

    var id: String {
        switch self {
        case .project(let project):
            return "project:\(project.id)"
        case .desktopThread(let thread):
            return "desktop:\(thread.sourceApp.displayName):\(thread.sessionId)"
        }
    }

    var title: String {
        switch self {
        case .project(let project):
            return project.projectName
        case .desktopThread(let thread):
            return thread.title
        }
    }

    var projectPath: String {
        switch self {
        case .project(let project):
            return project.projectPath
        case .desktopThread(let thread):
            return thread.projectPath
        }
    }

    var lastSessionAt: Date {
        switch self {
        case .project(let project):
            return project.lastSessionAt
        case .desktopThread(let thread):
            return thread.lastActiveAt
        }
    }

    var icon: String {
        switch self {
        case .project(let project):
            return project.editorIcon
        case .desktopThread(let thread):
            return thread.sourceApp.sfSymbol
        }
    }

    var opensProjectInApp: Bool {
        switch self {
        case .project(let project):
            return project.opensWithProjectApp
        case .desktopThread:
            return false
        }
    }

    var showsFinderAction: Bool {
        switch self {
        case .project:
            return opensProjectInApp
        case .desktopThread:
            return false
        }
    }

    var showsCopyPathAction: Bool {
        switch self {
        case .project:
            return true
        case .desktopThread:
            return false
        }
    }

    var openActionLabel: String {
        switch self {
        case .project(let project):
            return project.openActionLabel
        case .desktopThread(let thread):
            return "Open \(thread.sourceApp.displayName)"
        }
    }

    var inlineActionLabel: String? {
        switch self {
        case .project:
            return nil
        case .desktopThread(let thread) where thread.sourceApp == .codexDesktop:
            return "Open Codex"
        case .desktopThread(let thread) where thread.sourceApp == .claudeDesktop:
            return "Open Claude"
        case .desktopThread(let thread):
            return "Open \(thread.sourceApp.displayName)"
        }
    }

    var openHelpText: String {
        switch self {
        case .project(let project):
            return project.openHelpText
        case .desktopThread(let thread):
            return "Open \(thread.sourceApp.displayName) to find this archived session"
        }
    }

    var metadataText: String {
        switch self {
        case .project(let project):
            return Self.joinedMetadata([project.metadataEvidenceText, project.pathContext])
        case .desktopThread(let thread):
            return Self.joinedMetadata(["Archived", thread.sourceApp.shortDesktopName, Self.compactProjectPath(thread.projectPath)])
        }
    }

    static func build(
        projects: [RecentProject],
        classification: SessionClassificationSnapshot,
        limit: Int = 10
    ) -> [RecentResumeTarget] {
        let projectTargets = projects.map(RecentResumeTarget.project)
        let desktopTargets = desktopThreadTargets(from: classification)
        return Array((projectTargets + desktopTargets)
            .sorted { $0.lastSessionAt > $1.lastSessionAt }
            .prefix(limit))
    }

    private static func desktopThreadTargets(from classification: SessionClassificationSnapshot) -> [RecentResumeTarget] {
        var targetsByID: [String: RecentResumeTarget] = [:]
        for record in classification.records {
            guard let sourceApp = desktopThreadSourceApp(for: record.disposition),
                  let thread = DesktopThread(session: record.candidate.session, sourceApp: sourceApp) else {
                continue
            }
            if shouldSkipArchivedCodexDesktopThread(thread.sessionId, sourceApp: sourceApp, evidence: classification.evidence) {
                continue
            }
            let target = RecentResumeTarget.desktopThread(thread)
            if let existing = targetsByID[target.id],
               existing.lastSessionAt >= target.lastSessionAt {
                continue
            }
            targetsByID[target.id] = target
        }
        return Array(targetsByID.values)
    }

    private static func desktopThreadSourceApp(for disposition: SessionDisposition) -> HostApp? {
        guard case .hidden(let reason) = disposition else { return nil }
        switch reason {
        case .archivedCodexDesktop:
            return .codexDesktop
        case .archivedClaudeDesktop:
            return .claudeDesktop
        case .persistedHidden, .autoHidden, .missingCodexDesktopThread, .codexSubagent, .codexExecHelper,
             .orphanedEndedClaudeDesktop, .claudeDesktopStartupPlaceholder:
            return nil
        }
    }

    private static func shouldSkipArchivedCodexDesktopThread(
        _ sessionId: String,
        sourceApp: HostApp,
        evidence: SessionClassificationEvidence
    ) -> Bool {
        guard sourceApp == .codexDesktop else { return false }
        return evidence.codexSubagentThreadIDs.contains(sessionId) || evidence.codexExecHelperThreadIDs.contains(sessionId)
    }

    private static func joinedMetadata(_ parts: [String]) -> String {
        parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " \u{00B7} ")
    }

    private static func compactProjectPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }
}

extension RecentResumeTarget.DesktopThread {
    init?(session: Session, sourceApp: HostApp) {
        let title = Self.displayTitle(for: session)
        guard !title.isEmpty else { return nil }
        self.init(
            sessionId: session.sessionId,
            title: title,
            projectPath: session.projectPath,
            projectName: session.desktopProjectName ?? session.projectName,
            sourceApp: sourceApp,
            lastActiveAt: session.effectiveEndDate
        )
    }

    private static func displayTitle(for session: Session) -> String {
        [
            session.sessionName,
            session.lastPrompt,
            session.desktopProjectName,
            session.projectName,
        ]
        .compactMap { value -> String? in
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        }
        .first ?? ""
    }
}

private extension HostApp {
    var shortDesktopName: String {
        switch self {
        case .codexDesktop:
            return "Codex"
        case .claudeDesktop:
            return "Claude"
        default:
            return displayName
        }
    }
}
