import SwiftUI

struct StreamDeckPluginRowView: View {
    @ObservedObject var pluginManager: PluginManager
    @State private var justInstalled = false
    @State private var pluginOperationFailed = false
    @State private var profileFailed = false
    @State private var removeHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            primaryRow
            if pluginManager.sdInstalled {
                rowDivider
                profileRow
            }
            statusMessage
        }
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
        .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
        .padding(.vertical, 4)
        .frame(minHeight: 25)
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
        .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
        .padding(.vertical, 4)
        .frame(minHeight: 25)
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
            statusRow(
                "Installed — open Stream Deck to use it",
                icon: "checkmark",
                iconColor: Color.statusGreen,
                textColor: Color.statusWorkingText
            )
        } else if pluginOperationFailed {
            statusRow(
                "Could not change Stream Deck plugin",
                icon: "exclamationmark.triangle",
                iconColor: Color.amber,
                textColor: Color.statusAttentionText
            )
        } else if profileFailed {
            statusRow(
                "Could not open the default profile",
                icon: "exclamationmark.triangle",
                iconColor: Color.amber,
                textColor: Color.statusAttentionText
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

    private var rowDivider: some View {
        Rectangle()
            .fill(Color.groupedRowBorder)
            .frame(height: 0.5)
    }

    private func statusRow(
        _ text: String,
        icon: String,
        iconColor: Color,
        textColor: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            rowDivider
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9))
                    .foregroundStyle(iconColor)
                Text(text)
                    .font(.system(size: 10))
                    .foregroundStyle(textColor)
            }
            .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
            .padding(.vertical, 4)
            .frame(minHeight: 25)
        }
        .transition(.opacity)
    }

    private func flashPluginOperationFailure() {
        pluginOperationFailed = true
        justInstalled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { pluginOperationFailed = false }
    }
}
