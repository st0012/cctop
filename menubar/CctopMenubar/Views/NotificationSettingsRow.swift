import SwiftUI

struct NotificationSettingsRow: View {
    @ObservedObject var notificationPermission: NotificationPermissionController

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Notifications")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                if let statusText {
                    Text(statusText)
                        .font(.system(size: 10))
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            action
            Toggle("", isOn: toggleBinding)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(notificationPermission.state == .enabling)
        }
        .padding(.horizontal, AppChrome.settingsRowHorizontalPadding)
        .padding(.vertical, 8)
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: {
                notificationPermission.state == .enabled
                    || notificationPermission.state == .pendingSystemPermission
            },
            set: { isEnabled in
                if isEnabled {
                    notificationPermission.enable()
                } else {
                    notificationPermission.disable()
                }
            }
        )
    }

    private var statusText: String? {
        switch notificationPermission.state {
        case .off, .enabled:
            return nil
        case .enabling:
            return "Checking macOS permission"
        case .pendingSystemPermission:
            return "Will ask on first notification"
        case .needsSystemPermission:
            return "Enable in System Settings"
        case .failed:
            return "Could not enable"
        }
    }

    private var statusColor: Color {
        notificationPermission.state == .failed ? Color.statusAttention : Color.textMuted
    }

    @ViewBuilder
    private var action: some View {
        switch notificationPermission.state {
        case .needsSystemPermission:
            Button("Open Settings") {
                notificationPermission.openSystemSettings()
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.segmentActiveText)
            .buttonStyle(.plain)
        case .failed:
            Button("Retry") {
                notificationPermission.enable()
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Color.statusAttention)
            .buttonStyle(.plain)
        case .off, .enabling, .enabled, .pendingSystemPermission:
            EmptyView()
        }
    }
}
