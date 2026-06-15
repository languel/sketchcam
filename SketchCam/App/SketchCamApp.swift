import SwiftUI

@main
struct SketchCamApp: App {
    @StateObject private var appUI = AppUIState()

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
                .environmentObject(appUI)
                .frame(minWidth: 120, minHeight: 68)
        }
        .commands {
            CommandMenu("View") {
                Button("Toggle Performance Overlay") {
                    appUI.toggleDebugOverlay()
                }
                .keyboardShortcut("p", modifiers: [.control, .option])
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }
}
