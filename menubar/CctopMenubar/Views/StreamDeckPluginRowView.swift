import SwiftUI

struct StreamDeckPluginRowView: View {
    @ObservedObject var pluginManager: PluginManager
    @State private var justInstalled = false
    @State private var pluginOperationFailed = false
    @State private var profileFailed = false
    @State private var removeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            primaryRow
            if pluginManager.sdInstalled { profileRow }
            statusMessage
        }
        .padding(.vertical, 7)
    }

    private var primaryRow: some View {
        HStack(spacing: 8) {
            Text("Stream Deck")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if pluginManager.sdNeedsUpdate {
                installButton("Update Plugin")
            } else if pluginManager.sdInstalled {
                ConnectedBadge()
                removeButton
            } else {
                installButton("Install Plugin")
            }
        }
    }

    private var profileRow: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Default layout")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                Text("Five session keys + panel toggle")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.textMuted)
            }
            Spacer(minLength: 6)
            Button("Import default profile") {
                profileFailed = !pluginManager.importStreamDeckProfile()
            }
            .font(.system(size: 10, weight: .semibold))
            .buttonStyle(.plain)
            .foregroundStyle(Color.segmentActiveText)
            .help("Open Stream Deck to import cctop's default profile")
            .accessibilityLabel("Import cctop Stream Deck default profile")
            .accessibilityHint("Opens Stream Deck to confirm importing cctop's default profile.")
        }
    }

    private var removeButton: some View {
        Button {
            if !pluginManager.removeStreamDeckPlugin() { flashPluginOperationFailure() }
        } label: {
            Text("Remove")
                .font(.system(size: 10))
                .foregroundStyle(removeHovered ? Color.textPrimary : Color.textMuted)
        }
        .buttonStyle(.plain)
        .onHover { removeHovered = $0 }
        .help("Remove cctop's plugin; Stream Deck profiles remain unchanged")
        .accessibilityLabel("Remove cctop Stream Deck plugin")
    }

    @ViewBuilder private var statusMessage: some View {
        if justInstalled {
            inlineStatus(
                "Installed — open Stream Deck to use it",
                icon: "checkmark",
                color: Color.statusGreen
            )
        } else if pluginOperationFailed {
            inlineStatus(
                "Could not change Stream Deck plugin",
                icon: "exclamationmark.triangle",
                color: Color.amber
            )
        } else if profileFailed {
            inlineStatus(
                "Could not open the default profile",
                icon: "exclamationmark.triangle",
                color: Color.amber
            )
        }
    }

    private func installButton(_ label: String) -> some View {
        AmberActionButton(label: label) {
            if pluginManager.installStreamDeckPlugin() {
                justInstalled = true
                pluginOperationFailed = false
                profileFailed = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { justInstalled = false }
            } else {
                flashPluginOperationFailure()
            }
        }
    }

    private func inlineStatus(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).font(.system(size: 10))
        }
        .foregroundStyle(color)
        .transition(.opacity)
    }

    private func flashPluginOperationFailure() {
        pluginOperationFailed = true
        justInstalled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pluginOperationFailed = false }
    }
}
