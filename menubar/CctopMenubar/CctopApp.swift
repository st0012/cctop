import SwiftUI

@main
struct CctopApp: App {
    var body: some Scene {
        MenuBarExtra("cctop", systemImage: "terminal") {
            Text("cctop placeholder")
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }
}
