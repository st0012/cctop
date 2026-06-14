import SwiftUI

// MARK: - Previews

@MainActor
private func previewBasePM() -> PluginManager {
    PluginManager(homeDirectory: URL(fileURLWithPath: "/nonexistent"), refreshOnInit: false)
}

@MainActor
private class MockUpdater: UpdaterBase {
    override var canCheckForUpdates: Bool { true }
}

@MainActor
private func previewPM() -> PluginManager {
    let pm = previewBasePM()
    pm.ccInstalled = true
    pm.ocInstalled = true
    pm.ocConfigExists = true
    pm.piInstalled = true
    pm.piConfigExists = true
    pm.codexInstalled = true
    pm.codexConfigExists = true
    pm.codexHookStatus = .trusted
    return pm
}

@MainActor
private func previewPendingCodexTrustPM() -> PluginManager {
    let pm = previewPM()
    pm.codexHookStatus = .installedUntrusted
    return pm
}

#Preview("Default") {
    SettingsSection(updater: DisabledUpdater(), pluginManager: previewBasePM()).frame(width: 320).padding()
}

#Preview("All connected") {
    SettingsSection(updater: DisabledUpdater(), pluginManager: previewPM()).frame(width: 320).padding()
}

#Preview("Codex trust needed") {
    SettingsSection(updater: DisabledUpdater(), pluginManager: previewPendingCodexTrustPM()).frame(width: 320).padding()
}
