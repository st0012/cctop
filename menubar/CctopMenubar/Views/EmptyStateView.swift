import SwiftUI

struct EmptyStateView: View {
    private let pluginInstalled: Bool
    @State private var copiedIndex: Int?

    private static let marketplaceCommand = "claude plugin marketplace add st0012/cctop"
    private static let installCommand = "claude plugin install cctop"

    init() {
        let pluginDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/plugins/cache/cctop")
        var isDir: ObjCBool = false
        self.pluginInstalled = FileManager.default.fileExists(
            atPath: pluginDir.path, isDirectory: &isDir
        ) && isDir.boolValue
    }

    /// Test-only initializer to force a specific plugin state.
    init(pluginInstalled: Bool) {
        self.pluginInstalled = pluginInstalled
    }

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

            Text("Monitor your Claude Code sessions")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            if pluginInstalled {
                installedView
            } else {
                notInstalledView
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity)
    }

    private var notInstalledView: some View {
        VStack(spacing: 10) {
            stepRow(number: "1", text: "Add the cctop marketplace")
            commandRow(Self.marketplaceCommand, index: 1)

            stepRow(number: "2", text: "Install the plugin")
            commandRow(Self.installCommand, index: 2)

            stepRow(number: "3", text: "Restart Claude Code sessions")
            stepRow(number: "4", text: "Sessions will appear here automatically")
        }
    }

    private func commandRow(_ command: String, index: Int) -> some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(copiedIndex == index ? .green : .secondary)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var installedView: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                Text("Plugin installed")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Text("Start a Claude Code session \u{2014} it will appear here automatically.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Text("Existing sessions need a restart to pick up hooks.")
                .font(.system(size: 11))
                .foregroundStyle(.quaternary)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
    }

    private func stepRow(number: String, text: String) -> some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Color.amber)
                .clipShape(Circle())
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

#Preview("Not installed") {
    EmptyStateView(pluginInstalled: false)
        .frame(width: 320)
}
#Preview("Installed") {
    EmptyStateView(pluginInstalled: true)
        .frame(width: 320)
}
