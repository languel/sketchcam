import SwiftUI

@main
struct SketchCamApp: App {
    init() {
        #if DEBUG
        // One-shot GPU renderer smoke check (writes result to container tmp).
        DispatchQueue.global(qos: .utility).async { MetalLineRenderer.runSelfCheck() }
        #endif
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 120, minHeight: 68)
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}

