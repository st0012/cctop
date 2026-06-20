import AppKit
import Combine
import Foundation
import UserNotifications

enum NotificationPreferenceState: Equatable {
    case off
    case enabling
    case enabled
    case needsSystemPermission
    case failed
}

enum NotificationPermissionStatus {
    case notDetermined
    case denied
    case authorized
    case provisional
    case ephemeral
    case unknown

    var allowsNotifications: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined, .denied, .unknown:
            return false
        }
    }
}

protocol NotificationPreferenceStoring: AnyObject {
    var notificationsEnabled: Bool { get }
    func setNotificationsEnabled(_ isEnabled: Bool)
}

protocol NotificationPermissionClient: AnyObject {
    func getAuthorizationStatus(_ completion: @escaping (NotificationPermissionStatus) -> Void)
    func requestAuthorization(_ completion: @escaping (Result<Bool, Error>) -> Void)
    func openNotificationSettings()
}

final class NotificationPermissionController: ObservableObject {
    @Published private(set) var state: NotificationPreferenceState

    private let store: NotificationPreferenceStoring
    private let client: NotificationPermissionClient

    init(
        store: NotificationPreferenceStoring = UserDefaultsNotificationPreferenceStore(),
        client: NotificationPermissionClient = UserNotificationPermissionClient(),
        initialState: NotificationPreferenceState? = nil
    ) {
        self.store = store
        self.client = client
        state = initialState ?? (store.notificationsEnabled ? .enabling : .off)
    }

    func refresh() {
        client.getAuthorizationStatus { [weak self] status in
            self?.applyRefreshStatus(status)
        }
    }

    func enable() {
        state = .enabling
        client.getAuthorizationStatus { [weak self] status in
            self?.applyEnableStatus(status)
        }
    }

    func disable() {
        store.setNotificationsEnabled(false)
        state = .off
    }

    func openSystemSettings() {
        client.openNotificationSettings()
    }

    private func applyRefreshStatus(_ status: NotificationPermissionStatus) {
        if status.allowsNotifications {
            if store.notificationsEnabled || state == .needsSystemPermission || state == .enabling {
                store.setNotificationsEnabled(true)
                state = .enabled
            } else {
                state = .off
            }
            return
        }

        switch status {
        case .denied:
            if store.notificationsEnabled {
                store.setNotificationsEnabled(false)
                state = .needsSystemPermission
            } else if state == .needsSystemPermission {
                state = .needsSystemPermission
            } else {
                state = .off
            }
        case .notDetermined:
            if store.notificationsEnabled {
                store.setNotificationsEnabled(false)
            }
            state = .off
        case .unknown:
            if store.notificationsEnabled {
                store.setNotificationsEnabled(false)
            }
            state = .failed
        case .authorized, .provisional, .ephemeral:
            break
        }
    }

    private func applyEnableStatus(_ status: NotificationPermissionStatus) {
        if status.allowsNotifications {
            store.setNotificationsEnabled(true)
            state = .enabled
            return
        }

        switch status {
        case .notDetermined:
            requestSystemPermission()
        case .denied:
            store.setNotificationsEnabled(false)
            state = .needsSystemPermission
            client.openNotificationSettings()
        case .unknown:
            store.setNotificationsEnabled(false)
            state = .failed
        case .authorized, .provisional, .ephemeral:
            break
        }
    }

    private func requestSystemPermission() {
        client.requestAuthorization { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(true):
                store.setNotificationsEnabled(true)
                state = .enabled
            case .success(false):
                store.setNotificationsEnabled(false)
                state = .needsSystemPermission
                client.openNotificationSettings()
            case .failure(let error):
                sessionManagerLogger.error("Notification permission error: \(error, privacy: .public)")
                store.setNotificationsEnabled(false)
                state = .failed
            }
        }
    }
}

private final class UserDefaultsNotificationPreferenceStore: NotificationPreferenceStoring {
    var notificationsEnabled: Bool {
        UserDefaults.standard.bool(forKey: "notificationsEnabled")
    }

    func setNotificationsEnabled(_ isEnabled: Bool) {
        UserDefaults.standard.set(isEnabled, forKey: "notificationsEnabled")
    }
}

private final class UserNotificationPermissionClient: NotificationPermissionClient {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func getAuthorizationStatus(_ completion: @escaping (NotificationPermissionStatus) -> Void) {
        center.getNotificationSettings { settings in
            let status = NotificationPermissionStatus(settings.authorizationStatus)
            DispatchQueue.main.async {
                completion(status)
            }
        }
    }

    func requestAuthorization(_ completion: @escaping (Result<Bool, Error>) -> Void) {
        let wasAccessory = NSApplication.shared.activationPolicy() == .accessory
        if wasAccessory { NSApplication.shared.setActivationPolicy(.regular) }

        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            DispatchQueue.main.async {
                if wasAccessory { NSApplication.shared.setActivationPolicy(.accessory) }
                if let error {
                    completion(.failure(error))
                } else {
                    completion(.success(granted))
                }
            }
        }
    }

    func openNotificationSettings() {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.st0012.CctopMenubar"
        let appSettings = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(bundleID)")

        if let appSettings, NSWorkspace.shared.open(appSettings) {
            return
        }

        if let notifications = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings") {
            NSWorkspace.shared.open(notifications)
        }
    }
}

private extension NotificationPermissionStatus {
    init(_ status: UNAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .denied:
            self = .denied
        case .authorized:
            self = .authorized
        case .provisional:
            self = .provisional
        case .ephemeral:
            self = .ephemeral
        @unknown default:
            self = .unknown
        }
    }
}
