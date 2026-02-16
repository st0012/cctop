import Foundation
import Security

// MARK: - Updater Protocol

/// Abstraction over the update mechanism. `DisabledUpdater` is used for debug builds,
/// Homebrew installs, and unsigned builds. `SparkleUpdater` wraps SPUStandardUpdaterController
/// when Sparkle is available.
@MainActor
class UpdaterBase: NSObject, ObservableObject {
    @Published var pendingUpdateVersion: String?

    var canCheckForUpdates: Bool { false }
    var disabledReason: DisabledReason? { nil }
    func checkForUpdates() {}
}

// MARK: - Disabled Updater

enum DisabledReason {
    case development
    case unsigned

    var reasonText: String {
        switch self {
        case .development: return "Updates unavailable in development builds."
        case .unsigned: return "Updates unavailable in this build."
        }
    }
}

@MainActor
final class DisabledUpdater: UpdaterBase {
    private let reason: DisabledReason?

    init(reason: DisabledReason? = nil) {
        self.reason = reason
        super.init()
    }

    override var disabledReason: DisabledReason? { reason }
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
        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = true
        controller.startUpdater()
    }

    override var canCheckForUpdates: Bool { true }

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
            if choice != .dismiss {
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

    let summary = SecCertificateCopySubjectSummary(leaf) as String?
    return summary?.hasPrefix("Developer ID Application:") == true
}

@MainActor
func makeUpdater() -> UpdaterBase {
    let bundleURL = Bundle.main.bundleURL
    let isBundledApp = bundleURL.pathExtension == "app"

    guard isBundledApp else {
        return DisabledUpdater(reason: .development)
    }

    #if canImport(Sparkle) && ENABLE_SPARKLE
    guard isDeveloperIDSigned(bundleURL: bundleURL) else {
        return DisabledUpdater(reason: .unsigned)
    }
    return SparkleUpdater()
    #else
    return DisabledUpdater(reason: .unsigned)
    #endif
}
