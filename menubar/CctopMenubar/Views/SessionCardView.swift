import SwiftUI

struct SessionCardView: View {
    let session: Session
    @State private var isHovered = false
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(session.status.color)
                .frame(width: 9, height: 9)
                .opacity(session.status.needsAttention && !pulsing ? 0.6 : 1.0)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(session.projectName)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    Text(session.branch)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                if let context = session.contextLine {
                    Text(context)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(session.relativeTime)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(session.status.label)
                    .font(.system(size: 9))
                    .foregroundStyle(session.status.color)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(session.status.color.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(session.status.color.opacity(0.25), lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.primary.opacity(isHovered ? 0.06 : 0.03))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(isHovered ? 0.1 : 0.06), lineWidth: 1))
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onAppear { updatePulsing(for: session.status) }
        .onChange(of: session.status) { updatePulsing(for: $0) }
    }

    private func updatePulsing(for status: SessionStatus) {
        if status.needsAttention {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                pulsing = true
            }
        } else {
            withAnimation(.default) { pulsing = false }
        }
    }
}

#Preview("Working") {
    SessionCardView(session: .mock(status: .working, lastTool: "Bash", lastToolDetail: "cargo test"))
        .frame(width: 300).padding()
}
#Preview("Permission") {
    SessionCardView(session: .mock(status: .waitingPermission, notificationMessage: "Allow Bash: rm -rf"))
        .frame(width: 300).padding()
}
#Preview("Idle") {
    SessionCardView(session: .mock(status: .idle))
        .frame(width: 300).padding()
}
#Preview("Compacting") {
    SessionCardView(session: .mock(status: .compacting))
        .frame(width: 300).padding()
}
