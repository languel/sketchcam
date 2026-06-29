import SwiftUI

@main
struct SketchCamApp: App {
    @StateObject private var appUI = AppUIState()
    @AppStorage(LayoutStorageKeys.visibleTabs) private var visibleTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.bottomTabs) private var bottomTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.timelineDockVisible) private var timelineDockVisible = true

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
            CommandMenu("Panels") {
                Button("Show All Panels") {
                    appUI.sendLayoutCommand(.showAll)
                }
                Button("Reset Panel Layout") {
                    appUI.sendLayoutCommand(.reset)
                }
                Button("Show Timeline") {
                    appUI.sendLayoutCommand(.showTimeline)
                }
                Divider()
                ForEach(ControlTab.allCases) { tab in
                    Menu(tab.rawValue) {
                        Button("Dock Right") { dockPanelRight(tab) }
                        Button("Dock Bottom") { dockPanelBottom(tab) }
                        Button("Hide") { hidePanel(tab) }
                        Divider()
                        Text(panelPlacementText(tab))
                    }
                }
                Divider()
                Menu("Layout Presets") {
                    ForEach(1...3, id: \.self) { slot in
                        Button("Save Layout \(slot)") {
                            appUI.sendLayoutCommand(.save(slot: slot))
                        }
                        Button("Restore Layout \(slot)") {
                            appUI.sendLayoutCommand(.restore(slot: slot))
                        }
                        Button("Delete Layout \(slot)") {
                            appUI.sendLayoutCommand(.delete(slot: slot))
                        }
                        if slot != 3 { Divider() }
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

    private var bottomTabs: [ControlTab] {
        tabs(from: bottomTabsRaw)
    }

    private func tabs(from rawValue: String) -> [ControlTab] {
        guard !rawValue.isEmpty else { return [] }
        let ids = Set(rawValue.split(separator: ",").map(String.init))
        return ControlTab.allCases.filter { ids.contains($0.id) }
    }

    private func isTabVisible(_ tab: ControlTab) -> Bool {
        visibleTabs.contains(tab)
    }

    private func isTabDockedBottom(_ tab: ControlTab) -> Bool {
        bottomTabs.contains(tab)
    }

    private func dockPanelRight(_ panel: ControlTab) {
        var right = Set(visibleTabs)
        var bottom = Set(bottomTabs)
        right.insert(panel)
        bottom.remove(panel)
        visibleTabsRaw = ControlTab.storageValue(for: right)
        bottomTabsRaw = ControlTab.storageValue(for: bottom)
    }

    private func dockPanelBottom(_ panel: ControlTab) {
        var right = Set(visibleTabs)
        var bottom = Set(bottomTabs)
        right.remove(panel)
        bottom.insert(panel)
        visibleTabsRaw = ControlTab.storageValue(for: right)
        bottomTabsRaw = ControlTab.storageValue(for: bottom)
        timelineDockVisible = true
    }

    private func hidePanel(_ panel: ControlTab) {
        var right = Set(visibleTabs)
        var bottom = Set(bottomTabs)
        right.remove(panel)
        bottom.remove(panel)
        if right.isEmpty && bottom.isEmpty {
            right.insert(.layers)
        }
        visibleTabsRaw = ControlTab.storageValue(for: right)
        bottomTabsRaw = ControlTab.storageValue(for: bottom)
    }

    private func panelPlacementText(_ panel: ControlTab) -> String {
        if isTabVisible(panel) { return "Currently: Right" }
        if isTabDockedBottom(panel) { return "Currently: Bottom" }
        return "Currently: Hidden"
    }
}
