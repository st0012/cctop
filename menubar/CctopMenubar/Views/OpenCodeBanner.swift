import SwiftUI

struct ToolInstallBanner: View {
    let toolName: String
    let iconLabel: String
    let iconColor: Color
    let installAction: () -> Bool
    @Binding var installed: Bool
    @Binding var dismissed: Bool
    @State private var installHovered = false
    @State private var dismissHovered = false
    @State private var bannerHovered = false

    var body: some View {
        Group {
            if installed {
                installedBanner
            } else {
                promptBanner
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 2)
    }

    // MARK: - Prompt state

    private var promptBanner: some View {
        HStack(spacing: 8) {
            toolIcon
            Text("\(toolName) found \u{2014} track sessions?")
                .font(.system(size: 10))
                .foregroundStyle(Color.textSecondary)
            Spacer(minLength: 0)
            installButton
            dismissButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius)
                .fill(iconColor.opacity(bannerHovered ? 0.08 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius)
                .strokeBorder(iconColor.opacity(0.10), lineWidth: 1)
        )
        .onHover { bannerHovered = $0 }
    }

    private var installButton: some View {
        Button {
            if installAction() {
                withAnimation { installed = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { dismissed = true }
                }
            }
        } label: {
            Text("Install")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(installHovered ? .white : iconColor)
                .padding(.horizontal, 10)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius)
                        .fill(installHovered ? iconColor : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius)
                        .strokeBorder(
                            iconColor.opacity(installHovered ? 0 : 0.3),
                            lineWidth: 1
                        )
                )
        }
        .buttonStyle(.plain)
        .onHover { installHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: installHovered)
    }

    private var dismissButton: some View {
        Button {
            withAnimation { dismissed = true }
        } label: {
            Text("\u{00D7}")
                .font(.system(size: 14))
                .foregroundStyle(
                    dismissHovered ? Color.textSecondary : Color.textDimmed
                )
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius)
                        .fill(dismissHovered ? Color.panelSelectionBackground : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { dismissHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: dismissHovered)
    }

    // MARK: - Installed state

    private var installedBanner: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.statusGreen)
            Text("Installed \u{2014} restart \(toolName) to start tracking")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius)
                .fill(Color.statusGreen.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppChrome.groupCornerRadius)
                .strokeBorder(Color.statusGreen.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: - Tool icon

    private var toolIcon: some View {
        Text(iconLabel)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(iconColor)
            .frame(width: 20, height: 20)
            .background(
                RoundedRectangle(cornerRadius: AppChrome.controlCornerRadius)
                    .fill(iconColor.opacity(0.12))
            )
    }
}
