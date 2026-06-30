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
                    Button("Default Layout") {
                        appUI.sendLayoutCommand(.reset)
                    }
                    Divider()
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
        rightGroups.flatMap(\.panels)
    }

    private var leftTabs: [ControlTab] {
        leftGroups.flatMap(\.panels)
    }

    private var topTabs: [ControlTab] {
        topGroups.flatMap(\.panels)
    }

    private var bottomTabs: [ControlTab] {
        bottomGroups.flatMap(\.panels)
    }

    private var floatingTabs: [ControlTab] {
        floatingGroups.flatMap(\.panels)
    }

    private var leftGroups: [PanelGroup] {
        groups(from: leftTabsRaw, defaultPanels: ControlTab.defaultLeftPanels)
    }

    private var rightGroups: [PanelGroup] {
        groups(from: visibleTabsRaw, defaultPanels: ControlTab.defaultRightPanels)
    }

    private var topGroups: [PanelGroup] {
        groups(from: topTabsRaw)
    }

    private var bottomGroups: [PanelGroup] {
        groups(from: bottomTabsRaw, defaultPanels: timelineDockVisible ? [.timeline] : [])
    }

    private var floatingGroups: [PanelGroup] {
        groups(from: floatingTabsRaw)
    }

    private func tabs(from rawValue: String) -> [ControlTab] {
        groups(from: rawValue).flatMap(\.panels)
    }

    private func groups(from rawValue: String, defaultPanels: [ControlTab] = []) -> [PanelGroup] {
        guard rawValue != ControlTab.emptyDockValue else { return [] }
        guard !rawValue.isEmpty else {
            return defaultPanels.map { PanelGroup(panels: [$0]) }
        }
        if rawValue.contains("|") || rawValue.contains("+") {
            return rawValue.split(separator: "|").compactMap { groupRaw in
                let panels = groupRaw
                    .split(separator: "+")
                    .compactMap { id in ControlTab.allCases.first(where: { $0.id == String(id) }) }
                return panels.isEmpty ? nil : PanelGroup(panels: panels)
            }
        }
        let ids = rawValue.split(separator: ",").map(String.init)
        return ControlTab.panelGroups(for: ControlTab.allCases.filter { ids.contains($0.id) })
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
        let panels = moveGroup(for: panel)
        panels.forEach(removePanelFromAllDocks)
        var groups = groupsForDock(destination)
        groups.append(PanelGroup(panels: panels))
        setGroups(groups, for: destination)
        if destination == .bottom, panel == .timeline {
            timelineDockVisible = true
        }
    }

    private func moveGroup(for panel: ControlTab) -> [ControlTab] {
        ControlTab.yarnPathGroup.contains(panel) ? ControlTab.yarnPathGroup : [panel]
    }

    private func dockPanelRight(_ panel: ControlTab) {
        movePanel(panel, to: .right)
    }

    private func dockPanelBottom(_ panel: ControlTab) {
        movePanel(panel, to: .bottom)
    }

    private func hidePanel(_ panel: ControlTab) {
        removePanelFromAllDocks(panel)
    }

    private func removePanelFromAllDocks(_ panel: ControlTab) {
        if panel == .timeline {
            timelineDockVisible = false
        }
        for destination in [PanelDropDestination.left, .right, .top, .bottom, .floating] {
            var groups = groupsForDock(destination)
            groups = groups.compactMap { group in
                let panels = group.panels.filter { $0 != panel }
                return panels.isEmpty ? nil : PanelGroup(panels: panels)
            }
            setGroups(groups, for: destination)
        }
    }

    private func groupsForDock(_ destination: PanelDropDestination) -> [PanelGroup] {
        switch destination {
        case .left: return leftGroups
        case .right: return rightGroups
        case .top: return topGroups
        case .bottom: return bottomGroups
        case .floating: return floatingGroups
        }
    }

    private func setGroups(_ groups: [PanelGroup], for destination: PanelDropDestination) {
        switch destination {
        case .left:
            leftTabsRaw = ControlTab.dockStorageValue(for: groups, emptyValue: ControlTab.emptyDockValue)
        case .right:
            visibleTabsRaw = ControlTab.dockStorageValue(for: groups, emptyValue: ControlTab.emptyDockValue)
        case .top:
            topTabsRaw = ControlTab.dockStorageValue(for: groups)
        case .bottom:
            bottomTabsRaw = ControlTab.dockStorageValue(for: groups)
        case .floating:
            floatingTabsRaw = ControlTab.dockStorageValue(for: groups)
        }
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
