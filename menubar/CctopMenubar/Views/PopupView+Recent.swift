import SwiftUI

extension PopupView {
    @ViewBuilder
    var recentContent: some View {
        if recentTargets.isEmpty {
            emptyPlaceholder(systemImage: "clock", title: "No recent items yet\nFinished projects and archived sessions appear here")
        } else {
            panelList(recentTargets, tab: .recent) { _, target, isSelected in
                recentCard(target, isSelected: isSelected)
            }
        }
    }

    var recentTargets: [RecentResumeTarget] {
        recentResumeTargets ?? recentProjects.map(RecentResumeTarget.project)
    }

    func recentCard(_ target: RecentResumeTarget, isSelected: Bool = false) -> some View {
        RecentProjectCardView(target: target, isSelected: isSelected, relativeTimeNow: relativeTimeNow)
            .contentShape(Rectangle())
            .onTapGesture { openRecentResumeTarget(target); NSApp.deactivate() }
            .contextMenu {
                Button { openRecentResumeTarget(target); NSApp.deactivate() } label: {
                    Label(target.openActionLabel, systemImage: target.icon)
                }
                if target.showsFinderAction {
                    Button { openInFinder(path: target.projectPath) } label: { Label("Open Project in Finder", systemImage: "folder") }
                }
                if target.showsCopyPathAction {
                    Button { copyPath(target.projectPath) } label: {
                        Label("Copy Project Path", systemImage: "doc.on.doc")
                    }
                }
            }
            .help(target.openHelpText)
    }
}
