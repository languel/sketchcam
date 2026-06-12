import SwiftUI

@main
struct SketchCamApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 120, minHeight: 68)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}

