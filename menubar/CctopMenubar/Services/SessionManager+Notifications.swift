import Foundation
@preconcurrency import UserNotifications

struct SessionNotificationClient {
    var add: (UNNotificationRequest, @escaping (Error?) -> Void) -> Void
    var removePending: ([String]) -> Void
    var removeDelivered: ([String]) -> Void

    static let live = SessionNotificationClient(
        add: { request, completion in
            UNUserNotificationCenter.current().add(request, withCompletionHandler: completion)
        },
        removePending: { identifiers in
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: identifiers)
        },
        removeDelivered: { identifiers in
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    )
}

enum SessionNotificationAction: Equatable {
    case remove(identifier: String)
    case post(session: Session)
}

@MainActor
extension SessionManager {
    func hideSession(_ session: Session) {
        let stableKey = SessionIdentityPolicy.stableKey(for: session)
        guard sessions.contains(where: { SessionIdentityPolicy.stableKey(for: $0) == stableKey }) else { return }

        dataSources.manualSessionVisibility.hide(session)
        let visibleSessions = sessions.filter {
            SessionIdentityPolicy.stableKey(for: $0) != stableKey
        }

        syncTransitionNotifications(for: visibleSessions, oldSessions: sessions)
        sessions = visibleSessions
    }

    func isManuallyHidden(_ session: Session) -> Bool {
        dataSources.manualSessionVisibility.isHidden(session)
    }

    func syncTransitionNotifications(for newSessions: [Session], oldSessions: [Session]) {
        for action in Self.notificationActions(
            newSessions: newSessions,
            oldSessions: oldSessions,
            notificationsEnabled: dataSources.notificationsEnabled()
        ) {
            switch action {
            case .remove(let identifier):
                removeNotification(identifier: identifier)
            case .post(let session):
                sendNotification(for: session)
            }
        }
    }

    nonisolated static func notificationActions(
        newSessions: [Session],
        oldSessions: [Session],
        notificationsEnabled: Bool
    ) -> [SessionNotificationAction] {
        let newByStableKey = Dictionary(
            newSessions.map { (SessionIdentityPolicy.stableKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let oldByStableKey = Dictionary(
            oldSessions.map { (SessionIdentityPolicy.stableKey(for: $0), $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var actions: [SessionNotificationAction] = []
        for (key, oldSession) in oldByStableKey where oldSession.shouldPostAttentionNotification {
            guard let newSession = newByStableKey[key],
                  newSession.lifecycle == .active,
                  newSession.shouldPostAttentionNotification else {
                actions.append(.remove(identifier: SessionIdentityPolicy.notificationRequestIdentifier(for: oldSession)))
                continue
            }
        }

        guard notificationsEnabled else { return actions }
        for (key, newSession) in newByStableKey where newSession.lifecycle == .active && newSession.shouldPostAttentionNotification {
            guard let oldSession = oldByStableKey[key],
                  !oldSession.shouldPostAttentionNotification else { continue }
            actions.append(.post(session: newSession))
        }
        return actions
    }

    nonisolated static func notificationRequest(for session: Session) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        let notification = session.notificationContent
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.sound = .default
        content.userInfo = SessionIdentityPolicy.notificationUserInfo(for: session)

        return UNNotificationRequest(
            identifier: SessionIdentityPolicy.notificationRequestIdentifier(for: session),
            content: content,
            trigger: nil
        )
    }

    func postNotification(for session: Session) {
        let stableKey = SessionIdentityPolicy.stableKey(for: session)
        guard !isManuallyHidden(session),
              sessions.contains(where: { SessionIdentityPolicy.stableKey(for: $0) == stableKey }) else {
            return
        }
        let client = dataSources.notificationClient
        let request = Self.notificationRequest(for: session)
        client.removePending([request.identifier])
        client.removeDelivered([request.identifier])
        client.add(request) { error in
            if let error {
                sessionManagerLogger.error("Failed to send notification: \(error, privacy: .public)")
            }
        }
    }

    private func sendNotification(for session: Session) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        sessionManagerLogger.error("Notification permission error: \(error, privacy: .public)")
                    }
                    if granted {
                        self.postNotification(for: session)
                    }
                }
            case .authorized, .provisional, .ephemeral:
                self.postNotification(for: session)
            default:
                break
            }
        }
    }

    private func removeNotification(identifier: String) {
        let client = dataSources.notificationClient
        client.removePending([identifier])
        client.removeDelivered([identifier])
    }
}
