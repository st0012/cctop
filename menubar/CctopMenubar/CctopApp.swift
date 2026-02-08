import SwiftUI

@main
struct CctopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // No visible windows — everything is managed by AppDelegate
        // (status item + floating panel)
        Settings { EmptyView() }
    }
}
