import SwiftUI

struct OpenCodeBanner: View {
    var pluginManager: PluginManager?
    @Binding var installed: Bool
    @Binding var dismissed: Bool
    @State private var installHovered = false
    @State private var dismissHovered = false

    var body: some View {
        HStack(spacing: 4) {
            if installed {
                Image(systemName: "checkmark")
                    .font(.system(size: 9))
                    .foregroundStyle(.green)
                Text("Installed \u{2014} restart opencode to start tracking")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
            } else {
                Text("Track opencode sessions too?")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.textMuted)
                Spacer()
                Button {
                    if pluginManager?.installOpenCodePlugin() == true {
                        withAnimation { installed = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation { dismissed = true }
                        }
                    }
                } label: {
                    Text("Install")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.amber)
                        .opacity(installHovered ? 1.0 : 0.8)
                        .underline(installHovered)
                }
                .buttonStyle(.plain)
                .onHover { installHovered = $0 }
                Button {
                    withAnimation { dismissed = true }
                } label: {
                    Text("Dismiss")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.textMuted)
                        .opacity(dismissHovered ? 1.0 : 0.7)
                        .underline(dismissHovered)
                }
                .buttonStyle(.plain)
                .onHover { dismissHovered = $0 }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color.amber.opacity(0.05))
    }
}
