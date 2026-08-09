import Foundation

enum RecentResumeTarget: Identifiable, Equatable {
    struct DesktopThread: Equatable {
        let sessionId: String
        let cctopSessionId: String?
        let title: String
        let projectPath: String
        let projectName: String
        let lastActiveAt: Date

        init(
            sessionId: String,
            cctopSessionId: String? = nil,
            title: String,
            projectPath: String,
            projectName: String,
            lastActiveAt: Date
        ) {
            self.sessionId = sessionId
            self.cctopSessionId = cctopSessionId
            self.title = title
            self.projectPath = projectPath
            self.projectName = projectName
            self.lastActiveAt = lastActiveAt
        }
    }

    case project(RecentProject)
    case desktopThread(DesktopThread)

    var id: String {
        switch self {
        case .project(let project):
            return "project:\(project.id)"
        case .desktopThread(let thread):
            if let cctopSessionID = thread.cctopSessionId,
               CctopSessionID.isValid(cctopSessionID) {
                return "desktop:\(cctopSessionID)"
            }
            return "desktop:Claude Desktop:\(thread.sessionId)"
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

    var cctopSessionId: String? {
        guard case .desktopThread(let thread) = self else { return nil }
        return thread.cctopSessionId
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
        case .desktopThread:
            return HostApp.claudeDesktop.sfSymbol
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
        case .desktopThread:
            return "Open Claude Desktop"
        }
    }

    var inlineActionLabel: String? {
        switch self {
        case .project:
            return nil
        case .desktopThread:
            return "Open Claude"
        }
    }

    var openHelpText: String {
        switch self {
        case .project(let project):
            return project.openHelpText
        case .desktopThread:
            return "Open Claude Desktop; archived sessions may need manual lookup"
        }
    }

    var metadataText: String {
        switch self {
        case .project(let project):
            return Self.joinedMetadata([project.metadataEvidenceText, project.pathContext])
        case .desktopThread(let thread):
            return Self.joinedMetadata(["Archived", "Claude", Self.compactProjectPath(thread.projectPath)])
        }
    }

    static func build(
        projects: [RecentProject],
        classification: SessionClassificationSnapshot,
        excludingDesktopSessionIDs: Set<String> = [],
        limit: Int = 10
    ) -> [RecentResumeTarget] {
        let projectTargets = projects.map(RecentResumeTarget.project)
        let desktopTargets = desktopThreadTargets(
            from: classification,
            excludingSessionIDs: excludingDesktopSessionIDs
        )
        return Array((projectTargets + desktopTargets)
            .sorted { $0.lastSessionAt > $1.lastSessionAt }
            .prefix(limit))
    }

    private static func desktopThreadTargets(
        from classification: SessionClassificationSnapshot,
        excludingSessionIDs: Set<String>
    ) -> [RecentResumeTarget] {
        var targetsByID: [String: (target: RecentResumeTarget, candidate: SessionRecord)] = [:]
        for record in classification.records {
            if let cctopSessionID = record.candidate.data.cctopSessionId,
               excludingSessionIDs.contains(cctopSessionID) {
                continue
            }
            guard isArchivedClaudeDesktop(record.disposition),
                  let thread = DesktopThread(session: record.candidate.data) else {
                continue
            }
            let target = RecentResumeTarget.desktopThread(thread)
            if let existing = targetsByID[target.id],
               !SessionLifecyclePolicy.prefers(record.candidate, over: existing.candidate) {
                continue
            }
            targetsByID[target.id] = (target, record.candidate)
        }
        return targetsByID.values.map(\.target)
    }

    private static func isArchivedClaudeDesktop(_ disposition: SessionDisposition) -> Bool {
        guard case .hidden(.archivedClaudeDesktop) = disposition else { return false }
        return true
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
    init?(session: SessionData) {
        let title = Self.displayTitle(for: session)
        guard !title.isEmpty else { return nil }
        self.init(
            sessionId: session.sessionId,
            cctopSessionId: session.cctopSessionId,
            title: title,
            projectPath: session.projectPath,
            projectName: session.desktopProjectName ?? session.projectName,
            lastActiveAt: session.effectiveEndDate
        )
    }

    private static func displayTitle(for session: SessionData) -> String {
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
