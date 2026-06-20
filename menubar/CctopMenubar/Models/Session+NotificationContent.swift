import Foundation

struct SessionNotificationContent: Equatable {
    let title: String
    let subtitle: String
    let body: String
}

extension Session {
    private static let notificationBodyLimit = 72

    var notificationContent: SessionNotificationContent {
        let sender = notificationSenderName
        return SessionNotificationContent(
            title: notificationTitle,
            subtitle: notificationSubtitle(sender: sender),
            body: notificationBody
        )
    }

    private var notificationTitle: String {
        let title = Self.cleanNotificationTitleText(displayName)
        guard let projectContext = notificationProjectContext,
              !Self.title(title, alreadyContainsProject: projectContext) else {
            return title
        }
        return "[\(projectContext)] \(title)"
    }

    private var notificationProjectContext: String? {
        if let desktopProjectName = Self.cleanOptionalNotificationTitleText(desktopProjectName) {
            return desktopProjectName
        }
        guard sessionName != nil else { return nil }
        return Self.cleanOptionalNotificationTitleText(projectName)
    }

    private var notificationSenderName: String {
        let bundleId = terminal?.bundleId
        if Self.trustsDesktopBundle(source: source, bundleId: bundleId) {
            switch bundleId {
            case HostAppBundleID.codexDesktop: return "Codex Desktop"
            case HostAppBundleID.claudeDesktop: return "Claude Desktop"
            default: break
            }
        }

        switch source {
        case Self.codexSource: return "Codex"
        case Self.opencodeSource: return "opencode"
        case Self.piSource: return "pi"
        default: return "Claude"
        }
    }

    private func notificationSubtitle(sender: String) -> String {
        switch status {
        case .waitingPermission:
            return "\(sender) needs permission"
        case .waitingInput:
            return "\(sender) is waiting for input"
        default:
            return "\(sender) needs attention"
        }
    }

    private var notificationBody: String {
        let detail: String?
        switch status {
        case .waitingPermission:
            detail = Self.cleanOptionalNotificationBodyText(notificationMessage) ?? "Permission needed"
        case .waitingInput:
            detail = Self.cleanOptionalNotificationBodyText(notificationMessage)
                ?? Self.cleanOptionalNotificationBodyText(lastPrompt)
                ?? "Waiting for input"
        default:
            detail = Self.cleanOptionalNotificationBodyText(notificationMessage) ?? "Needs attention"
        }
        return Self.truncateNotificationBody(detail ?? "Needs attention")
    }

    private static func title(_ title: String, alreadyContainsProject project: String) -> Bool {
        let title = title.lowercased()
        let project = project.lowercased()
        return title == project || title.hasPrefix("[\(project)] ")
    }

    private static func cleanOptionalNotificationTitleText(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = cleanNotificationTitleText(text)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cleanOptionalNotificationBodyText(_ text: String?) -> String? {
        guard let text else { return nil }
        let cleaned = cleanNotificationBodyText(text)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func cleanNotificationTitleText(_ text: String) -> String {
        cleanNotificationBodyText(text)
            .replacingOccurrences(of: "CCTOP", with: "cctop")
    }

    private static func cleanNotificationBodyText(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func truncateNotificationBody(_ text: String) -> String {
        guard text.count > notificationBodyLimit else { return text }
        let prefixLength = max(0, notificationBodyLimit - 3)
        return String(text.prefix(prefixLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
