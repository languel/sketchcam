import SwiftUI

@main
struct SketchCamApp: App {
    init() {
        #if DEBUG
        // One-shot GPU smoke checks (write results to container tmp).
        DispatchQueue.global(qos: .utility).async {
            MetalLineRenderer.runSelfCheck()
            MetalEffects.runSelfCheck()
            MetalInkEngine.runSelfCheck()
        }
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
