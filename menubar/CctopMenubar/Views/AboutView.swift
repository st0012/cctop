import SwiftUI

struct AboutView: View {
    private let repoURL = "https://github.com/st0012/cctop"

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            // App icon + identity
            VStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 64, height: 64)
                Text("cctop")
                    .font(.system(size: 18, weight: .bold))
                Text("Monitor your AI coding sessions")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.textSecondary)
                Text("Version \(version)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.textMuted)
            }
            .padding(.top, 16)
            .padding(.bottom, 14)

            Divider().padding(.horizontal, 14)

            // Credits
            VStack(spacing: 4) {
                HoverLinkButton(
                    label: "\u{00A9} 2025 Stan Lo",
                    url: "https://st0012.dev",
                    font: .system(size: 11),
                    color: Color.textSecondary
                )
                Text("MIT License")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
            }
            .padding(.vertical, 10)

            Divider().padding(.horizontal, 14)

            // Links
            HStack(spacing: 16) {
                linkButton("GitHub", url: repoURL)
                linkButton("Report Issue", url: "\(repoURL)/issues")
            }
            .padding(.vertical, 10)

            // Acknowledgments
            Text("Built with KeyboardShortcuts & Sparkle")
                .font(.system(size: 9))
                .foregroundStyle(Color.textMuted)
                .padding(.bottom, 4)

            // Privacy
            Text("No analytics \u{00B7} No telemetry")
                .font(.system(size: 9))
                .foregroundStyle(Color.textMuted)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
    }

    private func linkButton(_ label: String, url: String) -> some View {
        HoverLinkButton(
            label: label,
            url: url,
            font: .system(size: 11, weight: .medium),
            color: Color.amber,
            showArrow: true
        )
    }
}

private struct HoverLinkButton: View {
    let label: String
    let url: String
    var font: Font = .system(size: 11)
    var color: Color = .amber
    var showArrow: Bool = false
    @State private var isHovered = false

    var body: some View {
        Button {
            if let linkURL = URL(string: url) {
                NSWorkspace.shared.open(linkURL)
            }
        } label: {
            HStack(spacing: 4) {
                Text(label)
                    .font(font)
                    .underline(isHovered)
                if showArrow {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .foregroundStyle(isHovered ? .primary : color)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

#Preview {
    AboutView()
        .frame(width: 320)
        .background(Color.settingsBackground)
        .padding()
}
