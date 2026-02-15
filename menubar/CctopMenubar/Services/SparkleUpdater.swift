import Foundation
import Security

// MARK: - Updater Protocol

/// Abstraction over the update mechanism. `DisabledUpdater` is used for debug builds,
/// Homebrew installs, and unsigned builds. `SparkleUpdater` wraps SPUStandardUpdaterController
/// when Sparkle is available.
@MainActor
class UpdaterBase: ObservableObject {
    @Published var pendingUpdateVersion: String?

    var canCheckForUpdates: Bool { false }
    var disabledReason: String? { nil }
    func checkForUpdates() {}
}

// MARK: - Disabled Updater

@MainActor
final class DisabledUpdater: UpdaterBase {
    private let reason: String?

    init(reason: String? = nil) {
        self.reason = reason
        super.init()
    }

    override var canCheckForUpdates: Bool { false }
    override var disabledReason: String? { reason }
}

// MARK: - Sparkle Updater

#if canImport(Sparkle) && ENABLE_SPARKLE
import Sparkle

@MainActor
final class SparkleUpdater: UpdaterBase, @preconcurrency SPUUpdaterDelegate {
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false,
        updaterDelegate: self,
        userDriverDelegate: nil)

    override init() {
        super.init()
        let updater = controller.updater
        let autoUpdate = (UserDefaults.standard.object(forKey: "autoUpdateEnabled") as? Bool) ?? true
        updater.automaticallyChecksForUpdates = autoUpdate
        updater.automaticallyDownloadsUpdates = autoUpdate
        controller.startUpdater()
    }

    override var canCheckForUpdates: Bool { true }
    override var disabledReason: String? { nil }

    override func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        Task { @MainActor in
            self.pendingUpdateVersion = item.displayVersionString
        }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor in
            switch choice {
            case .install, .skip:
                self.pendingUpdateVersion = nil
            case .dismiss:
                break
            @unknown default:
                self.pendingUpdateVersion = nil
            }
        }
    }
}
#endif

// MARK: - Factory

private func isDeveloperIDSigned(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
          let code = staticCode else { return false }

    var infoCF: CFDictionary?
    guard SecCodeCopySigningInformation(
        code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF
    ) == errSecSuccess,
          let info = infoCF as? [String: Any],
          let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
          let leaf = certs.first else { return false }

    if let summary = SecCertificateCopySubjectSummary(leaf) as String? {
        return summary.hasPrefix("Developer ID Application:")
    }
    return false
}

@MainActor
func makeUpdater() -> UpdaterBase {
    let bundleURL = Bundle.main.bundleURL
    let isBundledApp = bundleURL.pathExtension == "app"

    guard isBundledApp else {
        return DisabledUpdater(reason: "Updates unavailable in development builds.")
    }

    if InstallOrigin.isHomebrewCask(appBundleURL: bundleURL) {
        return DisabledUpdater(reason: "Updates managed by Homebrew.")
    }

    #if canImport(Sparkle) && ENABLE_SPARKLE
    guard isDeveloperIDSigned(bundleURL: bundleURL) else {
        return DisabledUpdater(reason: "Updates unavailable in this build.")
    }
    return SparkleUpdater()
    #else
    return DisabledUpdater(reason: "Updates unavailable in this build.")
    #endif
}
