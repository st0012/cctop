import Foundation

/// Drives the Codex install → trust onboarding shared by the Settings row
/// and the empty state. Installing is step one of two — Codex still has to
/// trust the hooks — so the flow shows a brief spinner instead of a success
/// flash and then opens the trust walkthrough itself, before the user can
/// leave the screen thinking setup is done.
///
/// Each surface owns its own instance: the walkthrough popover must anchor
/// to the control that started the install, never to another view's.
/// Views keep all presentation (labels, hints, failure styling); the flow
/// owns only the behavior.
@MainActor
final class CodexSetupFlow: ObservableObject {
    @Published private(set) var isInstalling = false
    @Published var showWalkthrough = false

    /// Spinner hold before revealing the result. The install itself is
    /// near-instant file IO and runs before the delay starts — only the
    /// reveal is paced, so a failure can never hide behind the spinner.
    private static let revealDelay: TimeInterval = 0.6

    func runInstall(using pluginManager: PluginManager, onFailure: @escaping () -> Void) {
        guard !isInstalling else { return }
        isInstalling = true
        let success = pluginManager.installCodexPlugin()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.revealDelay) { [weak self] in
            guard let self else { return }
            self.isInstalling = false
            if !success {
                onFailure()
            } else if pluginManager.codexHookStatus.needsTrust {
                // One-tick hop so the trust button renders before the popover
                // binding flips — NSPopover needs a live anchor view. Not a
                // redundant dispatch; removing it can drop the presentation.
                DispatchQueue.main.async { self.showWalkthrough = true }
            }
        }
    }
}
