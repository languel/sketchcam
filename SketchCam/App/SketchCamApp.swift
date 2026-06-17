import SwiftUI

@main
struct SketchCamApp: App {
    @StateObject private var appUI = AppUIState()
    @AppStorage("visibleControlTabs") private var visibleTabsRaw: String = ""

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
            CommandGroup(after: .toolbar) {
                Divider()
                Text("Show tabs")
                ForEach(ControlTab.allCases) { tab in
                    Button {
                        toggleTabVisible(tab)
                    } label: {
                        Label(tab.rawValue, systemImage: isTabVisible(tab) ? "checkmark" : "")
                    }
                }
                Divider()
                Button("Toggle Performance Overlay") {
                    appUI.toggleDebugOverlay()
                }
                .keyboardShortcut("p", modifiers: [.control, .option])
            }
        }
        .windowStyle(.titleBar)
        .windowResizability(.contentMinSize)
    }

    private var visibleTabs: [ControlTab] {
        ControlTab.visibleTabs(from: visibleTabsRaw)
    }

    private func isTabVisible(_ tab: ControlTab) -> Bool {
        visibleTabs.contains(tab)
    }

    private func toggleTabVisible(_ tab: ControlTab) {
        var tabs = Set(visibleTabs)
        if tabs.contains(tab) { tabs.remove(tab) } else { tabs.insert(tab) }
        guard !tabs.isEmpty else { return }
        visibleTabsRaw = ControlTab.storageValue(for: tabs)
    }
}
