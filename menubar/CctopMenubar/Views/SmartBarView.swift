import SwiftUI

struct SmartBarView: View {
    let sessions: [Session]
    var onTap: (() -> Void)?

    var body: some View {
        let counts = HeaderView.statusCounts(for: sessions)
        let needsAttention = counts.permission > 0 || counts.attention > 0
        let content = HStack(spacing: 3) {
            // Logo
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.amber.opacity(needsAttention ? 1.0 : 0.5))
                .frame(width: 10, height: 10)
                .overlay(
                    Text("C")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.white)
                )
                .padding(.trailing, 2)

            microNum(counts.permission, color: .red)
            microNum(counts.attention, color: Color.amber)
            microNum(counts.working, color: Color.statusGreen)
            microNum(counts.idle, color: Color.secondary)

            // Disclosure chevron
            Image(systemName: "chevron.down")
                .font(.system(size: 6, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.4))
                .padding(.leading, 2)
        }
        .padding(.horizontal, 7)
        .frame(height: 16)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())

        if let onTap {
            Button(action: onTap) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private func microNum(_ count: Int, color: Color) -> some View {
        Text("\(count)")
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(color.opacity(count > 0 ? 1.0 : 0.25))
            .frame(minWidth: 12, minHeight: 11)
            .background(color.opacity(count > 0 ? 0.12 : 0.05))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
}

// MARK: - Translucent pill wrapper

struct TranslucentPill<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(.ultraThinMaterial.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    }
}

// MARK: - Previews

#Preview("Smart Bar") {
    VStack(spacing: 20) {
        TranslucentPill {
            SmartBarView(sessions: [
                .mock(status: .working, lastTool: "Edit"),
                .mock(status: .working, lastTool: "Bash"),
                .mock(status: .idle),
                .mock(status: .idle),
            ])
        }
        TranslucentPill {
            SmartBarView(sessions: [
                .mock(status: .waitingPermission),
                .mock(status: .waitingInput),
                .mock(status: .working, lastTool: "Edit"),
                .mock(status: .idle),
            ])
        }
    }
    .padding(24)
    .frame(width: 360)
}

#Preview("Smart Bar Tappable") {
    TranslucentPill {
        SmartBarView(sessions: Session.qaShowcase, onTap: {})
    }
    .padding(24)
    .frame(width: 360)
}
