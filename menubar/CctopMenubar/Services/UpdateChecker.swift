import Foundation
import os.log

private let logger = Logger(subsystem: "com.st0012.CctopMenubar", category: "UpdateChecker")

@MainActor
class UpdateChecker: ObservableObject {
    @Published var updateAvailable: String?

    private static let checkInterval: TimeInterval = 24 * 3600
    private static let lastCheckedKey = "updateLastChecked"
    private static let latestVersionKey = "updateLatestVersion"
    private static let releaseURL = URL(string: "https://api.github.com/repos/st0012/cctop/releases/latest")!
    static let releasesPageURL = URL(string: "https://github.com/st0012/cctop/releases/latest")!

    private var timer: Timer?

    init() {
        // Restore cached result
        if let cached = UserDefaults.standard.string(forKey: Self.latestVersionKey),
           isNewer(cached) {
            updateAvailable = cached
        }
        checkIfNeeded()
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkIfNeeded()
            }
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func checkIfNeeded() {
        let lastChecked = UserDefaults.standard.double(forKey: Self.lastCheckedKey)
        let elapsed = Date().timeIntervalSince1970 - lastChecked
        guard elapsed >= Self.checkInterval else { return }
        check()
    }

    private func check() {
        var request = URLRequest(url: Self.releaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        Task {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    logger.warning("Update check failed: non-200 response")
                    return
                }
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tagName = json["tag_name"] as? String else {
                    logger.warning("Update check: could not parse tag_name")
                    return
                }
                let version = tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckedKey)
                UserDefaults.standard.set(version, forKey: Self.latestVersionKey)
                if isNewer(version) {
                    logger.info("Update available: \(version, privacy: .public)")
                    updateAvailable = version
                } else {
                    updateAvailable = nil
                }
            } catch {
                logger.warning("Update check error: \(error, privacy: .public)")
            }
        }
    }

    private func isNewer(_ remoteVersion: String) -> Bool {
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else {
            return false
        }
        return remoteVersion.compare(current, options: .numeric) == .orderedDescending
    }
}
