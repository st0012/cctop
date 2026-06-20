import XCTest
@testable import CctopMenubar

final class AppSettingsTests: XCTestCase {
    func testAppearanceModeRawValues() {
        XCTAssertEqual(AppearanceMode.system.rawValue, "system")
        XCTAssertEqual(AppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppearanceMode.dark.rawValue, "dark")
    }

    func testAppearanceModeLabels() {
        XCTAssertEqual(AppearanceMode.system.label, "System")
        XCTAssertEqual(AppearanceMode.light.label, "Light")
        XCTAssertEqual(AppearanceMode.dark.label, "Dark")
    }

    func testAllCasesOrder() {
        let cases = AppearanceMode.allCases
        XCTAssertEqual(cases, [.system, .light, .dark])
    }
}

@MainActor
final class NotificationPermissionControllerTests: XCTestCase {
    func testEnableWithAuthorizedPermissionPersistsPreference() {
        let store = NotificationPreferenceStoreSpy(initialValue: false)
        let client = NotificationPermissionClientSpy(statuses: [.authorized])
        let controller = NotificationPermissionController(store: store, client: client)

        controller.enable()

        XCTAssertEqual(controller.state, .enabled)
        XCTAssertEqual(store.savedValues, [true])
        XCTAssertFalse(client.didOpenNotificationSettings)
    }

    func testEnableWithDeniedPermissionKeepsPreferenceOffAndOpensSettings() {
        let store = NotificationPreferenceStoreSpy(initialValue: false)
        let client = NotificationPermissionClientSpy(statuses: [.denied])
        let controller = NotificationPermissionController(store: store, client: client)

        controller.enable()

        XCTAssertEqual(controller.state, .needsSystemPermission)
        XCTAssertEqual(store.savedValues, [false])
        XCTAssertTrue(client.didOpenNotificationSettings)
    }

    func testEnableWithGrantedPromptPersistsAfterRequestSucceeds() {
        let store = NotificationPreferenceStoreSpy(initialValue: false)
        let client = NotificationPermissionClientSpy(
            statuses: [.notDetermined],
            requestResult: .success(true)
        )
        let controller = NotificationPermissionController(store: store, client: client)

        controller.enable()

        XCTAssertEqual(controller.state, .enabled)
        XCTAssertEqual(store.savedValues, [true])
        XCTAssertEqual(client.requestAuthorizationCount, 1)
    }

    func testEnableWithDeniedPromptKeepsPreferenceOffAndOpensSettings() {
        let store = NotificationPreferenceStoreSpy(initialValue: false)
        let client = NotificationPermissionClientSpy(
            statuses: [.notDetermined],
            requestResult: .success(false)
        )
        let controller = NotificationPermissionController(store: store, client: client)

        controller.enable()

        XCTAssertEqual(controller.state, .needsSystemPermission)
        XCTAssertEqual(store.savedValues, [false])
        XCTAssertTrue(client.didOpenNotificationSettings)
    }

    func testEnableWithRequestErrorShowsFailedAndKeepsPreferenceOff() {
        let store = NotificationPreferenceStoreSpy(initialValue: false)
        let client = NotificationPermissionClientSpy(
            statuses: [.notDetermined],
            requestResult: .failure(NSError(domain: "test", code: 1))
        )
        let controller = NotificationPermissionController(store: store, client: client)

        controller.enable()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(store.savedValues, [false])
        XCTAssertFalse(client.didOpenNotificationSettings)
    }

    func testEnableWithUnknownStatusShowsFailedAndKeepsPreferenceOff() {
        let store = NotificationPreferenceStoreSpy(initialValue: false)
        let client = NotificationPermissionClientSpy(statuses: [.unknown])
        let controller = NotificationPermissionController(store: store, client: client)

        controller.enable()

        XCTAssertEqual(controller.state, .failed)
        XCTAssertEqual(store.savedValues, [false])
    }

    func testEnableDoesNotPersistWhilePermissionCheckIsPending() {
        let store = NotificationPreferenceStoreSpy(initialValue: false)
        let client = DeferredNotificationPermissionClientSpy()
        let controller = NotificationPermissionController(store: store, client: client)

        controller.enable()

        XCTAssertEqual(controller.state, .enabling)
        XCTAssertEqual(store.savedValues, [])

        client.completeStatus(.authorized)

        XCTAssertEqual(controller.state, .enabled)
        XCTAssertEqual(store.savedValues, [true])
    }

    func testRefreshAfterSystemSettingsGrantCompletesPendingEnable() {
        let store = NotificationPreferenceStoreSpy(initialValue: false)
        let client = NotificationPermissionClientSpy(statuses: [.authorized])
        let controller = NotificationPermissionController(store: store, client: client, initialState: .needsSystemPermission)

        controller.refresh()

        XCTAssertEqual(controller.state, .enabled)
        XCTAssertEqual(store.savedValues, [true])
    }

    func testRefreshWithLegacyEnabledPreferenceButDeniedPermissionShowsSystemPermissionState() {
        let store = NotificationPreferenceStoreSpy(initialValue: true)
        let client = NotificationPermissionClientSpy(statuses: [.denied])
        let controller = NotificationPermissionController(store: store, client: client)

        controller.refresh()

        XCTAssertEqual(controller.state, .needsSystemPermission)
        XCTAssertEqual(store.savedValues, [false])
    }

    func testRefreshWithNotDeterminedPermissionKeepsPreferenceEnabledForFirstPrompt() {
        let store = NotificationPreferenceStoreSpy(initialValue: true)
        let client = NotificationPermissionClientSpy(statuses: [.notDetermined])
        let controller = NotificationPermissionController(store: store, client: client)

        controller.refresh()

        XCTAssertEqual(controller.state, .pendingSystemPermission)
        XCTAssertTrue(store.notificationsEnabled)
        XCTAssertEqual(store.savedValues, [])
        XCTAssertEqual(store.savedPermissionValues, [])
    }

    func testDisableClearsPendingSystemPermissionPreference() {
        let store = NotificationPreferenceStoreSpy(initialValue: true)
        let client = NotificationPermissionClientSpy(statuses: [.notDetermined])
        let controller = NotificationPermissionController(
            store: store,
            client: client,
            initialState: .pendingSystemPermission
        )

        controller.disable()

        XCTAssertEqual(controller.state, .off)
        XCTAssertFalse(store.notificationsEnabled)
        XCTAssertEqual(store.savedValues, [false])
        XCTAssertEqual(store.savedPermissionValues, [false])
    }

    func testLaunchRefreshPreservesSystemPermissionStateForLaterSettingsController() {
        let store = NotificationPreferenceStoreSpy(initialValue: true)
        let launchClient = NotificationPermissionClientSpy(statuses: [.denied])
        let launchController = NotificationPermissionController(store: store, client: launchClient)

        launchController.refresh()

        XCTAssertEqual(launchController.state, .needsSystemPermission)
        XCTAssertEqual(store.savedValues, [false])
        XCTAssertEqual(store.savedPermissionValues, [true])

        let settingsClient = NotificationPermissionClientSpy(statuses: [.denied])
        let settingsController = NotificationPermissionController(store: store, client: settingsClient)

        XCTAssertEqual(settingsController.state, .needsSystemPermission)

        settingsController.refresh()

        XCTAssertEqual(settingsController.state, .needsSystemPermission)
    }

    func testDisableClearsPreferenceAndState() {
        let store = NotificationPreferenceStoreSpy(initialValue: true)
        let client = NotificationPermissionClientSpy(statuses: [.authorized])
        let controller = NotificationPermissionController(store: store, client: client, initialState: .enabled)

        controller.disable()

        XCTAssertEqual(controller.state, .off)
        XCTAssertEqual(store.savedValues, [false])
    }
}

private final class NotificationPreferenceStoreSpy: NotificationPreferenceStoring {
    private var enabled: Bool
    private var needsPermission: Bool
    private(set) var savedValues: [Bool] = []
    private(set) var savedPermissionValues: [Bool] = []

    init(initialValue: Bool, needsPermission: Bool = false) {
        enabled = initialValue
        self.needsPermission = needsPermission
    }

    var notificationsEnabled: Bool {
        enabled
    }

    var needsSystemNotificationPermission: Bool {
        needsPermission
    }

    func setNotificationsEnabled(_ isEnabled: Bool) {
        enabled = isEnabled
        savedValues.append(isEnabled)
    }

    func setNeedsSystemNotificationPermission(_ needsPermission: Bool) {
        self.needsPermission = needsPermission
        savedPermissionValues.append(needsPermission)
    }
}

private final class NotificationPermissionClientSpy: NotificationPermissionClient {
    private var statuses: [NotificationPermissionStatus]
    private let requestResult: Result<Bool, Error>
    private(set) var requestAuthorizationCount = 0
    private(set) var didOpenNotificationSettings = false

    init(
        statuses: [NotificationPermissionStatus],
        requestResult: Result<Bool, Error> = .success(false)
    ) {
        self.statuses = statuses
        self.requestResult = requestResult
    }

    func getAuthorizationStatus(_ completion: @escaping (NotificationPermissionStatus) -> Void) {
        completion(statuses.isEmpty ? .unknown : statuses.removeFirst())
    }

    func requestAuthorization(_ completion: @escaping (Result<Bool, Error>) -> Void) {
        requestAuthorizationCount += 1
        completion(requestResult)
    }

    func openNotificationSettings() {
        didOpenNotificationSettings = true
    }
}

private final class DeferredNotificationPermissionClientSpy: NotificationPermissionClient {
    private var statusCompletion: ((NotificationPermissionStatus) -> Void)?

    func getAuthorizationStatus(_ completion: @escaping (NotificationPermissionStatus) -> Void) {
        statusCompletion = completion
    }

    func requestAuthorization(_ completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    func openNotificationSettings() {}

    func completeStatus(_ status: NotificationPermissionStatus) {
        statusCompletion?(status)
        statusCompletion = nil
    }
}
