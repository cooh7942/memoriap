import SwiftUI

@main
struct MemoriapApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1400, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
