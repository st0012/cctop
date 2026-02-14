import SwiftUI

struct EmptyStateView: View {
    private let ccInstalled: Bool
    private let ocInstalled: Bool
    @State private var copiedIndex: Int?

    private static let ccMarketplace = "claude plugin marketplace add st0012/cctop"
    private static let ccInstall = "claude plugin install cctop"
    private static let ocInstall = "cp -r /Applications/cctop.app/Contents/Resources/opencode-plugin/ ~/.config/opencode/plugins/cctop/"

    init() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser

        let ccDir = home.appendingPathComponent(".claude/plugins/cache/cctop")
        var isDir: ObjCBool = false
        self.ccInstalled = fm.fileExists(atPath: ccDir.path, isDirectory: &isDir) && isDir.boolValue

        let ocPlugin = home.appendingPathComponent(".config/opencode/plugins/cctop/plugin.js")
        self.ocInstalled = fm.fileExists(atPath: ocPlugin.path)
    }

    /// Test-only initializer to force specific plugin states.
    init(ccInstalled: Bool, ocInstalled: Bool) {
        self.ccInstalled = ccInstalled
        self.ocInstalled = ocInstalled
    }

    /// Legacy test initializer — treats pluginInstalled as CC installed.
    init(pluginInstalled: Bool) {
        self.ccInstalled = pluginInstalled
        self.ocInstalled = false
    }

    private var anyInstalled: Bool { ccInstalled || ocInstalled }

    var body: some View {
        VStack(spacing: 16) {
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.amber)
                .frame(width: 36, height: 36)
                .overlay(
                    Text("C")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(.white)
                )
                .padding(.top, 4)

            Text("Monitor your AI coding sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            if anyInstalled {
                installedView
            } else {
                notInstalledView
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    private var installedView: some View {
        VStack(spacing: 8) {
            pluginStatusRow("Claude Code", installed: ccInstalled)
            pluginStatusRow("opencode", installed: ocInstalled)

            Text("Start a session \u{2014} it will appear here automatically.")
                .font(.system(size: 12))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 4)

            Text("Existing sessions need a restart to pick up hooks.")
                .font(.system(size: 11))
                .foregroundStyle(Color.textMuted)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
    }

    private func pluginStatusRow(_ name: String, installed: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: installed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(installed ? .green : Color.textMuted)
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(installed ? Color.textSecondary : Color.textMuted)
            Spacer()
        }
    }

    private var notInstalledView: some View {
        VStack(spacing: 12) {
            // Claude Code setup
            VStack(spacing: 6) {
                sectionHeader("Claude Code")
                commandRow(Self.ccMarketplace, index: 1)
                commandRow(Self.ccInstall, index: 2)
            }

            // opencode setup
            VStack(spacing: 6) {
                sectionHeader("opencode")
                commandRow(Self.ocInstall, index: 3)
            }

            stepRow(text: "Restart sessions after installing")
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
    }

    private func commandRow(_ command: String, index: Int) -> some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedIndex = index
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if copiedIndex == index { copiedIndex = nil }
                }
            } label: {
                Image(systemName: copiedIndex == index ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(copiedIndex == index ? .green : Color.textSecondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func stepRow(text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 10))
                .foregroundStyle(Color.textMuted)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
    }
}

#Preview("Not installed") {
    EmptyStateView(ccInstalled: false, ocInstalled: false)
        .frame(width: 320)
}
#Preview("CC installed") {
    EmptyStateView(ccInstalled: true, ocInstalled: false)
        .frame(width: 320)
}
#Preview("Both installed") {
    EmptyStateView(ccInstalled: true, ocInstalled: true)
        .frame(width: 320)
}
#Preview("OC only") {
    EmptyStateView(ccInstalled: false, ocInstalled: true)
        .frame(width: 320)
}
