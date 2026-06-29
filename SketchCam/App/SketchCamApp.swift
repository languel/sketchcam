import SwiftUI

@main
struct SketchCamApp: App {
    @StateObject private var appUI = AppUIState()
    @AppStorage(LayoutStorageKeys.visibleTabs) private var visibleTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.leftTabs) private var leftTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.topTabs) private var topTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.bottomTabs) private var bottomTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.floatingTabs) private var floatingTabsRaw: String = ""
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
                        Button("Dock Left") { movePanel(tab, to: .left) }
                        Button("Dock Right") { dockPanelRight(tab) }
                        Button("Dock Top") { movePanel(tab, to: .top) }
                        Button("Dock Bottom") { dockPanelBottom(tab) }
                        Button("Float") { movePanel(tab, to: .floating) }
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

    private var leftTabs: [ControlTab] {
        tabs(from: leftTabsRaw)
    }

    private var topTabs: [ControlTab] {
        tabs(from: topTabsRaw)
    }

    private var bottomTabs: [ControlTab] {
        tabs(from: bottomTabsRaw)
    }

    private var floatingTabs: [ControlTab] {
        tabs(from: floatingTabsRaw)
    }

    private func tabs(from rawValue: String) -> [ControlTab] {
        guard rawValue != ControlTab.emptyDockValue else { return [] }
        guard !rawValue.isEmpty else { return [] }
        let ids = Set(rawValue.split(separator: ",").map(String.init))
        return ControlTab.allCases.filter { ids.contains($0.id) }
    }

    private func panelLocation(_ tab: ControlTab) -> PanelDropDestination? {
        if leftTabs.contains(tab) { return .left }
        if visibleTabs.contains(tab) { return .right }
        if topTabs.contains(tab) { return .top }
        if bottomTabs.contains(tab) { return .bottom }
        if floatingTabs.contains(tab) { return .floating }
        return nil
    }

    private func movePanel(_ panel: ControlTab, to destination: PanelDropDestination) {
        var left = Set(leftTabs)
        var right = Set(visibleTabs)
        var top = Set(topTabs)
        var bottom = Set(bottomTabs)
        var floating = Set(floatingTabs)
        left.remove(panel)
        bottom.remove(panel)
        right.remove(panel)
        top.remove(panel)
        floating.remove(panel)
        switch destination {
        case .left:
            left.insert(panel)
        case .right:
            right.insert(panel)
        case .top:
            top.insert(panel)
        case .bottom:
            bottom.insert(panel)
            timelineDockVisible = true
        case .floating:
            floating.insert(panel)
        }
        leftTabsRaw = ControlTab.storageValue(for: left)
        visibleTabsRaw = ControlTab.rightDockStorageValue(for: right)
        topTabsRaw = ControlTab.storageValue(for: top)
        bottomTabsRaw = ControlTab.storageValue(for: bottom)
        floatingTabsRaw = ControlTab.storageValue(for: floating)
    }

    private func dockPanelRight(_ panel: ControlTab) {
        movePanel(panel, to: .right)
    }

    private func dockPanelBottom(_ panel: ControlTab) {
        movePanel(panel, to: .bottom)
    }

    private func hidePanel(_ panel: ControlTab) {
        var left = Set(leftTabs)
        var right = Set(visibleTabs)
        var top = Set(topTabs)
        var bottom = Set(bottomTabs)
        var floating = Set(floatingTabs)
        left.remove(panel)
        right.remove(panel)
        top.remove(panel)
        bottom.remove(panel)
        floating.remove(panel)
        leftTabsRaw = ControlTab.storageValue(for: left)
        visibleTabsRaw = ControlTab.rightDockStorageValue(for: right)
        topTabsRaw = ControlTab.storageValue(for: top)
        bottomTabsRaw = ControlTab.storageValue(for: bottom)
        floatingTabsRaw = ControlTab.storageValue(for: floating)
    }

    private func panelPlacementText(_ panel: ControlTab) -> String {
        switch panelLocation(panel) {
        case .left: return "Currently: Left"
        case .right: return "Currently: Right"
        case .top: return "Currently: Top"
        case .bottom: return "Currently: Bottom"
        case .floating: return "Currently: Floating"
        case nil: break
        }
        return "Currently: Hidden"
    }
}
