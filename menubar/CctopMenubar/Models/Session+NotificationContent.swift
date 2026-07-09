import Foundation

struct SessionNotificationContent: Equatable {
    let title: String
    let subtitle: String
    let body: String
}

extension Session {
    private static let notificationBodyLimit = 72

    var shouldPostAttentionNotification: Bool {
        guard status.needsAttention else { return false }
        guard usesCodexPromptFallbackPolicy, status == .waitingInput else { return true }
        guard Self.cleanOptionalNotificationBodyText(notificationMessage) == nil else { return true }
        guard let lastPrompt else { return true }
        return Self.userFacingCodexPromptFallbackText(from: lastPrompt) != nil
    }

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
                ?? Self.cleanOptionalPromptFallbackText(
                    lastPrompt,
                    usesCodexPromptFallbackPolicy: usesCodexPromptFallbackPolicy
                )
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

    private var usesCodexPromptFallbackPolicy: Bool {
        source == Self.codexSource
            || (terminal?.bundleId == HostAppBundleID.codexDesktop
                && Self.trustsDesktopBundle(source: source, bundleId: terminal?.bundleId))
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

    private static func cleanOptionalPromptFallbackText(
        _ text: String?,
        usesCodexPromptFallbackPolicy: Bool
    ) -> String? {
        guard let text else { return nil }
        let userFacingText: String?
        if usesCodexPromptFallbackPolicy {
            userFacingText = userFacingCodexPromptFallbackText(from: text)
        } else {
            userFacingText = text
        }
        guard let userFacingText else {
            return nil
        }
        let cleaned = cleanNotificationBodyText(userFacingText)
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

    private static func userFacingCodexPromptFallbackText(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if isMachineWrapperText(trimmed) {
            return nil
        }
        if let userRequest = extractCodexUserRequestFromScaffold(trimmed) {
            return userRequest
        }
        if isMachineOnlyCodexScaffoldText(trimmed) {
            return nil
        }
        return trimmed
    }

    private static func extractCodexUserRequestFromScaffold(_ text: String) -> String? {
        guard isCodexScaffoldText(text),
              let marker = text.range(of: "## My request for Codex:") else {
            return nil
        }
        let request = String(text[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, !isMachineWrapperText(request) else {
            return nil
        }
        return request
    }

    private static func isMachineWrapperText(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        let prefixes = [
            "<codex_delegation",
            "&lt;codex_delegation",
            "<heartbeat",
            "&lt;heartbeat",
            "<environment_context",
            "&lt;environment_context",
            "<skill",
            "&lt;skill"
        ]
        return prefixes.contains { lowercased.hasPrefix($0) }
    }

    private static func isCodexScaffoldText(_ text: String) -> Bool {
        isCodexScaffoldHeadingLine(text)
    }

    private static func isCodexScaffoldHeadingLine(_ line: String) -> Bool {
        let lowercased = line.lowercased()
        let prefixes = [
            "# in app browser:",
            "# in browser:",
            "# open files:",
            "# files:"
        ]
        return prefixes.contains { lowercased.hasPrefix($0) }
    }

    private static func isMachineOnlyCodexScaffoldText(_ text: String) -> Bool {
        guard isCodexScaffoldText(text) else { return false }
        let lines = text.components(separatedBy: .newlines)
            .dropFirst()
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy(isGeneratedCodexScaffoldContextLine)
    }

    private static func isGeneratedCodexScaffoldContextLine(_ line: String) -> Bool {
        let content = line.hasPrefix("- ")
            ? String(line.dropFirst(2)).trimmingCharacters(in: .whitespacesAndNewlines)
            : line
        let lowercased = content.lowercased()
        return isCodexScaffoldHeadingLine(content)
            || content.hasPrefix("/")
            || content.hasPrefix("~/")
            || lowercased.hasPrefix("file://")
            || lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("current url:")
            || lowercased.hasPrefix("page:")
            || lowercased.hasPrefix("url:")
            || lowercased.hasPrefix("the user has ")
    }

    private static func truncateNotificationBody(_ text: String) -> String {
        guard text.count > notificationBodyLimit else { return text }
        let prefixLength = max(0, notificationBodyLimit - 3)
        return String(text.prefix(prefixLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
