import SwiftUI

struct SmartBarView: View {
    let sessions: [Session]
    var onTap: (() -> Void)?

    private var counts: (permission: Int, attention: Int, working: Int, idle: Int) {
        HeaderView.statusCounts(for: sessions)
    }

    private var needsAttention: Bool {
        counts.permission > 0 || counts.attention > 0
    }

    var body: some View {
        let content = HStack(spacing: 8) {
            // Logo
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.amber.opacity(needsAttention ? 1.0 : 0.5))
                .frame(width: 16, height: 16)
                .overlay(
                    Text("C")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                )

            if counts.permission > 0 {
                miniChip(count: counts.permission, color: .red)
            }
            if counts.attention > 0 {
                miniChip(count: counts.attention, color: Color.amber)
            }
            if counts.working > 0 {
                miniChip(count: counts.working, color: Color.statusGreen)
            }
            if counts.idle > 0 {
                Text("+\(counts.idle)")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary.opacity(0.6))
            }

            // Disclosure chevron
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Color.secondary.opacity(0.4))
        }
        .padding(.horizontal, 12)
        .frame(height: 32)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())

        if let onTap {
            Button(action: onTap) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }

    private func miniChip(count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text("\(count)")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(color)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

// MARK: - Translucent pill wrapper

struct TranslucentPill<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(white: 0.15, opacity: 0.55))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
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
