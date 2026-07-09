import SwiftUI

extension PopupView {
    func overlayPanel<Content: View>(
        verticalPadding: CGFloat = AppChrome.overlayContentVerticalPadding,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, minHeight: AppChrome.overlayMinimumContentHeight, alignment: .top)
            .background {
                PanelSurfaceBackground(usesMaterial: false)
            }
            .transition(.asymmetric(
                insertion: .move(edge: .top),
                removal: .modifier(
                    active: RollUpEffect(progress: 0),
                    identity: RollUpEffect(progress: 1)
                )
            ))
    }

    var noActiveSessionsContent: some View {
        emptyPlaceholder(
            systemImage: "circle.dotted",
            title: "No active sessions",
            detail: PopupTab.active.emptyStateDetail
        )
    }

    var noIdleSessionsContent: some View {
        emptyPlaceholder(
            systemImage: "moon",
            title: "No idle sessions",
            detail: PopupTab.idle.emptyStateDetail
        )
    }

    func emptyPlaceholder(systemImage: String, title: String, detail: String? = nil) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Color.textMuted)
            VStack(spacing: 2) {
                Text(title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.textMuted)
                    .multilineTextAlignment(.center)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}
