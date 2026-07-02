import AppKit
import SketchCamCore
import SketchCamShared
import SwiftUI
import UniformTypeIdentifiers

final class AppUIState: ObservableObject {
    @Published var debugOverlayVisible = false
    @Published var layoutCommand: LayoutCommand?

    func toggleDebugOverlay() {
        debugOverlayVisible.toggle()
    }

    func sendLayoutCommand(_ command: LayoutCommand) {
        layoutCommand = command
    }
}

enum LayoutCommand: Equatable {
    case showAll
    case reset
    case save(slot: Int)
    case restore(slot: Int)
    case delete(slot: Int)
}

struct LayoutSnapshot: Codable {
    var visibleTabsRaw: String
    var leftTabsRaw: String
    var topTabsRaw: String
    var bottomTabsRaw: String
    var floatingTabsRaw: String
    var floatingPanelPositionsRaw: String
    var floatingPanelSizesRaw: String
    var timelineDockVisible: Bool
    var leftDockCollapsed: Bool
    var rightDockCollapsed: Bool
    var topDockCollapsed: Bool
    var bottomDockCollapsed: Bool
    var leftDockSize: Double
    var rightDockSize: Double
    var topDockSize: Double
    var bottomDockSize: Double
    var minimizedPanelsRaw: String
    var inspectorVisible: Bool
    var inspectorFit: Bool

    init(
        visibleTabsRaw: String,
        leftTabsRaw: String,
        topTabsRaw: String,
        bottomTabsRaw: String,
        floatingTabsRaw: String,
        floatingPanelPositionsRaw: String,
        floatingPanelSizesRaw: String,
        timelineDockVisible: Bool,
        leftDockCollapsed: Bool,
        rightDockCollapsed: Bool,
        topDockCollapsed: Bool,
        bottomDockCollapsed: Bool,
        leftDockSize: Double,
        rightDockSize: Double,
        topDockSize: Double,
        bottomDockSize: Double,
        minimizedPanelsRaw: String,
        inspectorVisible: Bool,
        inspectorFit: Bool
    ) {
        self.visibleTabsRaw = visibleTabsRaw
        self.leftTabsRaw = leftTabsRaw
        self.topTabsRaw = topTabsRaw
        self.bottomTabsRaw = bottomTabsRaw
        self.floatingTabsRaw = floatingTabsRaw
        self.floatingPanelPositionsRaw = floatingPanelPositionsRaw
        self.floatingPanelSizesRaw = floatingPanelSizesRaw
        self.timelineDockVisible = timelineDockVisible
        self.leftDockCollapsed = leftDockCollapsed
        self.rightDockCollapsed = rightDockCollapsed
        self.topDockCollapsed = topDockCollapsed
        self.bottomDockCollapsed = bottomDockCollapsed
        self.leftDockSize = leftDockSize
        self.rightDockSize = rightDockSize
        self.topDockSize = topDockSize
        self.bottomDockSize = bottomDockSize
        self.minimizedPanelsRaw = minimizedPanelsRaw
        self.inspectorVisible = inspectorVisible
        self.inspectorFit = inspectorFit
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        visibleTabsRaw = try container.decodeIfPresent(String.self, forKey: .visibleTabsRaw) ?? ""
        leftTabsRaw = try container.decodeIfPresent(String.self, forKey: .leftTabsRaw) ?? ""
        topTabsRaw = try container.decodeIfPresent(String.self, forKey: .topTabsRaw) ?? ""
        bottomTabsRaw = try container.decodeIfPresent(String.self, forKey: .bottomTabsRaw) ?? ""
        floatingTabsRaw = try container.decodeIfPresent(String.self, forKey: .floatingTabsRaw) ?? ""
        floatingPanelPositionsRaw = try container.decodeIfPresent(String.self, forKey: .floatingPanelPositionsRaw) ?? ""
        floatingPanelSizesRaw = try container.decodeIfPresent(String.self, forKey: .floatingPanelSizesRaw) ?? ""
        timelineDockVisible = try container.decodeIfPresent(Bool.self, forKey: .timelineDockVisible) ?? true
        leftDockCollapsed = try container.decodeIfPresent(Bool.self, forKey: .leftDockCollapsed) ?? false
        rightDockCollapsed = try container.decodeIfPresent(Bool.self, forKey: .rightDockCollapsed) ?? false
        topDockCollapsed = try container.decodeIfPresent(Bool.self, forKey: .topDockCollapsed) ?? false
        bottomDockCollapsed = try container.decodeIfPresent(Bool.self, forKey: .bottomDockCollapsed) ?? false
        leftDockSize = try container.decodeIfPresent(Double.self, forKey: .leftDockSize) ?? 320
        rightDockSize = try container.decodeIfPresent(Double.self, forKey: .rightDockSize) ?? 360
        topDockSize = try container.decodeIfPresent(Double.self, forKey: .topDockSize) ?? 190
        bottomDockSize = try container.decodeIfPresent(Double.self, forKey: .bottomDockSize) ?? 220
        minimizedPanelsRaw = try container.decodeIfPresent(String.self, forKey: .minimizedPanelsRaw) ?? ""
        inspectorVisible = try container.decodeIfPresent(Bool.self, forKey: .inspectorVisible) ?? true
        inspectorFit = try container.decodeIfPresent(Bool.self, forKey: .inspectorFit) ?? true
    }
}

enum LayoutStorageKeys {
    static let visibleTabs = "visibleControlTabs"
    static let leftTabs = "leftControlTabs"
    static let topTabs = "topControlTabs"
    static let bottomTabs = "bottomControlTabs"
    static let floatingTabs = "floatingControlTabs"
    static let floatingPanelPositions = "floatingControlPanelPositions"
    static let floatingPanelSizes = "floatingControlPanelSizes"
    static let inkToolbarControls = "inkToolbarControls"
    static let timelineDockVisible = "timelineDockVisible"
    static let leftDockCollapsed = "leftDockCollapsed"
    static let rightDockCollapsed = "rightDockCollapsed"
    static let topDockCollapsed = "topDockCollapsed"
    static let bottomDockCollapsed = "bottomDockCollapsed"
    static let leftDockSize = "leftDockSize"
    static let rightDockSize = "rightDockSize"
    static let topDockSize = "topDockSize"
    static let bottomDockSize = "bottomDockSize"
    static let minimizedPanels = "minimizedPanels"

    static func preset(_ slot: Int) -> String {
        "layoutPreset.\(slot)"
    }
}

enum PanelDropDestination: Hashable {
    case left
    case right
    case top
    case bottom
    case floating
}

private struct PanelInsertTarget: Equatable {
    var destination: PanelDropDestination
    var beforeGroupID: String?
}

struct PanelGroup: Identifiable, Equatable {
    var panels: [ControlTab]

    var id: String {
        panels.map(\.id).joined(separator: "+")
    }

    var activeDefault: ControlTab? {
        panels.first
    }
}

enum ControlTab: String, CaseIterable, Identifiable {
    case toolbar = "Toolbar"
    case inkToolbar = "Ink Toolbar"
    case layers = "Layers"
    case camera = "Camera"
    case movie = "Movie"
    case marks = "Marks"
    case yarn = "Yarn"
    case wrap = "Wrap"
    case lineWalk = "Line walk"
    case ink = "Ink"
    case paper = "Paper"
    case history = "History"
    case timeline = "Timeline"
    case web = "Web"
    case presets = "Presets"
    case keys = "Keys"
    case debug = "Debug"
    case input = "Settings"

    var id: String { rawValue }

    static let defaultLeftPanels: [ControlTab] = [.camera, .movie, .input]
    static let defaultTopPanels: [ControlTab] = [.toolbar, .inkToolbar]
    static let defaultRightPanels: [ControlTab] = [.layers, .paper, .ink]
    static let defaultVisible: Set<ControlTab> = Set(defaultLeftPanels + defaultTopPanels + defaultRightPanels)
    static let yarnPathGroup: [ControlTab] = [.yarn, .wrap, .lineWalk]
    static let emptyDockValue = "__empty__"

    static func visibleTabs(from rawValue: String) -> [ControlTab] {
        guard rawValue != emptyDockValue else { return [] }
        guard !rawValue.isEmpty else {
            return allCases.filter { defaultVisible.contains($0) }
        }
        let ids = Set(rawValue.split(separator: ",").map(String.init))
        let shown = allCases.filter { ids.contains($0.id) }
        return shown.isEmpty ? allCases.filter { defaultVisible.contains($0) } : shown
    }

    static func storageValue(for tabs: Set<ControlTab>) -> String {
        allCases
            .filter { tabs.contains($0) }
            .map { $0.id }
            .joined(separator: ",")
    }

    static func rightDockStorageValue(for tabs: Set<ControlTab>) -> String {
        tabs.isEmpty ? emptyDockValue : storageValue(for: tabs)
    }

    static func dockStorageValue(for groups: [PanelGroup], emptyValue: String = "") -> String {
        guard !groups.isEmpty else { return emptyValue }
        return groups
            .map { group in group.panels.map(\.id).joined(separator: "+") }
            .joined(separator: "|")
    }

    static func panelSet(from rawValue: String) -> Set<ControlTab> {
        let ids = Set(rawValue.split(separator: ",").map(String.init))
        return Set(allCases.filter { ids.contains($0.id) })
    }

    static func panelGroups(for panels: [ControlTab]) -> [PanelGroup] {
        var used = Set<ControlTab>()
        return panels.compactMap { panel in
            guard !used.contains(panel) else { return nil }
            if yarnPathGroup.contains(panel) {
                let grouped = yarnPathGroup.filter { panels.contains($0) }
                used.formUnion(grouped)
                return grouped.isEmpty ? nil : PanelGroup(panels: grouped)
            }
            used.insert(panel)
            return PanelGroup(panels: [panel])
        }
    }

    var icon: String {
        switch self {
        case .toolbar: "wrench.and.screwdriver"
        case .inkToolbar: "paintpalette"
        case .input: "gearshape"
        case .camera: "camera"
        case .movie: "film"
        case .layers: "square.3.layers.3d"
        case .marks: "point.3.connected.trianglepath.dotted"
        case .yarn: "scribble.variable"
        case .wrap: "figure.stand"
        case .lineWalk: "lasso"
        case .ink: "paintbrush.pointed"
        case .paper: "doc.text.image"
        case .history: "clock.arrow.circlepath"
        case .timeline: "timeline.selection"
        case .web: "globe"
        case .presets: "bookmark"
        case .keys: "keyboard"
        case .debug: "ladybug"
        }
    }
}

private enum InkTool: String, CaseIterable, Identifiable {
    case draw = "Draw"
    case select = "Select"
    case points = "Points"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .draw: "pencil.tip"
        case .select: "cursorarrow"
        case .points: "point.3.connected.trianglepath.dotted"
        }
    }
}

private enum ToolbarControlID: String, CaseIterable, Identifiable {
    case mode = "mode"
    case inkKind = "inkKind"
    case hue = "hue"
    case smooth = "smooth"
    case penSize = "penSize"
    case washSize = "washSize"
    case smear = "smear"
    case flow = "flow"
    case bleed = "bleed"
    case dry = "dry"
    case wetDecay = "wetDecay"
    case fade = "fade"
    case colorSeparation = "colorSeparation"
    case brushInk = "brushInk"
    case fix = "fix"
    case clear = "clear"
    case save = "save"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mode: "Mode"
        case .inkKind: "Ink"
        case .hue: "Hue"
        case .smooth: "Smooth"
        case .penSize: "Pen size"
        case .washSize: "Wash size"
        case .smear: "Smear"
        case .flow: "Flow"
        case .bleed: "Bleed"
        case .dry: "Dry"
        case .wetDecay: "Wet decay"
        case .fade: "Fade"
        case .colorSeparation: "Color"
        case .brushInk: "Brush ink"
        case .fix: "Fix"
        case .clear: "Clear"
        case .save: "Save"
        }
    }

    var compactTitle: String {
        switch self {
        case .penSize: "Size"
        case .washSize: "Wash"
        case .wetDecay: "Wet"
        case .colorSeparation: "Color"
        case .brushInk: "Brush"
        default: title
        }
    }

    var icon: String {
        switch self {
        case .mode: "paintbrush.pointed"
        case .inkKind: "drop"
        case .hue: "paintpalette"
        case .smooth: "scribble"
        case .penSize: "slider.horizontal.3"
        case .washSize: "paintbrush"
        case .smear: "tornado"
        case .flow: "wind"
        case .bleed: "drop.degreesign"
        case .dry: "sun.max"
        case .wetDecay: "humidity"
        case .fade: "timer"
        case .colorSeparation: "camera.filters"
        case .brushInk: "drop.fill"
        case .fix: "pin"
        case .clear: "trash"
        case .save: "square.and.arrow.down"
        }
    }

    static let defaultInkToolbar: [ToolbarControlID] = [
        .mode, .inkKind, .hue, .penSize, .flow, .bleed, .dry, .colorSeparation, .brushInk, .fix, .clear
    ]

    static func controls(from rawValue: String) -> [ToolbarControlID] {
        guard !rawValue.isEmpty else { return defaultInkToolbar }
        let controls = rawValue
            .split(separator: ",")
            .compactMap { ToolbarControlID(rawValue: String($0)) }
        return controls.isEmpty ? defaultInkToolbar : controls
    }

    static func storageValue(for controls: [ToolbarControlID]) -> String {
        controls.map(\.id).joined(separator: ",")
    }
}

struct ContentView: View {
    @ObservedObject var model: SketchCamViewModel
    @StateObject private var windowMode = WindowModeController()
    @StateObject private var presetStore = PresetStore()
    @EnvironmentObject private var appUI: AppUIState
    @Environment(\.openWindow) private var openWindow
    @State private var newPresetName = ""
    @State private var recallWholeState = false
    @State private var webURLField = ""
    @State private var webSnippetField = ""
    @ObservedObject private var shortcuts = ShortcutRegistry.shared
    @State private var movieURLField = ""
    @State private var tab = ControlTab.layers
    @State private var bottomTabID = ControlTab.ink.id
    /// Comma-separated ids of the tabs shown in the tab bar. Empty = default visible tabs.
    @AppStorage(LayoutStorageKeys.visibleTabs) private var visibleTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.leftTabs) private var leftTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.topTabs) private var topTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.bottomTabs) private var bottomTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.floatingTabs) private var floatingTabsRaw: String = ""
    @AppStorage(LayoutStorageKeys.floatingPanelPositions) private var floatingPanelPositionsRaw: String = ""
    @AppStorage(LayoutStorageKeys.floatingPanelSizes) private var floatingPanelSizesRaw: String = ""
    @AppStorage(LayoutStorageKeys.inkToolbarControls) private var inkToolbarControlsRaw: String = ""
    @AppStorage(LayoutStorageKeys.timelineDockVisible) private var timelineDockVisible = true
    @AppStorage(LayoutStorageKeys.leftDockCollapsed) private var leftDockCollapsed = false
    @AppStorage(LayoutStorageKeys.rightDockCollapsed) private var rightDockCollapsed = false
    @AppStorage(LayoutStorageKeys.topDockCollapsed) private var topDockCollapsed = false
    @AppStorage(LayoutStorageKeys.bottomDockCollapsed) private var bottomDockCollapsed = false
    @AppStorage(LayoutStorageKeys.leftDockSize) private var leftDockSize = 320.0
    @AppStorage(LayoutStorageKeys.rightDockSize) private var rightDockSize = 360.0
    @AppStorage(LayoutStorageKeys.topDockSize) private var topDockSize = 190.0
    @AppStorage(LayoutStorageKeys.bottomDockSize) private var bottomDockSize = 220.0
    @AppStorage(LayoutStorageKeys.minimizedPanels) private var minimizedPanelsRaw = ""
    @AppStorage(InkUndoPreferences.gpuStateCountKey)
    private var inkUndoGPUStateCount = InkUndoPreferences.defaultGPUStateCount
    @State private var inkTool = InkTool.draw
    @State private var selectedInkPathID: UUID?
    @State private var selectedInkPointIndex: Int?
    @State private var inkPaperSettingsExpanded = false
    @State private var inkMaterialMapExpanded = false
    @State private var debugOverlayOffset = CGSize.zero
    @State private var draggingPanel: ControlTab?
    @State private var dockDragBaselines: [PanelDropDestination: CGFloat] = [:]
    @State private var dockDragStartLocations: [PanelDropDestination: CGFloat] = [:]
    @State private var liveDockSizes: [PanelDropDestination: Double] = [:]
    @State private var dockResizeActive = false
    @State private var selectedPanelByGroup: [String: String] = [:]
    @State private var layoutBeforePresentation: LayoutSnapshot?
    @State private var floatingDockDestination: PanelDropDestination?
    @State private var leftDockDropTargeted = false
    @State private var rightDockDropTargeted = false
    @State private var topDockDropTargeted = false
    @State private var bottomDockDropTargeted = false
    @State private var floatingDockDropTargeted = false
    @State private var floatingDragOrigins: [String: CGPoint] = [:]
    @State private var floatingDragOffsets: [String: CGSize] = [:]
    @State private var panelDragLocation: CGPoint?
    @State private var panelDragGhost: ControlTab?
    @State private var panelGroupFrames: [String: CGRect] = [:]
    @State private var panelTabFrames: [String: CGRect] = [:]
    @State private var panelDockTarget: PanelDropDestination?
    @State private var panelGroupTargetID: String?
    @State private var panelInsertTarget: PanelInsertTarget?
    @State private var floatingResizeOrigins: [String: CGSize] = [:]
    @State private var floatingResizePositionOrigins: [String: CGPoint] = [:]
    @State private var floatingResizeLiveSizes: [String: CGSize] = [:]
    @State private var floatingResizeLivePositions: [String: CGPoint] = [:]
    @State private var hoveredFloatingResizeGroupID: String?
    @State private var workspaceRootSize = CGSize(width: 1200, height: 800)

    init(model: SketchCamViewModel) {
        self.model = model
    }

    var body: some View {
        dockedWorkspace
        .transaction { transaction in
            if dockResizeActive {
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        }
        .overlay { debugOverlay }
        .background(windowMode.transparent ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor(controller: windowMode))
        .background(FocusEscapeHandler())
        .background {
            TitlebarAccessory(isVisible: windowMode.decorated) {
                panelChromeTitlebarControls
            }
        }
        .onAppear {
            model.start()
            model.prepareInkStrokeRecordsForCurrentSettings()
            model.reconcileWorkspaceWithGraph()
            ensureInkToolbarPanelVisible()
            registerShortcuts()
            ShortcutRegistry.shared.start()
        }
        .onReceive(appUI.$layoutCommand.compactMap { $0 }) { command in
            applyLayoutCommand(command)
            appUI.layoutCommand = nil
        }
        .onChange(of: windowMode.presentationMode) { _, isPresentation in
            syncLayoutWithPresentationMode(isPresentation)
        }
        .onDisappear { model.stop() }
    }

    private var dockedWorkspace: some View {
        HStack(spacing: 0) {
            if !leftTabs.isEmpty, floatingDockDestination != .left {
                dockSection(title: "Left", systemImage: "rectangle.leftthird.inset.filled", groups: leftGroups, destination: .left, isCollapsed: $leftDockCollapsed)
                    .frame(width: leftDockCollapsed ? 0 : dockSize(.left, stored: leftDockSize))
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .trailing) {
                        if !leftDockCollapsed {
                            dockResizeHandle(destination: .left, isCollapsed: $leftDockCollapsed, size: $leftDockSize)
                        }
                    }
            }
            canvasDock
            if windowMode.panelVisible && windowMode.panelFit && !visibleTabs.isEmpty {
                dockSection(title: "Right", systemImage: "rectangle.rightthird.inset.filled", groups: rightGroups, destination: .right, isCollapsed: $rightDockCollapsed)
                    .frame(width: rightDockCollapsed ? 0 : dockSize(.right, stored: rightDockSize))
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .leading) {
                        if !rightDockCollapsed {
                            dockResizeHandle(destination: .right, isCollapsed: $rightDockCollapsed, size: $rightDockSize)
                        }
                    }
            }
        }
        .overlay {
            floatingDockOverlay
        }
        .overlay {
            if windowMode.panelVisible && !windowMode.panelFit && !visibleTabs.isEmpty {
                GeometryReader { _ in
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        dockSection(title: "Right", systemImage: "rectangle.rightthird.inset.filled", groups: rightGroups, destination: .right, isCollapsed: $rightDockCollapsed)
                            .frame(width: rightDockCollapsed ? 0 : dockSize(.right, stored: rightDockSize))
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
                            .overlay(alignment: .leading) {
                                if !rightDockCollapsed {
                                    dockResizeHandle(destination: .right, isCollapsed: $rightDockCollapsed, size: $rightDockSize)
                                }
                            }
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            floatingPanelsOverlay
        }
        .overlay {
            panelDockTargetOverlay
        }
        .overlay {
            panelDragGhostOverlay
        }
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { workspaceRootSize = geo.size }
                    .onChange(of: geo.size) { _, newSize in
                        workspaceRootSize = newSize
                    }
            }
        }
        .coordinateSpace(name: "workspaceRoot")
    }

    @ViewBuilder private var panelDragGhostOverlay: some View {
        if let ghost = panelDragGhost, let location = panelDragLocation {
            Label(ghost.rawValue, systemImage: ghost.icon)
                .labelStyle(.iconOnly)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.primary)
                .frame(width: 22, height: 22)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.92))
                .overlay {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.65), lineWidth: 1.5)
                }
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: Color.black.opacity(0.24), radius: 10, y: 4)
                .position(x: location.x, y: location.y)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder private var panelDockTargetOverlay: some View {
        if draggingPanel != nil {
            GeometryReader { geo in
                ZStack {
                    dockEdgeTargetView(.left, size: geo.size)
                    dockEdgeTargetView(.right, size: geo.size)
                    dockEdgeTargetView(.top, size: geo.size)
                    dockEdgeTargetView(.bottom, size: geo.size)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func dockEdgeTargetView(_ destination: PanelDropDestination, size: CGSize) -> some View {
        let active = panelDockTarget == destination
        let thickness: CGFloat = active ? 8 : 2
        let opacity = active ? 0.75 : 0.18
        return Rectangle()
            .fill(Color.accentColor.opacity(opacity))
            .frame(
                width: destination == .left || destination == .right ? thickness : nil,
                height: destination == .top || destination == .bottom ? thickness : nil
            )
            .overlay {
                if active {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dockEdgeAlignment(destination))
    }

    private func dockEdgeAlignment(_ destination: PanelDropDestination) -> Alignment {
        switch destination {
        case .left: return .leading
        case .right: return .trailing
        case .top: return .top
        case .bottom: return .bottom
        case .floating: return .center
        }
    }

    private var canvasDock: some View {
        VStack(spacing: 0) {
            if !topTabs.isEmpty, floatingDockDestination != .top {
                dockSection(title: "Top", systemImage: "rectangle.topthird.inset.filled", groups: topGroups, destination: .top, isCollapsed: $topDockCollapsed)
                    .frame(height: topDockCollapsed ? 34 : topDockHeight)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .bottom) {
                        dockResizeHandle(destination: .top, isCollapsed: $topDockCollapsed, size: $topDockSize)
                    }
            }
            previewPane
            if !bottomTabs.isEmpty, floatingDockDestination != .bottom {
                bottomDock
                    .frame(height: bottomDockCollapsed ? 34 : dockSize(.bottom, stored: bottomDockSize))
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .top) {
                        dockResizeHandle(destination: .bottom, isCollapsed: $bottomDockCollapsed, size: $bottomDockSize)
                    }
            }
        }
        .frame(minWidth: 120, minHeight: 68)
    }

    private var bottomDock: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !bottomDockCollapsed {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(bottomGroups) { group in
                            panelInsertGap(destination: .bottom, beforeGroupID: group.id)
                            panelGroupCard(group, destination: .bottom)
                        }
                        panelInsertGap(destination: .bottom, beforeGroupID: nil)
                    }
                    .padding(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .dockDropHighlight(isTargeted: bottomDockDropTargeted || panelDockTarget == .bottom)
        .onDrop(of: [UTType.plainText], isTargeted: $bottomDockDropTargeted) { providers in
            handlePanelDrop(providers, destination: .bottom)
        }
    }

    @ViewBuilder private var floatingDockOverlay: some View {
        GeometryReader { _ in
            switch floatingDockDestination {
            case .left:
                if !leftTabs.isEmpty {
                    HStack(spacing: 0) {
                        dockSection(title: "Left", systemImage: "rectangle.leftthird.inset.filled", groups: leftGroups, destination: .left, isCollapsed: $leftDockCollapsed)
                            .frame(width: leftDockCollapsed ? 0 : dockSize(.left, stored: leftDockSize))
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
                        Spacer(minLength: 0)
                    }
                }
            case .top:
                if !topTabs.isEmpty {
                    VStack(spacing: 0) {
                        dockSection(title: "Top", systemImage: "rectangle.topthird.inset.filled", groups: topGroups, destination: .top, isCollapsed: $topDockCollapsed)
                            .frame(height: topDockCollapsed ? 34 : topDockHeight)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
                        Spacer(minLength: 0)
                    }
                }
            case .bottom:
                if !bottomTabs.isEmpty {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        bottomDock
                            .frame(height: bottomDockCollapsed ? 34 : dockSize(.bottom, stored: bottomDockSize))
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.94))
                    }
                }
            case .right, .floating, nil:
                EmptyView()
            }
        }
    }

    private var panelChromeTitlebarControls: some View {
        HStack(spacing: 18) {
            dockToolbarButton(
                destination: .left,
                systemImage: "rectangle.leftthird.inset.filled",
                isAvailable: !leftTabs.isEmpty,
                isActive: !leftDockCollapsed && !leftTabs.isEmpty,
                help: leftDockCollapsed ? "Expand left dock" : "Minimize left dock"
            )
            dockToolbarButton(
                destination: .top,
                systemImage: "rectangle.topthird.inset.filled",
                isAvailable: !topTabs.isEmpty,
                isActive: !topDockCollapsed && !topTabs.isEmpty,
                help: topDockCollapsed ? "Expand top dock" : "Minimize top dock"
            )
            dockToolbarButton(
                destination: .bottom,
                systemImage: "rectangle.bottomthird.inset.filled",
                isAvailable: !bottomTabs.isEmpty,
                isActive: !bottomDockCollapsed && !bottomTabs.isEmpty,
                help: bottomDockCollapsed ? "Expand bottom dock" : "Minimize bottom dock"
            )
            dockToolbarButton(
                destination: .right,
                systemImage: "rectangle.rightthird.inset.filled",
                isAvailable: !visibleTabs.isEmpty,
                isActive: windowMode.panelVisible && !rightDockCollapsed && !visibleTabs.isEmpty,
                help: rightDockCollapsed || !windowMode.panelVisible ? "Expand right dock" : "Minimize right dock"
            )

            Menu {
                Button("Show All Panels") { showAllPanels() }
                Button("Default Layout") { resetLayout() }
                Divider()
                dockMenu(destination: .left, title: "Left Dock", isCollapsed: leftDockCollapsed, hasPanels: !leftTabs.isEmpty)
                dockMenu(destination: .top, title: "Top Dock", isCollapsed: topDockCollapsed, hasPanels: !topTabs.isEmpty)
                dockMenu(destination: .bottom, title: "Bottom Dock", isCollapsed: bottomDockCollapsed, hasPanels: !bottomTabs.isEmpty)
                dockMenu(destination: .right, title: "Right Dock", isCollapsed: rightDockCollapsed || !windowMode.panelVisible, hasPanels: !visibleTabs.isEmpty)
            } label: {
                Label("Panel layout", systemImage: "slider.horizontal.3")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.plain)
            .fixedSize()
            .help("Panel layout")

            Button {
                appUI.toggleDebugOverlay()
            } label: {
                Image(systemName: appUI.debugOverlayVisible ? "chart.line.uptrend.xyaxis.circle.fill" : "chart.line.uptrend.xyaxis.circle")
            }
            .buttonStyle(.plain)
            .help("Toggle performance overlay")
        }
        .font(.system(size: 16, weight: .medium))
        .controlSize(.small)
        .padding(.trailing, 14)
        .frame(height: 28)
    }

    @ViewBuilder private func dockMenu(
        destination: PanelDropDestination,
        title: String,
        isCollapsed: Bool,
        hasPanels: Bool
    ) -> some View {
        Menu(title) {
            Button(isCollapsed ? "Show" : "Hide") {
                setDock(destination, hidden: !isCollapsed)
            }
            .disabled(!hasPanels)
            Button(isDockFloating(destination) ? "Dock" : "Float") {
                toggleDockFloating(destination)
            }
            .disabled(!hasPanels || destination == .floating)
        }
    }

    private func dockToolbarButton(
        destination: PanelDropDestination,
        systemImage: String,
        isAvailable: Bool,
        isActive: Bool,
        help: String
    ) -> some View {
        Button {
            toggleDockFromToolbar(destination)
        } label: {
            Image(systemName: systemImage)
                .symbolVariant(isActive ? .fill : .none)
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .disabled(!isAvailable)
        .foregroundStyle(isActive ? Color.primary : Color.secondary)
        .help(help)
    }

    private func toggleDockFromToolbar(_ destination: PanelDropDestination) {
        switch destination {
        case .left:
            toggleLeftDockSide()
        case .right:
            toggleRightDockSide()
        case .top:
            topDockCollapsed.toggle()
        case .bottom:
            bottomDockCollapsed.toggle()
        case .floating:
            break
        }
    }

    private func toggleLeftDockSide() {
        guard !leftTabs.isEmpty else { return }
        leftDockCollapsed.toggle()
    }

    private func toggleRightDockSide() {
        guard !visibleTabs.isEmpty else { return }
        if !windowMode.panelVisible {
            windowMode.panelVisible = true
            rightDockCollapsed = false
        } else {
            rightDockCollapsed.toggle()
        }
    }

    private func setDock(_ destination: PanelDropDestination, hidden: Bool) {
        switch destination {
        case .left:
            guard !leftTabs.isEmpty else { return }
            leftDockCollapsed = hidden
        case .right:
            guard !visibleTabs.isEmpty else { return }
            if hidden {
                rightDockCollapsed = true
            } else {
                windowMode.panelVisible = true
                rightDockCollapsed = false
            }
        case .top:
            guard !topTabs.isEmpty else { return }
            topDockCollapsed = hidden
        case .bottom:
            guard !bottomTabs.isEmpty else { return }
            bottomDockCollapsed = hidden
        case .floating:
            break
        }
    }

    private func isDockFloating(_ destination: PanelDropDestination) -> Bool {
        switch destination {
        case .right:
            return windowMode.panelVisible && !windowMode.panelFit
        case .left, .top, .bottom:
            return floatingDockDestination == destination
        case .floating:
            return false
        }
    }

    private func toggleDockFloating(_ destination: PanelDropDestination) {
        switch destination {
        case .right:
            guard !visibleTabs.isEmpty else { return }
            windowMode.panelVisible = true
            windowMode.panelFit.toggle()
            rightDockCollapsed = false
        case .left, .top, .bottom:
            guard !groupsForDock(destination).isEmpty else { return }
            floatingDockDestination = floatingDockDestination == destination ? nil : destination
            setDock(destination, hidden: false)
        case .floating:
            break
        }
    }

    private var timelineSummary: some View {
            HStack(spacing: 10) {
                TimelineMetric(label: "Strokes", value: "\(inkStrokeRecords.count)")
                TimelineMetric(label: "Editable", value: "\(inkStrokeRecords.filter(\.isEditable).count)")
                TimelineMetric(label: "Immediate", value: "\(inkStrokeRecords.filter { !$0.isEditable }.count)")
                Divider()
                    .frame(height: 40)
                Text("Timeline controls will land here; records already preserve timing, order, and render recipes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
    }

    @ViewBuilder private var debugOverlay: some View {
        if appUI.debugOverlayVisible {
            LiveDebugOverlay(
                live: model.live,
                permission: model.cameraPermissionState.rawValue,
                threshold: model.settings.threshold,
                error: model.errorText,
                close: { appUI.debugOverlayVisible = false },
                offset: $debugOverlayOffset
            )
            .padding(.trailing, 14)
            .padding(.vertical, 14)
            .transition(.move(edge: .trailing).combined(with: .opacity))
            .zIndex(100)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        }
    }

    // MARK: - Preview

    private var previewPane: some View {
        GeometryReader { geo in
            let outputRect = workspaceOutputRect(
                container: geo.size,
                outputSize: model.outputFormat.size,
                workspace: model.settings.workspace
            )
            ZStack {
                // Checkerboard backdrop so an Alpha background (or ink-only
                // threshold) is visibly transparent in the preview instead of
                // reading as black. Hidden in transparent-window mode, where
                // alpha must be ACTUALLY transparent.
                if !windowMode.transparent {
                    CheckerboardBackground()
                }
                if !model.settings.previewEnabled {
                    Text("Preview off — still publishing")
                        .foregroundStyle(.secondary)
                        .frame(width: outputRect.width, height: outputRect.height)
                        .position(x: outputRect.midX, y: outputRect.midY)
                } else if model.settings.useMetalPreview, model.settings.previewMode != .split {
                    // Zero-readback GPU display (also the presentation-mode output).
                    SampleBufferDisplayView(controller: model.previewDisplay)
                        .frame(width: outputRect.width, height: outputRect.height)
                        .position(x: outputRect.midX, y: outputRect.midY)
                } else {
                    // Observes the live store, so the ~4 Hz image updates don't
                    // re-evaluate the whole ContentView body.
                    LivePreviewImage(live: model.live)
                        .frame(width: outputRect.width, height: outputRect.height)
                        .position(x: outputRect.midX, y: outputRect.midY)
                }
                if model.settings.landmarks.inkEnabled {
                    InkPreviewDrawingLayer(
                        paths: inkPathsBinding,
                        showLivePath: model.settings.landmarks.inkShowLivePath,
                        immediatePen: activeInkConfig.immediatePen,
                        immediateWash: activeInkConfig.immediateWash,
                        smoothing: activeInkConfig.smoothing,
                        onLive: { model.updateInkLiveStroke($0) },
                        onLiveEnd: { model.endInkLiveStroke() },
                        onStrokeCommitted: { commitCanvasStrokeRecord($0) },
                        outputSize: model.outputFormat.size,
                        outputRect: outputRect,
                        workspace: model.settings.workspace,
                        activeFrameID: activeInkFrameID,
                        inkColor: rgbaColor(activeInkConfig.inkColor),
                        inkRGBA: activeInkConfig.inkColor,
                        tool: inkTool,
                        brushMode: currentInkMode,
                        inkKind: currentInkKind,
                        width: Float(inkSizeBinding.wrappedValue),
                        washWidth: Float(inkWashSizeBinding.wrappedValue),
                        flow: activeInkConfig.flow,
                        bleed: activeInkConfig.bleed,
                        dry: activeInkConfig.dry,
                        colorSeparation: Float(inkColorSeparationBinding.wrappedValue),
                        brushInk: Float(inkBrushInkBinding.wrappedValue),
                        selectedPathID: $selectedInkPathID,
                        selectedPointIndex: $selectedInkPointIndex
                    )
                    .zIndex(20)
                }
                WorkspaceArtboardOverlay(model: model, outputSize: model.outputFormat.size)
                    .allowsHitTesting(workspaceOverlayHandlesInput)
                    .zIndex(25)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipShape(Rectangle())
        }
        .frame(minWidth: 120, minHeight: 68)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceOverlayHandlesInput: Bool {
        switch model.settings.workspace?.activeTool {
        case .artboard, .pan, .transform, .crop, .mask:
            return true
        case .select, .pen, .wash, nil:
            return false
        }
    }

    private var activeInkFrameID: UUID? {
        guard let workspace = model.settings.workspace,
              let graph = model.settings.layerGraph else { return nil }
        if let activeID = workspace.activeFrameID,
           isInkFrame(activeID, workspace: workspace, graph: graph) {
            return activeID
        }
        return workspace.frames.first { isInkFrame($0.id, workspace: workspace, graph: graph) }?.id
    }

    private var defaultInkFrameID: UUID? {
        guard let workspace = model.settings.workspace,
              let graph = model.settings.layerGraph else { return nil }
        return workspace.frames.first { isInkFrame($0.id, workspace: workspace, graph: graph) }?.id
    }

    private func isInkFrame(_ frameID: UUID, workspace: CollageWorkspace, graph: LayerGraph) -> Bool {
        guard let frame = workspace.frame(id: frameID),
              case .layer(let layerID) = frame.material,
              let layer = graph.layers.first(where: { $0.id == layerID }),
              let node = graph.node(layer.node) else { return false }
        return node.kind.family == "ink"
    }

    // MARK: - Controls

    /// The tabs currently shown in the tab bar, in canonical order.
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
        groups(from: topTabsRaw, defaultPanels: ControlTab.defaultTopPanels)
    }

    private var bottomGroups: [PanelGroup] {
        groups(from: bottomTabsRaw, defaultPanels: timelineDockVisible ? [.timeline] : [])
    }

    private var floatingGroups: [PanelGroup] {
        groups(from: floatingTabsRaw)
    }

    private var minimizedPanels: Set<ControlTab> {
        ControlTab.panelSet(from: minimizedPanelsRaw)
    }

    private var selectedBottomTab: ControlTab? {
        selectedPanel(in: bottomGroups.first) ?? bottomTabs.first
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
            return rawValue
                .split(separator: "|")
                .compactMap { groupRaw in
                    let panels = groupRaw
                        .split(separator: "+")
                        .compactMap { id in ControlTab.allCases.first(where: { $0.id == String(id) }) }
                    return panels.isEmpty ? nil : PanelGroup(panels: panels)
                }
        }
        let ids = rawValue.split(separator: ",").map(String.init)
        return ControlTab.panelGroups(for: ControlTab.allCases.filter { ids.contains($0.id) })
    }

    private func panelLocation(_ panel: ControlTab) -> PanelDropDestination? {
        if leftTabs.contains(panel) { return .left }
        if visibleTabs.contains(panel) { return .right }
        if topTabs.contains(panel) { return .top }
        if bottomTabs.contains(panel) { return .bottom }
        if floatingTabs.contains(panel) { return .floating }
        return nil
    }

    private func ensureInkToolbarPanelVisible() {
        guard panelLocation(.inkToolbar) == nil else { return }
        var groups = topGroups
        groups.append(PanelGroup(panels: [.inkToolbar]))
        setGroups(groups, for: .top)
        topDockCollapsed = false
    }

    private func toggleTabVisible(_ t: ControlTab) {
        if panelLocation(t) != nil {
            hidePanel(t)
        } else {
            dockPanelRight(t)
        }
    }

    private func movePanel(_ panel: ControlTab, to destination: PanelDropDestination) {
        let panels = moveGroup(for: panel)
        panels.forEach(removePanelFromAllDocks)
        var groups = groupsForDock(destination)
        groups.append(PanelGroup(panels: panels))
        setGroups(groups, for: destination)
        activateDock(destination, panel: panel)
        tab = panel
    }

    private func moveGroup(_ group: PanelGroup, to destination: PanelDropDestination) {
        let sourceTabs = group.panels
        sourceTabs.forEach(removePanelFromAllDocks)
        var groups = groupsForDock(destination)
        groups.append(PanelGroup(panels: sourceTabs))
        setGroups(groups, for: destination)
        if let activePanel = sourceTabs.first {
            activateDock(destination, panel: activePanel)
            tab = activePanel
        }
    }

    private func moveGroup(_ group: PanelGroup, to target: PanelInsertTarget) {
        let sourceTabs = group.panels
        sourceTabs.forEach(removePanelFromAllDocks)
        var groups = groupsForDock(target.destination)
        let insertGroup = PanelGroup(panels: sourceTabs)
        if let beforeGroupID = target.beforeGroupID,
           let index = groups.firstIndex(where: { $0.id == beforeGroupID }) {
            groups.insert(insertGroup, at: index)
        } else {
            groups.append(insertGroup)
        }
        setGroups(groups, for: target.destination)
        if let activePanel = sourceTabs.first {
            activateDock(target.destination, panel: activePanel)
            tab = activePanel
        }
    }

    private func floatGroup(_ group: PanelGroup, at position: CGPoint) {
        moveGroup(group, to: .floating)
        setFloatingPosition(position, for: group)
    }

    private func movePanel(_ panel: ControlTab, to destination: PanelDropDestination, before target: ControlTab?) {
        let oldLocation = panelLocation(panel)
        let oldGroups = oldLocation == destination ? groupsForDock(destination) : []
        let sourceIndex = oldGroups.firstIndex(where: { $0.panels.contains(panel) })
        let targetIndex = oldGroups.firstIndex(where: { $0.panels.contains(target ?? panel) })
        removePanelFromAllDocks(panel)
        var groups = groupsForDock(destination)
        if let target, let index = groups.firstIndex(where: { $0.panels.contains(target) }) {
            let shouldInsertAfter = oldLocation == destination
                && (sourceIndex ?? 0) < (targetIndex ?? 0)
            groups.insert(PanelGroup(panels: [panel]), at: shouldInsertAfter ? index + 1 : index)
        } else {
            groups.append(PanelGroup(panels: [panel]))
        }
        setGroups(groups, for: destination)
        activateDock(destination, panel: panel)
        tab = panel
    }

    private func moveGroup(for panel: ControlTab) -> [ControlTab] {
        ControlTab.yarnPathGroup.contains(panel) ? ControlTab.yarnPathGroup : [panel]
    }

    private func groupPanel(_ panel: ControlTab, with target: ControlTab, in destination: PanelDropDestination) {
        guard panel != target else { return }
        removePanelFromAllDocks(panel)
        var groups = groupsForDock(destination)
        if let index = groups.firstIndex(where: { $0.panels.contains(target) }) {
            if !groups[index].panels.contains(panel) {
                groups[index].panels.append(panel)
            }
        } else {
            groups.append(PanelGroup(panels: [target, panel]))
        }
        setGroups(groups, for: destination)
        activateDock(destination, panel: panel)
        tab = panel
    }

    private func groupPanelGroup(_ draggedGroup: PanelGroup, with targetGroup: PanelGroup, in destination: PanelDropDestination) {
        let panelsToAdd = draggedGroup.panels.filter { !targetGroup.panels.contains($0) }
        guard !panelsToAdd.isEmpty else { return }
        draggedGroup.panels.forEach(removePanelFromAllDocks)
        var groups = groupsForDock(destination)
        if let index = groups.firstIndex(where: { $0.id == targetGroup.id || !$0.panels.filter(targetGroup.panels.contains).isEmpty }) {
            groups[index] = PanelGroup(panels: groups[index].panels + panelsToAdd)
        } else {
            groups.append(PanelGroup(panels: targetGroup.panels + panelsToAdd))
        }
        setGroups(groups, for: destination)
        if let activePanel = panelsToAdd.first ?? targetGroup.activeDefault {
            activateDock(destination, panel: activePanel)
            tab = activePanel
        }
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
        let groups = normalizedPanelGroups(groups)
        switch destination {
        case .left:
            leftTabsRaw = ControlTab.dockStorageValue(for: groups, emptyValue: ControlTab.emptyDockValue)
        case .right:
            visibleTabsRaw = ControlTab.dockStorageValue(for: groups, emptyValue: ControlTab.emptyDockValue)
        case .top:
            topTabsRaw = ControlTab.dockStorageValue(for: groups, emptyValue: ControlTab.emptyDockValue)
        case .bottom:
            bottomTabsRaw = ControlTab.dockStorageValue(for: groups, emptyValue: ControlTab.emptyDockValue)
        case .floating:
            floatingTabsRaw = ControlTab.dockStorageValue(for: groups)
        }
    }

    private func normalizedPanelGroups(_ groups: [PanelGroup]) -> [PanelGroup] {
        var seen = Set<ControlTab>()
        return groups.compactMap { group in
            let panels = group.panels.filter { panel in
                guard !seen.contains(panel) else { return false }
                seen.insert(panel)
                return true
            }
            return panels.isEmpty ? nil : PanelGroup(panels: panels)
        }
    }

    private func activateDock(_ destination: PanelDropDestination, panel: ControlTab) {
        switch destination {
        case .right:
            windowMode.panelVisible = true
            rightDockCollapsed = false
        case .bottom:
            bottomTabID = panel.id
            if panel == .timeline {
                timelineDockVisible = true
            }
            bottomDockCollapsed = false
        case .left:
            leftDockCollapsed = false
        case .top:
            topDockCollapsed = false
        case .floating:
            break
        }
    }

    private func dockPanelLeft(_ panel: ControlTab) {
        movePanel(panel, to: .left)
    }

    private func dockPanelRight(_ panel: ControlTab) {
        movePanel(panel, to: .right)
    }

    private func dockPanelTop(_ panel: ControlTab) {
        movePanel(panel, to: .top)
    }

    private func dockPanelBottom(_ panel: ControlTab) {
        movePanel(panel, to: .bottom)
    }

    private func floatPanel(_ panel: ControlTab) {
        movePanel(panel, to: .floating)
    }

    private func floatPanel(_ panel: ControlTab, at position: CGPoint) {
        let group = PanelGroup(panels: moveGroup(for: panel))
        floatGroup(group, at: position)
    }

    private func hidePanel(_ panel: ControlTab) {
        removePanelFromAllDocks(panel)
        selectedPanelByGroup = selectedPanelByGroup.filter { $0.value != panel.id }
        if panelLocation(tab) == nil { tab = visibleTabs.first ?? leftTabs.first ?? topTabs.first ?? bottomTabs.first ?? floatingTabs.first ?? .layers }
        if bottomTabID == panel.id { bottomTabID = bottomTabs.first?.id ?? ControlTab.ink.id }
    }

    private func showAllPanels() {
        floatingDockDestination = nil
        leftTabsRaw = ControlTab.emptyDockValue
        visibleTabsRaw = ControlTab.dockStorageValue(for: allPanelsGroupedForDisplay())
        topTabsRaw = ControlTab.dockStorageValue(for: ControlTab.defaultTopPanels.map { PanelGroup(panels: [$0]) })
        bottomTabsRaw = ""
        floatingTabsRaw = ""
        floatingPanelPositionsRaw = ""
        floatingPanelSizesRaw = ""
        timelineDockVisible = false
        rightDockCollapsed = false
        windowMode.panelVisible = true
        windowMode.panelFit = true
        tab = .layers
    }

    private func allPanelsGroupedForDisplay() -> [PanelGroup] {
        ControlTab.panelGroups(for: ControlTab.allCases)
    }

    private func resetLayout() {
        floatingDockDestination = nil
        leftTabsRaw = ControlTab.dockStorageValue(for: ControlTab.defaultLeftPanels.map { PanelGroup(panels: [$0]) })
        visibleTabsRaw = ControlTab.dockStorageValue(for: ControlTab.defaultRightPanels.map { PanelGroup(panels: [$0]) })
        topTabsRaw = ""
        bottomTabsRaw = ControlTab.dockStorageValue(for: [PanelGroup(panels: [.timeline])])
        floatingTabsRaw = ""
        floatingPanelPositionsRaw = ""
        floatingPanelSizesRaw = ""
        timelineDockVisible = true
        leftDockCollapsed = false
        rightDockCollapsed = false
        topDockCollapsed = false
        bottomDockCollapsed = false
        leftDockSize = 320
        rightDockSize = 360
        topDockSize = 190
        bottomDockSize = 220
        minimizedPanelsRaw = ""
        windowMode.panelVisible = true
        windowMode.panelFit = true
        selectedPanelByGroup = [:]
        tab = .layers
    }

    private func applyLayoutCommand(_ command: LayoutCommand) {
        switch command {
        case .showAll:
            showAllPanels()
        case .reset:
            resetLayout()
        case .save(let slot):
            saveLayout(slot: slot)
        case .restore(let slot):
            restoreLayout(slot: slot)
        case .delete(let slot):
            UserDefaults.standard.removeObject(forKey: LayoutStorageKeys.preset(slot))
        }
    }

    private func currentLayoutSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(
            visibleTabsRaw: visibleTabsRaw,
            leftTabsRaw: leftTabsRaw,
            topTabsRaw: topTabsRaw,
            bottomTabsRaw: bottomTabsRaw,
            floatingTabsRaw: floatingTabsRaw,
            floatingPanelPositionsRaw: floatingPanelPositionsRaw,
            floatingPanelSizesRaw: floatingPanelSizesRaw,
            timelineDockVisible: timelineDockVisible,
            leftDockCollapsed: leftDockCollapsed,
            rightDockCollapsed: rightDockCollapsed,
            topDockCollapsed: topDockCollapsed,
            bottomDockCollapsed: bottomDockCollapsed,
            leftDockSize: leftDockSize,
            rightDockSize: rightDockSize,
            topDockSize: topDockSize,
            bottomDockSize: bottomDockSize,
            minimizedPanelsRaw: minimizedPanelsRaw,
            inspectorVisible: windowMode.panelVisible,
            inspectorFit: windowMode.panelFit
        )
    }

    private func saveLayout(slot: Int) {
        guard let data = try? JSONEncoder().encode(currentLayoutSnapshot()) else { return }
        UserDefaults.standard.set(data, forKey: LayoutStorageKeys.preset(slot))
    }

    private func restoreLayout(slot: Int) {
        guard let data = UserDefaults.standard.data(forKey: LayoutStorageKeys.preset(slot)),
              let snapshot = try? JSONDecoder().decode(LayoutSnapshot.self, from: data) else { return }
        applyLayoutSnapshot(snapshot)
    }

    private func applyLayoutSnapshot(_ snapshot: LayoutSnapshot) {
        floatingDockDestination = nil
        visibleTabsRaw = snapshot.visibleTabsRaw
        leftTabsRaw = snapshot.leftTabsRaw
        topTabsRaw = snapshot.topTabsRaw
        bottomTabsRaw = snapshot.bottomTabsRaw
        floatingTabsRaw = snapshot.floatingTabsRaw
        floatingPanelPositionsRaw = snapshot.floatingPanelPositionsRaw
        floatingPanelSizesRaw = snapshot.floatingPanelSizesRaw
        timelineDockVisible = snapshot.timelineDockVisible
        leftDockCollapsed = snapshot.leftDockCollapsed
        rightDockCollapsed = snapshot.rightDockCollapsed
        topDockCollapsed = snapshot.topDockCollapsed
        bottomDockCollapsed = snapshot.bottomDockCollapsed
        leftDockSize = snapshot.leftDockSize
        rightDockSize = snapshot.rightDockSize
        topDockSize = snapshot.topDockSize
        bottomDockSize = snapshot.bottomDockSize
        minimizedPanelsRaw = snapshot.minimizedPanelsRaw
        windowMode.panelVisible = snapshot.inspectorVisible
        windowMode.panelFit = snapshot.inspectorFit
        tab = visibleTabs.first ?? .layers
        bottomTabID = bottomTabs.first?.id ?? ControlTab.ink.id
    }

    private func syncLayoutWithPresentationMode(_ isPresentation: Bool) {
        if isPresentation {
            layoutBeforePresentation = currentLayoutSnapshot()
            leftDockCollapsed = true
            rightDockCollapsed = true
            topDockCollapsed = true
            bottomDockCollapsed = true
            windowMode.panelVisible = false
        } else if let snapshot = layoutBeforePresentation {
            layoutBeforePresentation = nil
            DispatchQueue.main.async {
                applyLayoutSnapshot(snapshot)
            }
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

    private func selectedPanel(in group: PanelGroup?) -> ControlTab? {
        guard let group else { return nil }
        if let id = selectedPanelByGroup[group.id],
           let panel = group.panels.first(where: { $0.id == id }) {
            return panel
        }
        if group.panels.contains(tab) {
            return tab
        }
        return group.activeDefault
    }

    private func selectPanel(_ panel: ControlTab, in group: PanelGroup) {
        selectedPanelByGroup[group.id] = panel.id
        tab = panel
        if bottomTabs.contains(panel) {
            bottomTabID = panel.id
        }
    }

    private func togglePanelMinimized(_ panel: ControlTab) {
        var minimized = minimizedPanels
        if minimized.contains(panel) {
            minimized.remove(panel)
        } else {
            minimized.insert(panel)
        }
        minimizedPanelsRaw = ControlTab.storageValue(for: minimized)
        tab = panel
    }

    private func panelDragProvider(for panel: ControlTab) -> NSItemProvider {
        draggingPanel = panel
        return NSItemProvider(object: panel.id as NSString)
    }

    private func handlePanelDrop(_ providers: [NSItemProvider], destination: PanelDropDestination) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String,
                  let panel = ControlTab.allCases.first(where: { $0.id == id }) else { return }
            DispatchQueue.main.async {
                switch destination {
                case .left:
                    dockPanelLeft(panel)
                case .right:
                    dockPanelRight(panel)
                case .top:
                    dockPanelTop(panel)
                case .bottom:
                    dockPanelBottom(panel)
                case .floating:
                    floatPanel(panel)
                }
                draggingPanel = nil
                leftDockDropTargeted = false
                rightDockDropTargeted = false
                topDockDropTargeted = false
                bottomDockDropTargeted = false
                floatingDockDropTargeted = false
            }
        }
        return true
    }

    private func handlePanelDrop(_ providers: [NSItemProvider], destination: PanelDropDestination, before target: ControlTab) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String,
                  let panel = ControlTab.allCases.first(where: { $0.id == id }) else { return }
            DispatchQueue.main.async {
                movePanel(panel, to: destination, before: target)
                draggingPanel = nil
            }
        }
        return true
    }

    private func handlePanelGroupDrop(_ providers: [NSItemProvider], destination: PanelDropDestination, target: ControlTab) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let id = object as? String,
                  let panel = ControlTab.allCases.first(where: { $0.id == id }) else { return }
            DispatchQueue.main.async {
                groupPanel(panel, with: target, in: destination)
                draggingPanel = nil
            }
        }
        return true
    }

    private func dropTargetBinding(for destination: PanelDropDestination) -> Binding<Bool> {
        switch destination {
        case .left:
            return $leftDockDropTargeted
        case .right:
            return $rightDockDropTargeted
        case .top:
            return $topDockDropTargeted
        case .bottom:
            return $bottomDockDropTargeted
        case .floating:
            return $floatingDockDropTargeted
        }
    }

    private func closeDock(_ destination: PanelDropDestination) {
        if floatingDockDestination == destination {
            floatingDockDestination = nil
        }
        switch destination {
        case .left:
            leftTabsRaw = ControlTab.emptyDockValue
        case .right:
            visibleTabsRaw = ControlTab.emptyDockValue
            windowMode.panelVisible = false
        case .top:
            topTabsRaw = ""
        case .bottom:
            bottomTabsRaw = ""
            timelineDockVisible = false
        case .floating:
            floatingTabsRaw = ""
        }
    }

    private func dockPanelAfterDrag(_ panel: ControlTab, translation: CGSize) {
        defer { draggingPanel = nil }
        let threshold: CGFloat = 70
        if abs(translation.width) < threshold && abs(translation.height) < threshold {
            floatPanel(panel)
            return
        }
        if abs(translation.width) > abs(translation.height) {
            translation.width < 0 ? dockPanelLeft(panel) : dockPanelRight(panel)
        } else {
            translation.height < 0 ? dockPanelTop(panel) : dockPanelBottom(panel)
        }
    }

    private func floatingPositions() -> [String: CGPoint] {
        floatingPanelPositionsRaw
            .split(separator: "|")
            .reduce(into: [String: CGPoint]()) { result, rawEntry in
                let parts = rawEntry.split(separator: ":")
                guard parts.count == 3,
                      let x = Double(parts[1]),
                      let y = Double(parts[2]) else { return }
                result[String(parts[0])] = CGPoint(x: x, y: y)
            }
    }

    private func encodeFloatingPositions(_ positions: [String: CGPoint]) -> String {
        positions
            .sorted { $0.key < $1.key }
            .map { key, point in
                "\(key):\(Int(point.x.rounded())):\(Int(point.y.rounded()))"
            }
            .joined(separator: "|")
    }

    private func floatingPosition(for group: PanelGroup, in size: CGSize) -> CGPoint {
        if let position = floatingPositions()[group.id] {
            return clampedFloatingPosition(position, in: size)
        }
        let index = floatingGroups.firstIndex(where: { $0.id == group.id }) ?? 0
        let fallback = CGPoint(x: min(size.width - 220, 80 + CGFloat(index * 26)),
                               y: min(size.height - 120, 90 + CGFloat(index * 30)))
        return clampedFloatingPosition(fallback, in: size)
    }

    private func setFloatingPosition(_ position: CGPoint, for group: PanelGroup) {
        var positions = floatingPositions()
        positions[group.id] = position
        floatingPanelPositionsRaw = encodeFloatingPositions(positions)
    }

    private func floatingSizes() -> [String: CGSize] {
        floatingPanelSizesRaw
            .split(separator: "|")
            .reduce(into: [String: CGSize]()) { result, rawEntry in
                let parts = rawEntry.split(separator: ":")
                guard parts.count == 3,
                      let width = Double(parts[1]),
                      let height = Double(parts[2]) else { return }
                result[String(parts[0])] = CGSize(width: width, height: height)
            }
    }

    private func encodeFloatingSizes(_ sizes: [String: CGSize]) -> String {
        sizes
            .sorted { $0.key < $1.key }
            .map { key, size in
                "\(key):\(Int(size.width.rounded())):\(Int(size.height.rounded()))"
            }
            .joined(separator: "|")
    }

    private func floatingSize(for group: PanelGroup) -> CGSize {
        if let size = floatingSizes()[group.id] {
            return clampedFloatingSize(size, for: group)
        }
        return defaultFloatingSize(for: group)
    }

    private func savedFloatingSize(for group: PanelGroup) -> CGSize? {
        floatingSizes()[group.id].map { clampedFloatingSize($0, for: group) }
    }

    private func setFloatingSize(_ size: CGSize, for group: PanelGroup) {
        var sizes = floatingSizes()
        sizes[group.id] = clampedFloatingSize(size, for: group)
        floatingPanelSizesRaw = encodeFloatingSizes(sizes)
    }

    private func defaultFloatingSize(for group: PanelGroup) -> CGSize {
        let activePanel = selectedPanel(in: group) ?? group.activeDefault ?? .layers
        switch activePanel {
        case .toolbar:
            return CGSize(width: 760, height: 150)
        case .timeline:
            return CGSize(width: 520, height: 210)
        case .layers:
            return CGSize(width: 430, height: 260)
        case .paper:
            return CGSize(width: 430, height: 280)
        case .ink:
            return CGSize(width: 430, height: 560)
        default:
            return CGSize(width: 360, height: 320)
        }
    }

    private func clampedFloatingSize(_ size: CGSize, for group: PanelGroup) -> CGSize {
        let minimumWidth = max(panelMinimumWidth(for: .floating), defaultFloatingSize(for: group).width * 0.72)
        return CGSize(
            width: min(max(size.width, minimumWidth), 900),
            height: min(max(size.height, 96), 760)
        )
    }

    private func clampedFloatingPosition(_ position: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: min(max(position.x, 0), max(0, size.width - 80)),
            y: min(max(position.y, 0), max(0, size.height - 60))
        )
    }

    private func dockEdgeTarget(at point: CGPoint, in size: CGSize, excluding source: PanelDropDestination?) -> PanelDropDestination? {
        let threshold: CGFloat = 44
        if source != .left, point.x <= threshold { return .left }
        if source != .right, point.x >= size.width - threshold { return .right }
        if source != .top, point.y <= threshold { return .top }
        if source != .bottom, point.y >= size.height - threshold { return .bottom }
        return nil
    }

    private func dockTarget(at point: CGPoint, in size: CGSize, excluding source: PanelDropDestination?) -> PanelDropDestination? {
        openDockDestination(at: point, in: size, excluding: source ?? .floating)
            ?? dockEdgeTarget(at: point, in: size, excluding: source)
    }

    private func groupTarget(at point: CGPoint, draggedGroup: PanelGroup) -> (group: PanelGroup, destination: PanelDropDestination)? {
        guard panelDragGhost != nil else { return nil }
        for destination in [PanelDropDestination.left, .right, .top, .bottom, .floating] {
            for group in groupsForDock(destination) where group.id != draggedGroup.id && group.panels.allSatisfy({ !draggedGroup.panels.contains($0) }) {
                for panel in group.panels where !draggedGroup.panels.contains(panel) {
                    if let frame = panelTabFrames[panel.id],
                       panelIconHitFrame(from: frame).contains(point) {
                        return (group, destination)
                    }
                }
            }
        }
        return nil
    }

    private func panelIconHitFrame(from tabFrame: CGRect) -> CGRect {
        CGRect(x: tabFrame.minX, y: tabFrame.minY, width: min(tabFrame.width, 34), height: tabFrame.height)
            .insetBy(dx: -6, dy: -6)
    }

    private func isPanelTabDragStart(_ point: CGPoint, in group: PanelGroup) -> Bool {
        group.panels.contains { panel in
            panelTabFrames[panel.id]?.insetBy(dx: -2, dy: -2).contains(point) == true
        }
    }

    private func insertionTarget(at point: CGPoint, draggedGroup: PanelGroup, rootSize: CGSize, source: PanelDropDestination) -> PanelInsertTarget? {
        let destinations: [PanelDropDestination] = [.left, .right, .top, .bottom]
        for destination in destinations {
            let groups = groupsForDock(destination).filter { group in
                group.id != draggedGroup.id && group.panels.allSatisfy { !draggedGroup.panels.contains($0) }
            }
            let frames = groups.compactMap { group -> (PanelGroup, CGRect)? in
                guard let frame = panelGroupFrames[group.id] else { return nil }
                return (group, frame)
            }
            guard !frames.isEmpty else { continue }
            let union = frames.dropFirst().reduce(frames[0].1) { $0.union($1.1) }.insetBy(dx: -20, dy: -24)
            guard union.contains(point) else { continue }
            if let before = frames.sorted(by: { $0.1.midY < $1.1.midY }).first(where: { point.y < $0.1.midY }) {
                return PanelInsertTarget(destination: destination, beforeGroupID: before.0.id)
            }
            return PanelInsertTarget(destination: destination, beforeGroupID: nil)
        }
        if let destination = dockTarget(at: point, in: rootSize, excluding: source) {
            return PanelInsertTarget(destination: destination, beforeGroupID: nil)
        }
        return nil
    }

    private func updatePanelDragTargets(group: PanelGroup, source: PanelDropDestination, location: CGPoint, rootSize: CGSize) {
        panelDragLocation = location
        if let target = groupTarget(at: location, draggedGroup: group) {
            panelGroupTargetID = target.group.id
            panelDockTarget = nil
            panelInsertTarget = nil
        } else {
            panelGroupTargetID = nil
            panelInsertTarget = insertionTarget(at: location, draggedGroup: group, rootSize: rootSize, source: source)
            panelDockTarget = panelInsertTarget?.destination ?? dockTarget(at: location, in: rootSize, excluding: source)
        }
    }

    private func clearPanelDragTargets() {
        panelDragLocation = nil
        panelDragGhost = nil
        panelDockTarget = nil
        panelGroupTargetID = nil
        panelInsertTarget = nil
    }

    private func floatingDropPosition(
        for group: PanelGroup,
        at location: CGPoint,
        startLocation: CGPoint,
        rootSize: CGSize,
        iconAnchored: Bool
    ) -> CGPoint {
        if iconAnchored {
            let iconInPanel = CGPoint(x: 20, y: 18)
            return clampedFloatingPosition(
                CGPoint(x: location.x - iconInPanel.x,
                        y: location.y - iconInPanel.y),
                in: rootSize
            )
        }
        if let frame = panelGroupFrames[group.id] {
            return clampedFloatingPosition(
                CGPoint(x: location.x + frame.minX - startLocation.x,
                        y: location.y + frame.minY - startLocation.y),
                in: rootSize
            )
        }
        return clampedFloatingPosition(location, in: rootSize)
    }

    private func openDockDestination(at point: CGPoint, in size: CGSize, excluding source: PanelDropDestination) -> PanelDropDestination? {
        let edgeThreshold: CGFloat = 42
        if source != .left,
           floatingDockDestination != .left,
           !leftDockCollapsed,
           point.x <= (leftTabs.isEmpty ? edgeThreshold : CGFloat(dockSize(.left, stored: leftDockSize)) + edgeThreshold) {
            return .left
        }
        if source != .right,
           floatingDockDestination != .right,
           !rightDockCollapsed,
           point.x >= size.width - (visibleTabs.isEmpty ? edgeThreshold : CGFloat(dockSize(.right, stored: rightDockSize)) + edgeThreshold) {
            return .right
        }
        if source != .top,
           floatingDockDestination != .top,
           !topDockCollapsed,
           point.y <= (topTabs.isEmpty ? edgeThreshold : CGFloat(dockSize(.top, stored: topDockSize)) + edgeThreshold) {
            return .top
        }
        if source != .bottom,
           floatingDockDestination != .bottom,
           !bottomDockCollapsed,
           point.y >= size.height - (bottomTabs.isEmpty ? edgeThreshold : CGFloat(dockSize(.bottom, stored: bottomDockSize)) + edgeThreshold) {
            return .bottom
        }
        return nil
    }

    private func isPoint(_ point: CGPoint, insideOpenDock destination: PanelDropDestination, in size: CGSize) -> Bool {
        switch destination {
        case .left:
            return !leftTabs.isEmpty
                && floatingDockDestination != .left
                && !leftDockCollapsed
                && point.x <= CGFloat(dockSize(.left, stored: leftDockSize))
        case .right:
            return !visibleTabs.isEmpty
                && floatingDockDestination != .right
                && windowMode.panelVisible
                && windowMode.panelFit
                && !rightDockCollapsed
                && point.x >= size.width - CGFloat(dockSize(.right, stored: rightDockSize))
        case .top:
            return !topTabs.isEmpty
                && floatingDockDestination != .top
                && !topDockCollapsed
                && point.y <= CGFloat(dockSize(.top, stored: topDockSize))
        case .bottom:
            return !bottomTabs.isEmpty
                && floatingDockDestination != .bottom
                && !bottomDockCollapsed
                && point.y >= size.height - CGFloat(dockSize(.bottom, stored: bottomDockSize))
        case .floating:
            return false
        }
    }

    private func finishPanelDrag(
        group: PanelGroup,
        panel: ControlTab,
        source: PanelDropDestination,
        location: CGPoint,
        startLocation: CGPoint,
        translation: CGSize,
        rootSize: CGSize
    ) {
        let iconAnchored = panelDragGhost != nil
        defer {
            draggingPanel = nil
            floatingDragOrigins[group.id] = nil
            floatingDragOffsets[group.id] = nil
            floatingResizeOrigins[group.id] = nil
            floatingResizePositionOrigins[group.id] = nil
            floatingResizeLiveSizes[group.id] = nil
            floatingResizeLivePositions[group.id] = nil
            clearPanelDragTargets()
        }
        if let target = groupTarget(at: location, draggedGroup: group) {
            groupPanelGroup(group, with: target.group, in: target.destination)
            return
        }
        if let target = insertionTarget(at: location, draggedGroup: group, rootSize: rootSize, source: source) {
            moveGroup(group, to: target)
            return
        }
        if let destination = dockTarget(at: location, in: rootSize, excluding: source) {
            moveGroup(group, to: destination)
            return
        }
        if source != .floating, isPoint(location, insideOpenDock: source, in: rootSize) {
            tab = panel
            return
        }
        if source == .floating {
            if floatingGroups.contains(where: { $0.id == group.id }) {
                let origin = floatingDragOrigins[group.id] ?? floatingPosition(for: group, in: rootSize)
                setFloatingPosition(
                    clampedFloatingPosition(
                        CGPoint(x: origin.x + translation.width, y: origin.y + translation.height),
                        in: rootSize
                    ),
                    for: group
                )
            } else {
                floatGroup(group, at: floatingDropPosition(for: group, at: location, startLocation: startLocation, rootSize: rootSize, iconAnchored: iconAnchored))
            }
        } else {
            floatGroup(group, at: floatingDropPosition(for: group, at: location, startLocation: startLocation, rootSize: rootSize, iconAnchored: iconAnchored))
        }
        tab = panel
    }

    private func dockResizeHandle(destination: PanelDropDestination, isCollapsed: Binding<Bool>, size: Binding<Double>) -> some View {
        let isVertical = destination == .left || destination == .right
        return Rectangle()
            .fill(Color.primary.opacity(0.001))
            .frame(width: isVertical ? 8 : nil, height: isVertical ? nil : 8)
            .overlay {
                Rectangle()
                    .fill(Color.primary.opacity(0.16))
                    .frame(width: isVertical ? 1 : nil, height: isVertical ? nil : 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        dockResizeActive = true
                        if dockDragBaselines[destination] == nil {
                            dockDragBaselines[destination] = size.wrappedValue
                            dockDragStartLocations[destination] = dockDragPointerLocation(destination)
                        }
                        let baseline = dockDragBaselines[destination] ?? size.wrappedValue
                        let startLocation = dockDragStartLocations[destination] ?? dockDragPointerLocation(destination)
                        let currentLocation = dockDragPointerLocation(destination)
                        let delta: CGFloat
                        switch destination {
                        case .left:
                            delta = currentLocation - startLocation
                        case .right:
                            delta = startLocation - currentLocation
                        case .top:
                            delta = startLocation - currentLocation
                        case .bottom:
                            delta = currentLocation - startLocation
                        case .floating:
                            delta = 0
                        }
                        let proposed = baseline + Double(delta)
                        let minimum = dockMinimumSize(destination)
                        let maximum = dockMaximumSize(destination)
                        isCollapsed.wrappedValue = false
                        liveDockSizes[destination] = min(max(proposed, minimum), maximum)
                    }
                    .onEnded { _ in
                        if let liveSize = liveDockSizes[destination] {
                            size.wrappedValue = liveSize
                        }
                        dockDragBaselines[destination] = nil
                        dockDragStartLocations[destination] = nil
                        liveDockSizes[destination] = nil
                        dockResizeActive = false
                    }
            )
            .help("Drag to resize or minimize this dock")
    }

    private func dockDragPointerLocation(_ destination: PanelDropDestination) -> CGFloat {
        let location = NSEvent.mouseLocation
        switch destination {
        case .left, .right:
            return location.x
        case .top, .bottom:
            return location.y
        case .floating:
            return 0
        }
    }

    private func dockSize(_ destination: PanelDropDestination, stored: Double) -> Double {
        max(liveDockSizes[destination] ?? stored, dockMinimumSize(destination))
    }

    private var topDockHeight: Double {
        guard topDockIsToolbarStrip else {
            return dockSize(.top, stored: topDockSize)
        }
        return Double(max(1, topGroups.count)) * 44
    }

    private var topDockIsToolbarStrip: Bool {
        !topGroups.isEmpty && topGroups.allSatisfy { group in
            let activePanel = selectedPanel(in: group) ?? group.activeDefault
            return activePanel.map(isToolbarPanel) == true
        }
    }

    private func dockMinimumSize(_ destination: PanelDropDestination) -> Double {
        switch destination {
        case .left, .right:
            return 320
        case .top:
            return topDockIsToolbarStrip ? 44 : 150
        case .bottom:
            return 170
        case .floating:
            return 300
        }
    }

    private func dockMaximumSize(_ destination: PanelDropDestination) -> Double {
        switch destination {
        case .left, .right:
            return 680
        case .top, .bottom:
            return 460
        case .floating:
            return 520
        }
    }

    private func dockSection(
        title: String,
        systemImage: String,
        groups: [PanelGroup],
        destination: PanelDropDestination,
        isCollapsed: Binding<Bool>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !isCollapsed.wrappedValue {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(groups) { group in
                            panelInsertGap(destination: destination, beforeGroupID: group.id)
                            panelGroupCard(group, destination: destination)
                        }
                        panelInsertGap(destination: destination, beforeGroupID: nil)
                    }
                    .padding(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .dockDropHighlight(isTargeted: dropTargetBinding(for: destination).wrappedValue || panelDockTarget == destination)
        .onDrop(of: [UTType.plainText], isTargeted: dropTargetBinding(for: destination)) { providers in
            handlePanelDrop(providers, destination: destination)
        }
    }

    @ViewBuilder private func panelInsertGap(destination: PanelDropDestination, beforeGroupID: String?) -> some View {
        if panelInsertTarget?.destination == destination && panelInsertTarget?.beforeGroupID == beforeGroupID {
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: 2)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .transition(.opacity)
        }
    }

    private func panelHeader(for panel: ControlTab) -> some View {
        HStack(spacing: 8) {
            panelDragHandle(for: panel)
            Spacer(minLength: 0)
            Button {
                hidePanel(panel)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Hide \(panel.rawValue)")
        }
    }

    private func panelGroupCard(_ group: PanelGroup, destination: PanelDropDestination) -> some View {
        let activePanel = selectedPanel(in: group) ?? group.activeDefault ?? .layers
        let isMinimized = minimizedPanels.contains(activePanel)
        let isActive = group.panels.contains(tab)
        let isGroupTargeted = panelGroupTargetID == group.id
        let panelSurface = Color(nsColor: isActive ? .controlBackgroundColor : .windowBackgroundColor)
        let headerSurface = Color(nsColor: .windowBackgroundColor).opacity(0.38)
        let isInlineToolbar = destination == .top && isToolbarPanel(activePanel) && !isMinimized
        return VStack(alignment: .leading, spacing: 0) {
            if isInlineToolbar {
                HStack(spacing: 8) {
                    panelTabStrip(group: group, activePanel: activePanel, destination: destination, activeTabSurface: panelSurface)
                    tabContent(activePanel)
                        .id(activePanel.id)
                        .transaction { transaction in
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                    Spacer(minLength: 0)
                    panelHeaderActions(for: activePanel)
                }
                .frame(height: 42)
                .padding(.trailing, 4)
                .background(headerSurface)
            } else {
                panelHeader(for: activePanel, group: group, destination: destination, activeTabSurface: panelSurface)
                    .frame(height: 36)
                    .background(headerSurface)
            }
            if !isMinimized && !isInlineToolbar {
                tabContent(activePanel)
                    .id(activePanel.id)
                    .padding(.top, 10)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }
            }
        }
        .frame(minWidth: panelMinimumWidth(for: destination), alignment: .leading)
        .background(panelSurface)
        .clipShape(Rectangle())
        .overlay {
            Rectangle()
                .stroke(
                    isGroupTargeted ? Color.accentColor.opacity(0.72) : (isActive ? Color.accentColor.opacity(0.24) : Color.primary.opacity(0.08)),
                    lineWidth: isGroupTargeted ? 3 : 1
                )
        }
        .background(isGroupTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { panelGroupFrames[group.id] = geo.frame(in: .named("workspaceRoot")) }
                    .onChange(of: geo.frame(in: .named("workspaceRoot"))) { _, newFrame in
                        panelGroupFrames[group.id] = newFrame
                    }
            }
        }
        .onTapGesture { tab = activePanel }
        .contextMenu {
            panelContextMenu(for: activePanel, group: group)
        }
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            handlePanelDrop(providers, destination: destination, before: group.panels.first ?? activePanel)
        }
    }

    private func isToolbarPanel(_ panel: ControlTab) -> Bool {
        panel == .toolbar || panel == .inkToolbar
    }

    @ViewBuilder private func panelContextMenu(for panel: ControlTab, group: PanelGroup) -> some View {
        Button("Dock Left") { moveGroup(group, to: .left) }
        Button("Dock Right") { moveGroup(group, to: .right) }
        Button("Dock Top") { moveGroup(group, to: .top) }
        Button("Dock Bottom") { moveGroup(group, to: .bottom) }
        Button("Float") {
            floatGroup(group, at: CGPoint(x: workspaceRootSize.width * 0.5, y: workspaceRootSize.height * 0.28))
        }
        Button(minimizedPanels.contains(panel) ? "Expand" : "Minimize") {
            togglePanelMinimized(panel)
        }
        Button("Hide") { group.panels.forEach(hidePanel) }
        Divider()
        Text(panelPlacementText(panel))
    }

    private func panelMinimumWidth(for destination: PanelDropDestination) -> CGFloat {
        switch destination {
        case .left, .right, .floating:
            return 280
        case .top, .bottom:
            return 260
        }
    }

    private func panelHeader(
        for activePanel: ControlTab,
        group: PanelGroup,
        destination: PanelDropDestination,
        activeTabSurface: Color
    ) -> some View {
        HStack(spacing: 0) {
            panelTabStrip(group: group, activePanel: activePanel, destination: destination, activeTabSurface: activeTabSurface)
            Spacer(minLength: 0)
            panelHeaderActions(for: activePanel)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("workspaceRoot"))
                .onChanged { value in
                    guard !isPanelTabDragStart(value.startLocation, in: group) else { return }
                    draggingPanel = activePanel
                    panelDragGhost = nil
                    updatePanelDragTargets(group: group, source: destination, location: value.location, rootSize: workspaceRootSize)
                    if destination == .floating {
                        let origin = floatingDragOrigins[group.id] ?? floatingPosition(for: group, in: workspaceRootSize)
                        floatingDragOrigins[group.id] = origin
                        floatingDragOffsets[group.id] = value.translation
                    }
                }
                .onEnded { value in
                    guard !isPanelTabDragStart(value.startLocation, in: group) else { return }
                    finishPanelDrag(
                        group: group,
                        panel: activePanel,
                        source: destination,
                        location: value.location,
                        startLocation: value.startLocation,
                        translation: value.translation,
                        rootSize: workspaceRootSize
                    )
                }
        )
    }

    private func panelHeaderActions(for activePanel: ControlTab) -> some View {
        HStack(spacing: 0) {
            if let visibility = panelVisibilityBinding(for: activePanel) {
                Button {
                    visibility.wrappedValue.toggle()
                } label: {
                    Image(systemName: visibility.wrappedValue ? "eye" : "eye.slash")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .frame(width: 34, height: 34)
                .help(visibility.wrappedValue ? "Disable \(activePanel.rawValue)" : "Enable \(activePanel.rawValue)")
            }
            Button {
                hidePanel(activePanel)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .frame(width: 34, height: 34)
            .help("Hide \(activePanel.rawValue)")
        }
    }

    private func panelTabStrip(
        group: PanelGroup,
        activePanel: ControlTab,
        destination: PanelDropDestination,
        activeTabSurface: Color
    ) -> some View {
        HStack(spacing: 0) {
            ForEach(group.panels) { panel in
                panelTabButton(panel, group: group, activePanel: activePanel, destination: destination, activeTabSurface: activeTabSurface)
            }
        }
    }

    @ViewBuilder private func panelTabButton(
        _ panel: ControlTab,
        group: PanelGroup,
        activePanel: ControlTab,
        destination: PanelDropDestination,
        activeTabSurface: Color
    ) -> some View {
        if isToolbarPanel(panel) {
            panelTabLabel(panel, group: group, activePanel: activePanel, destination: destination, activeTabSurface: activeTabSurface)
                .labelStyle(.iconOnly)
        } else if group.panels.count == 1 || panel == activePanel {
            panelTabLabel(panel, group: group, activePanel: activePanel, destination: destination, activeTabSurface: activeTabSurface)
                .labelStyle(.titleAndIcon)
        } else {
            panelTabLabel(panel, group: group, activePanel: activePanel, destination: destination, activeTabSurface: activeTabSurface)
                .labelStyle(.iconOnly)
        }
    }

    private func panelTabLabel(
        _ panel: ControlTab,
        group: PanelGroup,
        activePanel: ControlTab,
        destination: PanelDropDestination,
        activeTabSurface: Color
    ) -> some View {
        Button {
            selectPanel(panel, in: group)
        } label: {
            Label(panel.rawValue, systemImage: panel.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(draggingPanel == panel ? Color.accentColor : Color.secondary)
                .padding(.horizontal, panel == activePanel ? 12 : 8)
                .frame(height: 36)
                .background {
                    if panel == activePanel {
                        activeTabSurface
                    }
                }
                .compositingGroup()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isToolbarPanel(panel) ? panel.rawValue : "Double-click to minimize \(panel.rawValue)")
        .background {
            GeometryReader { geo in
                Color.clear
                    .onAppear { panelTabFrames[panel.id] = geo.frame(in: .named("workspaceRoot")) }
                    .onChange(of: geo.frame(in: .named("workspaceRoot"))) { _, newFrame in
                        panelTabFrames[panel.id] = newFrame
                    }
            }
        }
        .simultaneousGesture(
            TapGesture(count: 2)
                .onEnded {
                    selectPanel(panel, in: group)
                    togglePanelMinimized(panel)
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .named("workspaceRoot"))
                .onChanged { value in
                    draggingPanel = panel
                    panelDragGhost = panel
                    let draggedTab = PanelGroup(panels: [panel])
                    updatePanelDragTargets(group: draggedTab, source: destination, location: value.location, rootSize: workspaceRootSize)
                }
                .onEnded { value in
                    let draggedTab = PanelGroup(panels: [panel])
                    finishPanelDrag(
                        group: draggedTab,
                        panel: panel,
                        source: destination,
                        location: value.location,
                        startLocation: value.startLocation,
                        translation: value.translation,
                        rootSize: workspaceRootSize
                    )
                }
        )
        .onDrop(of: [UTType.plainText], isTargeted: nil) { providers in
            handlePanelGroupDrop(providers, destination: destination, target: panel)
        }
        .transaction { transaction in
            transaction.animation = nil
            transaction.disablesAnimations = true
        }
    }
    private func panelDragHandle(for panel: ControlTab) -> some View {
        Label(panel.rawValue, systemImage: panel.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(draggingPanel == panel ? Color.accentColor : Color.secondary)
            .labelStyle(.titleAndIcon)
            .contentShape(Rectangle())
            .help("Drag to dock or float this panel")
            .onDrag { panelDragProvider(for: panel) }
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in draggingPanel = panel }
                    .onEnded { value in
                        dockPanelAfterDrag(panel, translation: value.translation)
                    }
            )
    }

    private var floatingPanelsOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(floatingGroups) { group in
                    floatingPanelCard(group, rootSize: geo.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func floatingPanelCard(_ group: PanelGroup, rootSize: CGSize) -> some View {
        let position = floatingResizeLivePositions[group.id] ?? floatingPosition(for: group, in: rootSize)
        let offset = floatingDragOffsets[group.id] ?? .zero
        let size = floatingResizeLiveSizes[group.id] ?? floatingSize(for: group)
        let activePanel = selectedPanel(in: group) ?? group.activeDefault ?? .layers
        let isMinimized = minimizedPanels.contains(activePanel)
        return panelGroupCard(group, destination: .floating)
            .frame(width: size.width, alignment: .topLeading)
            .background(.ultraThinMaterial)
            .shadow(color: Color.black.opacity(0.22), radius: 16, y: 8)
            .overlay(alignment: .bottomTrailing) {
                if !isMinimized {
                    floatingResizeHandle(for: group)
                }
            }
            .offset(x: position.x + offset.width, y: position.y + offset.height)
    }

    private func floatingResizeHandle(for group: PanelGroup) -> some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(Color.primary.opacity(0.001))
                .frame(width: 24, height: 24)
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.secondary.opacity(hoveredFloatingResizeGroupID == group.id || floatingResizeOrigins[group.id] != nil ? 0.7 : 0))
                .padding(5)
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hoveredFloatingResizeGroupID = hovering ? group.id : (hoveredFloatingResizeGroupID == group.id ? nil : hoveredFloatingResizeGroupID)
        }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let origin = floatingResizeOrigins[group.id] ?? floatingSize(for: group)
                    floatingResizeOrigins[group.id] = origin
                    let positionOrigin = floatingResizePositionOrigins[group.id] ?? floatingPosition(for: group, in: workspaceRootSize)
                    floatingResizePositionOrigins[group.id] = positionOrigin
                    let resized = clampedFloatingSize(
                        CGSize(width: origin.width + value.translation.width,
                               height: origin.height),
                        for: group
                    )
                    floatingResizeLiveSizes[group.id] = resized
                    floatingResizeLivePositions[group.id] = clampedFloatingPosition(positionOrigin, in: workspaceRootSize)
                }
                .onEnded { _ in
                    if let liveSize = floatingResizeLiveSizes[group.id] {
                        setFloatingSize(liveSize, for: group)
                    }
                    if let livePosition = floatingResizeLivePositions[group.id] {
                        setFloatingPosition(livePosition, for: group)
                    }
                    floatingResizeOrigins[group.id] = nil
                    floatingResizePositionOrigins[group.id] = nil
                    floatingResizeLiveSizes[group.id] = nil
                    floatingResizeLivePositions[group.id] = nil
                }
        )
        .help("Resize floating panel")
    }

    @ViewBuilder private func tabContent(_ tab: ControlTab) -> some View {
        switch tab {
        case .toolbar: workspaceToolbarTab
        case .inkToolbar: inkToolbarTab
        case .input: inputTab
        case .camera: cameraTab
        case .movie: movieTab
        case .layers: layersTab
        case .marks: marksTab
        case .yarn: yarnTab
        case .wrap: wrapTab
        case .lineWalk: lineWalkTab
        case .ink: inkTab
        case .paper: paperTab
        case .history: historyTab
        case .timeline: timelineTab
        case .web: webTab
        case .presets: presetsTab
        case .keys: keysTab
        case .debug: debugTab
        }
    }

    private var isHeld: Bool {
        model.frameSource == .movie ? model.movieRate == 0 : model.inputFrozen
    }

    private var freezeButtonTitle: String {
        if model.frameSource == .movie {
            return model.movieRate == 0 ? "Play" : "Pause"
        }
        return model.inputFrozen ? "Unfreeze" : "Freeze"
    }

    // MARK: - Toolbar tab

    @ViewBuilder private var workspaceToolbarTab: some View {
        let workspace = model.settings.workspace
        let selected = workspace?.frame(id: workspace?.activeFrameID)
        HStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(workspaceToolbarTools) { tool in
                    Button {
                        workspaceToolBinding.wrappedValue = tool
                    } label: {
                        Image(systemName: workspaceToolIcon(tool))
                            .frame(width: 28, height: 24)
                            .background {
                                if workspaceToolBinding.wrappedValue == tool {
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.secondary.opacity(0.24))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .help(workspaceToolTitle(tool))
                }
            }
            .padding(2)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 6, style: .continuous))

            Divider()
                .frame(height: 24)

            if let selected {
                Label(selected.name, systemImage: workspaceRoleIcon(selected.role))
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No frame selected")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button { zoomWorkspace(by: 0.8) } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom artboard out")

                Button { resetWorkspaceView() } label: {
                    Image(systemName: "viewfinder")
                }
                .help("Fit output viewport")

                Button { zoomWorkspace(by: 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom artboard in")
            }
            .buttonStyle(.borderless)

            Divider()
                .frame(height: 24)

            Button {
                model.undoWorkspaceAction()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canUndoWorkspaceAction)
            .help("Undo workspace edit")

            Button {
                model.redoWorkspaceAction()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(.borderless)
            .disabled(!model.canRedoWorkspaceAction)
            .help("Redo workspace edit")

            Button {
                openWindow(id: "output")
            } label: {
                Image(systemName: "rectangle.inset.filled")
            }
            .buttonStyle(.borderless)
            .help("Open secondary output window")
        }
        .controlSize(.small)
        .onAppear { model.ensureWorkspace() }
    }

    private var workspaceToolbarTools: [WorkspaceTool] {
        [.select, .artboard, .pan, .transform, .crop, .mask]
    }

    // MARK: - Ink toolbar tab

    @ViewBuilder private var inkToolbarTab: some View {
        InkToolbarStrip(
            controls: inkToolbarControls,
            mode: inkModeBinding,
            inkKind: inkKindBinding,
            inkColor: inkColorPickerBinding,
            smooth: inkConfigFloatBinding(\.smoothing),
            size: inkSizeBinding,
            washSize: inkWashSizeBinding,
            smear: inkConfigFloatBinding(\.smearStrength),
            flow: inkConfigFloatBinding(\.flow),
            bleed: inkConfigFloatBinding(\.bleed),
            dry: inkConfigFloatBinding(\.dry),
            wetDecay: optionalInkConfigFloatBinding(\.wetnessDecay, defaultValue: 1),
            fade: optionalInkConfigFloatBinding(\.fadeDuration, defaultValue: 1.2),
            colorSeparation: inkColorSeparationBinding,
            brushInk: inkBrushInkBinding,
            controlDragProvider: toolbarControlDragProvider,
            removeControl: removeInkToolbarControl,
            resetControls: resetInkToolbarControls,
            fix: fixInk,
            clear: clearInk,
            save: model.exportCurrentFrame
        )
        .disabled(!model.settings.landmarks.inkEnabled)
        .onDrop(of: [UTType.plainText], isTargeted: nil, perform: handleInkToolbarDrop)
    }

    private var inkToolbarControls: [ToolbarControlID] {
        ToolbarControlID.controls(from: inkToolbarControlsRaw)
    }

    private func toolbarControlDragProvider(_ control: ToolbarControlID) -> NSItemProvider {
        guard NSEvent.modifierFlags.contains(.option) else {
            return NSItemProvider(object: "toolbar-control-cancelled" as NSString)
        }
        return NSItemProvider(object: "toolbar-control:\(control.id)" as NSString)
    }

    private func handleInkToolbarDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
            let data: Data?
            if let incoming = item as? Data {
                data = incoming
            } else if let incoming = item as? String {
                data = incoming.data(using: .utf8)
            } else if let incoming = item as? NSString {
                data = String(incoming).data(using: .utf8)
            } else {
                data = nil
            }
            guard let data,
                  let raw = String(data: data, encoding: .utf8),
                  raw.hasPrefix("toolbar-control:"),
                  let control = ToolbarControlID(rawValue: String(raw.dropFirst("toolbar-control:".count))) else { return }
            DispatchQueue.main.async {
                var controls = inkToolbarControls.filter { $0 != control }
                controls.append(control)
                inkToolbarControlsRaw = ToolbarControlID.storageValue(for: controls)
            }
        }
        return true
    }

    private func removeInkToolbarControl(_ control: ToolbarControlID) {
        let controls = inkToolbarControls.filter { $0 != control }
        inkToolbarControlsRaw = ToolbarControlID.storageValue(for: controls)
    }

    private func resetInkToolbarControls() {
        inkToolbarControlsRaw = ""
    }

    private func zoomWorkspace(by factor: Double) {
        model.updateWorkspaceLiveEdit { workspace in
            workspace.zoom = max(0.05, min(16, workspace.zoom * factor))
        }
    }

    private func resetWorkspaceView() {
        model.updateWorkspaceLiveEdit { workspace in
            workspace.zoom = 1
            workspace.viewCenter = CGPoint(x: workspace.outputViewport.frame.midX, y: workspace.outputViewport.frame.midY)
        }
    }

    private var workspaceToolBinding: Binding<WorkspaceTool> {
        Binding {
            model.settings.workspace?.activeTool ?? .select
        } set: { tool in
            model.mutateWorkspace { workspace in
                workspace.activeTool = tool
            }
            switch tool {
            case .pen:
                model.settings.landmarks.inkEnabled = true
                mutateActiveInkConfig { $0.brushMode = .pen }
                inkTool = .draw
            case .wash:
                model.settings.landmarks.inkEnabled = true
                mutateActiveInkConfig { $0.brushMode = .brush }
                inkTool = .draw
            case .select, .transform, .crop, .mask:
                inkTool = .select
            case .artboard, .pan:
                break
            }
        }
    }

    private func workspaceToolTitle(_ tool: WorkspaceTool) -> String {
        switch tool {
        case .select: return "Select"
        case .artboard: return "Artboard"
        case .pan: return "Pan"
        case .transform: return "Transform"
        case .crop: return "Crop"
        case .mask: return "Mask"
        case .pen: return "Pen"
        case .wash: return "Wash"
        }
    }

    private func workspaceToolIcon(_ tool: WorkspaceTool) -> String {
        switch tool {
        case .select: return "cursorarrow"
        case .artboard: return "rectangle.dashed"
        case .pan: return "hand.draw"
        case .transform: return "arrow.up.left.and.arrow.down.right"
        case .crop: return "crop"
        case .mask: return "camera.filters"
        case .pen: return "pencil.tip"
        case .wash: return "paintbrush.pointed"
        }
    }

    private func workspaceRoleIcon(_ role: WorkspaceFrameRole) -> String {
        switch role {
        case .output: return "record.circle"
        case .layer: return "square.3.layers.3d"
        case .reference: return "photo"
        case .preview: return "rectangle.inset.filled"
        }
    }


    // MARK: - Camera tab

    @ViewBuilder private var cameraTab: some View {
        SectionHeader("Camera")
        HStack {
            Button {
                model.toggleFreezeOrPause()
            } label: {
                Label(freezeButtonTitle, systemImage: isHeld ? "play.fill" : "pause.fill")
            }
            .panelButton()
            .help("Freeze live camera input")
            Spacer()
            Text(model.inputFrozen ? "held" : "live")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        Picker("Camera", selection: Binding(
            get: { model.selectedDeviceID ?? "" },
            set: {
                model.frameSource = .camera
                model.selectCamera($0.isEmpty ? nil : $0)
            }
        )) {
            ForEach(model.cameraDevices) { device in
                Text(device.name).tag(device.id)
            }
        }
        Picker("Resolution", selection: $model.inputResolution) {
            ForEach(CameraInputResolution.allCases) { resolution in
                Text(resolution.title).tag(resolution)
            }
        }
        .help("Capture resolution requested from the camera. Higher = more detail into effects/detection but more bandwidth.")

        SectionHeader("Frame")
        Toggle("Mirror", isOn: $model.settings.mirror)
            .help("Mirror the source (selfie view). For a creative per-layer flip, add a Mirror effect to a layer instead.")
        Toggle("Test pattern", isOn: $model.settings.testPatternMode)
    }

    // MARK: - Movie tab

    @ViewBuilder private var movieTab: some View {
        SectionHeader("Movie")
        HStack {
            Button {
                model.toggleFreezeOrPause()
            } label: {
                Label(freezeButtonTitle, systemImage: isHeld ? "play.fill" : "pause.fill")
            }
            .panelButton()
            .help("Pause or resume movie input")
            Spacer()
            Text(model.movieRate == 0 ? "paused" : "playing")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        HStack {
            Button("Open Movie…") { model.frameSource = .movie; model.openMoviePanel() }
                .panelButton()
            Button("Demo clip") { model.frameSource = .movie; model.loadDemoClip() }
                .panelButton()
            Text(model.movieURL?.lastPathComponent ?? "No movie selected")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        HStack {
            TextField("https://… (stream URL)", text: $movieURLField)
                .textFieldStyle(.roundedBorder)
            Button("Load") { model.frameSource = .movie; model.openMovieURL(movieURLField) }
                .panelButton()
                .disabled(movieURLField.isEmpty)
        }
        SliderRow(title: "Speed", value: $model.movieRate, range: 0...2, defaultValue: 1, hint: "0 pauses")
    }

    @ViewBuilder private var inputTab: some View {
        SectionHeader("Output")
        OutputExportControls(
            exporter: model.exporter,
            chooseDestination: model.chooseExportDestination,
            exportCurrent: model.exportCurrentFrame
        )
        Picker("Format", selection: $model.outputFormat) {
            ForEach(SketchCamFormats.all) { format in
                Text(format.displayName).tag(format)
            }
        }
        .help("Resolution published to the virtual camera and shown in the preview. This is the final output size.")
        Picker("Processing", selection: $model.settings.processingQuality) {
            ForEach(ProcessingQuality.allCases) { quality in
                Text(quality.title).tag(quality)
            }
        }
        .pickerStyle(.segmented)
        .help("Resolution the effect chain renders at, then upscaled to Output. Lower (540p) = cheaper effects, softer detail. Detection uses its own input size and is unaffected by this.")

        SectionHeader("Preview")
        Picker("Mode", selection: $model.settings.previewMode) {
            ForEach(PreviewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Toggle("Show preview", isOn: $model.settings.previewEnabled)
        Toggle("Metal display (zero readback)", isOn: $model.settings.useMetalPreview)
            .help("Display frames directly on the GPU — no CGImage readback, full rate. The preview is also the presentation-mode output. Split mode falls back to the CPU image.")
        SliderRow(title: "Display fps", value: Binding(
            get: { model.settings.previewFPS },
            set: { model.settings.previewFPS = $0.rounded() }
        ), range: 0...60, precision: 0, defaultValue: 0, hint: "0 = full-tilt (every published frame)")
        Toggle("Two-finger drag moves artboard", isOn: artboardDragCanvasWithScrollBinding)
            .help("On: two-finger drag moves the visible artboard with your fingers. Off: the viewport moves opposite the gesture.")

        SectionHeader("Window")
        HStack {
            Toggle("Panel", isOn: $windowMode.panelVisible)
        }
        .toggleStyle(.checkbox)
        HStack {
            Toggle("Decoration", isOn: $windowMode.decorated)
            Toggle("Transparent", isOn: $windowMode.transparent)
        }
        .toggleStyle(.checkbox)
        HStack {
            Toggle("On top", isOn: $windowMode.alwaysOnTop)
            Button {
                appUI.toggleDebugOverlay()
            } label: {
                Label("Performance", systemImage: appUI.debugOverlayVisible ? "chart.line.uptrend.xyaxis.circle.fill" : "chart.line.uptrend.xyaxis.circle")
            }
            .help("Toggle performance overlay (Control-Option-P)")
        }
        .controlSize(.small)
        HStack {
            Button(windowMode.presentationMode ? "Exit Presentation Mode" : "Presentation Mode") {
                windowMode.togglePresentationMode()
            }
            Button(windowMode.pipMode ? "Exit PIP" : "PIP") {
                windowMode.togglePIP()
            }
        }
        .controlSize(.small)

        SectionHeader("Rendering")
        Toggle("GPU drawing (Metal)", isOn: $model.settings.landmarks.useMetalDrawing)
            .help("Render the drawing strokes on the GPU instead of the CPU. Marks (dots/stick/labels) stay CPU. Watch the Overlay ms in Debug.")
        Toggle("Bead stroke (legacy)", isOn: $model.settings.landmarks.beadStroke)
            .help("Off = smooth filled ribbons (clean under transparency). On = the older per-segment quads + round discs.")
        Toggle("GPU compositor (experimental)", isOn: $model.settings.useGPUCompositor)
            .help("Composite every layer (camera/solid/paper/drawing/ink/web) from the graph on the GPU — per-layer Metal effect chain + mask. Off = legacy CoreImage path. The camera becomes a real, reorderable/maskable layer.")

        SectionHeader("Ink Undo")
        HStack {
            Text("GPU states")
            Spacer()
            TextField("", value: inkUndoGPUStateCountBinding, format: .number)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 72)
                .help("Click or double-click to type an exact state count.")
            Stepper("", value: inkUndoGPUStateCountBinding, in: 0...inkUndoMaximumStateCount)
                .labelsHidden()
        }
        .help("Exact physical ink states retained in GPU memory. 0 uses replay only. Changes apply as new gestures are captured.")
        Text(inkUndoMemoryEstimate)
            .font(.caption)
            .foregroundStyle(inkUndoUsesLargeMemoryShare ? .orange : .secondary)

        SectionHeader("Camera Extension")
        HStack {
            Button("Activate") { model.activateExtension() }
            Button("Deactivate") { model.deactivateExtension() }
        }
        .controlSize(.small)
        Text(model.activationManager.statusText)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var inkUndoStateBytes: Double {
        let size = model.outputFormat.size
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let shortSide = max(1, min(width, height))
        let dyeScale = Double(min(2048, shortSide)) / Double(shortSide)
        let simScale = 256.0 / Double(shortSide)
        let dyeWidth = max(1, Int((Double(width) * dyeScale).rounded()))
        let dyeHeight = max(1, Int((Double(height) * dyeScale).rounded()))
        let simWidth = max(1, Int((Double(width) * simScale).rounded()))
        let simHeight = max(1, Int((Double(height) * simScale).rounded()))
        // Dye fields use 26 bytes/pixel; solver fields use 6 bytes/pixel.
        return Double(dyeWidth * dyeHeight * 26 + simWidth * simHeight * 6)
    }

    private var inkUndoMaximumStateCount: Int {
        let halfMemory = Double(ProcessInfo.processInfo.physicalMemory) * 0.5
        return min(
            InkUndoPreferences.absoluteMaximumGPUStateCount,
            max(1, Int(halfMemory / max(1, inkUndoStateBytes)))
        )
    }

    private var inkUndoGPUStateCountBinding: Binding<Int> {
        Binding(
            get: { min(inkUndoGPUStateCount, inkUndoMaximumStateCount) },
            set: { inkUndoGPUStateCount = min(inkUndoMaximumStateCount, max(0, $0)) }
        )
    }

    private var inkUndoUsesLargeMemoryShare: Bool {
        inkUndoStateBytes * Double(inkUndoGPUStateCount) >= Double(ProcessInfo.processInfo.physicalMemory) * 0.25
    }

    private var inkUndoMemoryEstimate: String {
        let eachMB = inkUndoStateBytes / 1_000_000
        let totalGB = inkUndoStateBytes * Double(inkUndoGPUStateCount) / 1_000_000_000
        let warning = inkUndoUsesLargeMemoryShare ? " · Warning: large shared-memory allocation" : ""
        return String(format: "About %.0f MB per state · %.2f GB maximum%@", eachMB, totalGB, warning)
    }

    // MARK: - Layers tab

    @ViewBuilder private var layersTab: some View {
        WorkspaceFrameStackEditor(model: model)
    }

    // (The legacy Background and Effect tabs are gone. v2: background is just a
    // Solid layer in the stack; threshold/outline/blur/invert/mirror/person-key
    // are per-layer effects. The shared person-matte quality lives in Settings;
    // the frame-level Mirror + Test pattern toggles are in the Sources tab.)


    // MARK: - Marks tab

    @ViewBuilder private var marksTab: some View {
        Toggle("Landmark overlay", isOn: $model.settings.landmarks.enabled)
        Group {
            Picker("Source", selection: $model.settings.landmarks.sourceMode) {
                ForEach(LandmarkSourceMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Dots", isOn: $model.settings.landmarks.showDots)
                Toggle("Stick", isOn: $model.settings.landmarks.showStick)
            }
            .toggleStyle(.checkbox)

            SectionHeader("Face")
            featureRow("Jaw", track: \.landmarks.trackJaw, style: \.landmarks.jawStyle)
            featureRow("Nose", track: \.landmarks.trackNose, style: \.landmarks.noseStyle)
            featureRow("Mouth", track: \.landmarks.trackMouth, style: \.landmarks.mouthStyle)
            featureRow("L Brow", track: \.landmarks.trackLeftBrow, style: \.landmarks.leftBrowStyle)
            featureRow("R Brow", track: \.landmarks.trackRightBrow, style: \.landmarks.rightBrowStyle)
            featureRow("L Eye", track: \.landmarks.trackLeftEye, style: \.landmarks.leftEyeStyle)
            featureRow("R Eye", track: \.landmarks.trackRightEye, style: \.landmarks.rightEyeStyle)

            SectionHeader("Body")
            featureRow("Head", track: \.landmarks.trackHead, style: \.landmarks.headStyle)
            featureRow("Torso", track: \.landmarks.trackTorso, style: \.landmarks.torsoStyle)
            featureRow("L Arm", track: \.landmarks.trackLeftArm, style: \.landmarks.leftArmStyle)
            featureRow("R Arm", track: \.landmarks.trackRightArm, style: \.landmarks.rightArmStyle)
            featureRow("L Leg", track: \.landmarks.trackLeftLeg, style: \.landmarks.leftLegStyle)
            featureRow("R Leg", track: \.landmarks.trackRightLeg, style: \.landmarks.rightLegStyle)

            SectionHeader("Other")
            featureRow("Hands", track: \.landmarks.trackHands, style: \.landmarks.handsStyle)
            featureRow("Person", track: \.landmarks.trackContour, style: \.landmarks.contourStyle)
            SliderRow(title: "Detail", value: floatBinding(\.landmarks.contourDetail), defaultValue: 0.4,
                      hint: "Person silhouette contour (Vision segmentation). Independent of Layers keying — tracks the outline without the keying composite. Coarse → fine (hugs concavities).")
                .disabled(!model.settings.landmarks.trackContour)
            featureRow("Hull", track: \.landmarks.trackBodyHull, style: \.landmarks.bodyHullStyle)
                .help("Seg-free person outline: convex hull of the tracked landmarks. No segmentation cost, cruder than Person (can't enter concavities). Use alongside Person or on its own.")

            SectionHeader("Labels")
            Toggle("Show IDs", isOn: $model.settings.landmarks.showIDs)
            SliderRow(title: "Size", value: floatBinding(\.landmarks.labelSize), range: 6...24, defaultValue: 11)
                .disabled(!model.settings.landmarks.showIDs)
            Toggle("Match feature colors", isOn: $model.settings.landmarks.labelsMatchColor)
                .disabled(!model.settings.landmarks.showIDs)

            SectionHeader("Detection")
            SliderRow(title: "Rate (Hz)", value: Binding(
                get: { model.settings.landmarks.detectionsPerSecond },
                set: { model.settings.landmarks.detectionsPerSecond = $0.rounded() }
            ), range: 1...30, precision: 0, defaultValue: 10)
            SliderRow(title: "Input px", value: Binding(
                get: { Double(model.settings.landmarks.detectionMaxDimension) },
                set: { model.settings.landmarks.detectionMaxDimension = max(96, Int(($0 / 32).rounded()) * 32) }
            ), range: 128...512, precision: 0, defaultValue: 384,
               hint: "Longest side of the frame handed to Vision (snaps to /32; e.g. 256). NOTE: Vision resizes to a fixed internal size, so this mainly affects precision, NOT speed — to cut detection cost, track fewer categories or lower Rate.")
            Toggle("Predict motion (smooth tracking)", isOn: $model.settings.landmarks.predictiveTracking)
                .help("Extrapolate landmark motion and redraw every frame so the drawing tracks at frame rate and lags the body less — without raising the detection rate.")
            SliderRow(title: "Dot size", value: floatBinding(\.landmarks.dotScale), range: 0.2...4, defaultValue: 1)
            SliderRow(title: "Stick width", value: floatBinding(\.landmarks.stickScale), range: 0.2...4, defaultValue: 1)
        }
        .disabled(!model.settings.landmarks.enabled)
    }

    // MARK: - Drawing tab
    //
    // Marks visualizes the raw sensor data (dots, stick, labels); Drawing
    // hosts artistic interpretations of the same landmarks. Yarn is the
    // first algorithm; one-line, cubist, and ink-wash styles slot in here.

    // Each algorithm is its own tab with an enable checkbox and a fully
    // independent palette / match / seed. Enabled algorithms layer on the
    // canvas (back-to-front: Wrap, Yarn, Line walk).

    @ViewBuilder private var yarnTab: some View {
        Toggle("Enable Yarn", isOn: $model.settings.landmarks.yarnEnabled)
            .font(.headline)
            .help("Weave each feature's points into a many-pass tangle.")
        overlayOffHint
        Group {
            SectionHeader("Palette")
            paletteEditor(\.landmarks.yarnPalette, match: \.landmarks.yarnMatchesLandmarkColors)
            Toggle("Match landmark colors", isOn: $model.settings.landmarks.yarnMatchesLandmarkColors)
            seedRow(\.landmarks.yarnSeed)

            SectionHeader("Yarn")
            SliderRow(title: "Density", value: floatBinding(\.landmarks.subsetRatio), defaultValue: 0.65,
                      hint: "How many points are woven — higher = denser/heavier, lower = sparser.")
            SliderRow(title: "Weave", value: floatBinding(\.landmarks.yarnWeaveAmount), defaultValue: 0.7)
            SliderRow(title: "Width", value: floatBinding(\.landmarks.yarnWidth), range: 0.7...8, defaultValue: 2.2)
            SliderRow(title: "Variation", value: floatBinding(\.landmarks.yarnWidthVariation), defaultValue: 0.35,
                      hint: "Ribbon taper/swell along the stroke (0 = constant width).")
            Toggle("Halo (glow)", isOn: $model.settings.landmarks.yarnHalo)
                .help("Add a wide dark underlay + white highlight around the ribbon.")
            HStack(alignment: .top, spacing: 10) {
                XYPad(x: floatBinding(\.landmarks.yarnLinear), y: floatBinding(\.landmarks.yarnCircular))
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text("→ linear (zigzag)")
                    Text("↑ circular (loops)")
                    Text("drag the dot").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            SliderRow(title: "Winding", value: floatBinding(\.landmarks.yarnWinding), range: 1...6, precision: 1, defaultValue: 1,
                      hint: "Loops per segment for the circular noise — >1 makes local tangles/coils.")
        }
        .disabled(!model.settings.landmarks.yarnEnabled)
    }

    @ViewBuilder private var wrapTab: some View {
        Toggle("Enable Wrap the body", isOn: $model.settings.landmarks.wrapEnabled)
            .font(.headline)
            .help("A continuous yarn-wire that winds through the inside of the person (Gormley-style).")
        overlayOffHint
        Group {
            SectionHeader("Palette")
            paletteEditor(\.landmarks.wrapPalette, match: \.landmarks.wrapMatchesLandmarkColors)
            Toggle("Match landmark colors", isOn: $model.settings.landmarks.wrapMatchesLandmarkColors)
            seedRow(\.landmarks.wrapSeed)

            SectionHeader("Wrap the body")
            SliderRow(title: "Density", value: floatBinding(\.landmarks.wrapDensity), defaultValue: 0.6,
                      hint: "How densely the wire samples inside the body — higher = woven mat, lower = sparse bent-wire.")
            Picker("Curve", selection: $model.settings.landmarks.wrapCurveFit) {
                ForEach(CurveFit.allCases) { fit in Text(fit.title).tag(fit) }
            }
            .pickerStyle(.segmented)

            SectionHeader("Wildness")
            HStack(alignment: .top, spacing: 10) {
                XYPad(x: floatBinding(\.landmarks.wrapWildnessAlong), y: floatBinding(\.landmarks.wrapWildnessOrtho))
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text("→ along path")
                    Text("↑ orthogonal")
                    Text("drag the dot").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            SliderRow(title: "Scale", value: floatBinding(\.landmarks.wrapScale), defaultValue: 0.5,
                      hint: "Local (fine) → global (coarse, whole-wire drift)")

            SectionHeader("Loops")
            SliderRow(title: "Loop", value: floatBinding(\.landmarks.wrapCircular), defaultValue: 0,
                      hint: "Coil/loop amplitude along the wire.")
            SliderRow(title: "Winding", value: floatBinding(\.landmarks.wrapWinding), range: 1...6, precision: 1, defaultValue: 1,
                      hint: "Loops per segment — >1 makes tangles.")
            SliderRow(title: "Width", value: floatBinding(\.landmarks.wrapWidth), range: 0.7...8, defaultValue: 2.2)
            SliderRow(title: "Variation", value: floatBinding(\.landmarks.wrapWidthVariation), defaultValue: 0.35,
                      hint: "Ribbon taper/swell along the wire (0 = constant width).")
            Toggle("Halo (glow)", isOn: $model.settings.landmarks.wrapHalo)
                .help("Add a wide dark underlay + white highlight around the ribbon.")
        }
        .disabled(!model.settings.landmarks.wrapEnabled)
    }

    @ViewBuilder private var lineWalkTab: some View {
        Toggle("Enable Line walk", isOn: $model.settings.landmarks.lineWalkEnabled)
            .font(.headline)
            .help("One continuous line taken for a walk through the landmarks.")
        overlayOffHint
        Group {
            SectionHeader("Palette")
            paletteEditor(\.landmarks.lineWalkPalette, match: \.landmarks.lineWalkMatchesLandmarkColors)
            Toggle("Match landmark colors", isOn: $model.settings.landmarks.lineWalkMatchesLandmarkColors)
            seedRow(\.landmarks.lineWalkSeed)

            SectionHeader("Line walk")
            SliderRow(title: "Continuity", value: floatBinding(\.landmarks.lineWalkContinuity), defaultValue: 1,
                      hint: "One continuous line → separate semantic paths → fragmented segments")
            SliderRow(title: "Density", value: floatBinding(\.landmarks.lineWalkDensity), defaultValue: 0.5,
                      hint: "Few points (minimal) → dense sampling with subdivided lines")
            Picker("Curve", selection: $model.settings.landmarks.lineWalkCurveFit) {
                ForEach(CurveFit.allCases) { fit in Text(fit.title).tag(fit) }
            }
            .pickerStyle(.segmented)

            SectionHeader("Wildness")
            HStack(alignment: .top, spacing: 10) {
                XYPad(x: floatBinding(\.landmarks.lineWalkWildnessAlong), y: floatBinding(\.landmarks.lineWalkWildnessOrtho))
                    .frame(width: 96, height: 96)
                VStack(alignment: .leading, spacing: 6) {
                    Text("→ along path")
                    Text("↑ orthogonal")
                    Text("drag the dot").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            SliderRow(title: "Scale", value: floatBinding(\.landmarks.lineWalkScale), defaultValue: 0.5,
                      hint: "Local (fine, per sub-stroke) → global (coarse, whole-line drift)")

            SectionHeader("Stroke")
            SliderRow(title: "Width", value: floatBinding(\.landmarks.lineWalkWidth), range: 0.4...8, defaultValue: 2)
            SliderRow(title: "Variation", value: floatBinding(\.landmarks.lineWalkWidthVariation), defaultValue: 0.3,
                      hint: "Width modulation along the curve (calligraphic swell)")
            Toggle("Halo (glow)", isOn: $model.settings.landmarks.lineWalkHalo)
                .help("Add a wide dark underlay + white highlight around the ribbon.")
        }
        .disabled(!model.settings.landmarks.lineWalkEnabled)
    }

    @ViewBuilder private var paperTab: some View {
        SliderRow(title: "Opacity", value: inkPaperOpacityBinding, defaultValue: 1,
                  hint: "Opacity of the internal paper substrate. 0 = transparent ink-only output.")
        DisclosureGroup("Paper settings", isExpanded: $inkPaperSettingsExpanded) {
            PaperControls(config: inkPaperConfigBinding, showsMaterialMap: false)
                .padding(.top, 4)
        }
        .disabled(inkPaperOpacityBinding.wrappedValue <= 0.001)
    }

    @ViewBuilder private var inkTab: some View {
        Group {
            SectionHeader("Inputs")
            inkInputMenu(
                title: "Surface input",
                label: inkSurfaceInputLabel,
                help: "Layer used as the ink surface/substrate. None means the ink sim has no routed surface texture.",
                binding: inkSurfaceInputMenuBinding
            )
            inkInputMenu(
                title: "Dynamic input",
                label: inkDynamicInputLabel,
                help: "Layer used for motion, wetness, and live-flow response. None disables routed dynamic input.",
                binding: inkDynamicInputMenuBinding
            )
            if inkTextureBinding.wrappedValue != .none {
                Picker("Surface blend", selection: inkPaperCompositeBinding) {
                    ForEach(InkPaperCompositeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }

            DisclosureGroup("Material map", isExpanded: $inkMaterialMapExpanded) {
                PaperMaterialMapControls(config: inkPaperConfigBinding)
                    .padding(.top, 4)
            }

            DisclosureGroup("Ink response") {
                SliderRow(title: "Surface influence", value: optionalInkConfigFloatBinding(\.surfaceInfluence, defaultValue: 0), range: 0...1, defaultValue: 0,
                          hint: "Master coupling from the surface input's material map into the ink simulation. 0 = visual only; 1 = full absorbency, drag, and fresh-ink resistance.")
                SliderRow(title: "Dynamic influence", value: optionalInkConfigFloatBinding(\.dynamicInfluence, defaultValue: 0), range: 0...1, defaultValue: 0,
                          hint: "Couples the dynamic input to absorbency, drag, and resistance. This is a changing scalar mask; it does not provide motion direction.")
                SliderRow(title: "Motion force", value: optionalInkConfigFloatBinding(\.motionForce, defaultValue: 0), range: 0...2, defaultValue: 0,
                          hint: "Strength of the dynamic input's optical-flow vector pushing wet ink. It can move only pixels that are wet.")
                SliderRow(title: "Motion wetness", value: optionalInkConfigFloatBinding(\.motionWetness, defaultValue: 0), range: 0...1, defaultValue: 0,
                          hint: "Continuously wets pixels where dynamic-input optical flow is detected, allowing that motion to carry pigment.")
                SliderRow(title: "Dynamic absorbency", value: optionalInkConfigFloatBinding(\.dynamicAbsorbency, defaultValue: 0), range: 0...1, defaultValue: 0,
                          hint: "How strongly the dynamic input accelerates wetting and drying locally.")
                SliderRow(title: "Dynamic drag", value: optionalInkConfigFloatBinding(\.dynamicDrag, defaultValue: 0.5), range: 0...2, defaultValue: 0.5,
                          hint: "How strongly the dynamic input brakes fluid and pigment movement locally.")
                SliderRow(title: "Dynamic resist", value: optionalInkConfigFloatBinding(\.dynamicResist, defaultValue: 1), range: 0...1, defaultValue: 1,
                          hint: "How strongly the dynamic input rejects newly deposited pigment. It does not erase existing ink.")
                HStack(spacing: 6) {
                    Button("Fix") { fixInk() }
                        .help("Make all current pigment permanent and immune to wash. Shortcut: Control-Option-F.")
                    Button("Unfix") { unfixInk() }
                        .help("Return permanent pigment to the ordinary dried layer so wetting and wash can mobilize it. Shortcut: Shift-Option-F.")
                    Button("Wet canvas") { wetInkCanvas() }
                        .help("Flood the persistent wetness field once. It then moves and dries normally. Shortcut: Control-Option-W.")
                    Button("Dry canvas") { dryInkCanvas() }
                        .help("Remove all wetness and fluid momentum immediately without moving or fixing pigment. Shortcut: Shift-Option-W.")
                }
                .controlSize(.small)
            }

            Toggle("Show live cursor path", isOn: $model.settings.landmarks.inkShowLivePath)
                .help("Thin dashed guide tracking the cursor while the rendered ink catches up. Off by default.")
            SliderRow(title: "Smooth", value: inkConfigFloatBinding(\.smoothing), defaultValue: 0.5,
                      hint: "Rounds the stroke as you draw — higher = smoother/laggier. Hold Shift while drawing for extra smoothing.",
                      toolbarDragProvider: { toolbarControlDragProvider(.smooth) })

            SectionHeader("Pen / Wash")
            HStack(spacing: 12) {
                Picker("Mode", selection: inkModeBinding) {
                    ForEach(InkBrushMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                .help("Pen lays a stroke of ink; Wash uses a wet brush to push, smear and blend the ink in the velocity field.")

                Picker("Ink", selection: inkKindBinding) {
                    ForEach(InkKind.allCases) { kind in Text(kind.title).tag(kind) }
                }
                .pickerStyle(.segmented)
                .help("Color = chromatic ink that uses the Ink colour. Dissolve = opaque white pigment that covers / erases (a Dissolve wash clears to paper).")
            }
            // Ink + Wash colours on one row; the checkbox next to each toggles
            // "save stroke" for that tool (off = immediate: paints straight onto
            // the canvas without recording an editable path).
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    RGBAColorPicker("Ink", rgba: inkColorRGBA, supportsOpacity: true)
                    colorResetButton("Reset ink color") { mutateActiveInkConfig { $0.inkColor = .ink } }
                    Toggle("", isOn: savePenStrokeBinding)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help("Save pen stroke as an editable path. Off = immediate (paints straight onto the canvas, not recorded).")
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    RGBAColorPicker("Wash", rgba: inkWashColorRGBA, supportsOpacity: true)
                    colorResetButton("Reset wash color") { mutateActiveInkConfig { $0.washColor = RGBAColor(red: 0.84, green: 0.85, blue: 0.89) } }
                    Toggle("", isOn: saveWashStrokeBinding)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help("Save wash stroke as an editable path. Off = immediate.")
                }
            }
            SliderRow(title: "Pen size", value: inkSizeBinding, defaultValue: 0.5,
                      hint: "Pen tip size. Type a value past 1 in the field for a bigger brush.",
                      toolbarDragProvider: { toolbarControlDragProvider(.penSize) })
            SliderRow(title: "Wash size", value: inkWashSizeBinding, defaultValue: 0.5,
                      hint: "Wash brush size — independent of the pen. Type past 1 for a bigger brush.",
                      toolbarDragProvider: { toolbarControlDragProvider(.washSize) })
            SliderRow(title: "Smear", value: inkConfigFloatBinding(\.smearStrength), defaultValue: 0.5,
                      hint: "Wash smear dial, subtle → dramatic. Low = needs a deliberate move and pushes gently (fine control); high = the slightest motion smears hard. Also sets how strongly the wash re-mobilizes dried ink.",
                      toolbarDragProvider: { toolbarControlDragProvider(.smear) })
            SliderRow(title: "Flow", value: inkConfigFloatBinding(\.flow), defaultValue: 0.9,
                      hint: "Fluid energy — higher = livelier, longer-lived motion, more swirl and bleed; lower = calmer, stays where you put it.",
                      toolbarDragProvider: { toolbarControlDragProvider(.flow) })
            SliderRow(title: "Bleed", value: inkConfigFloatBinding(\.bleed), defaultValue: 0.8,
                      hint: "Diffusion into the paper. 0 = pigment is only pushed around, conserved (acrylic-like); high = watery, dissolves and spreads. (Editable below 0 for an anti-diffuse/sharpening experiment.)",
                      toolbarDragProvider: { toolbarControlDragProvider(.bleed) })
            SliderRow(title: "Dry", value: inkConfigFloatBinding(\.dry), defaultValue: 0.25,
                      hint: "How quickly strokes dry and fix into the paper. 0 = stays wet and spreadable indefinitely; high = sets fast.",
                      toolbarDragProvider: { toolbarControlDragProvider(.dry) })
            SliderRow(title: "Wet decay", value: optionalInkConfigFloatBinding(\.wetnessDecay, defaultValue: 1), range: 0...2, defaultValue: 1,
                      hint: "Direct wetness evaporation multiplier. 0 = wetness does not decay; 1 = normal Dry/Fade behavior; above 1 evaporates faster.",
                      toolbarDragProvider: { toolbarControlDragProvider(.wetDecay) })
            SliderRow(title: "Fade", value: optionalInkConfigFloatBinding(\.fadeDuration, defaultValue: 1.2), range: 0.2...5, precision: 1, defaultValue: 1.2,
                      hint: "Seconds the ink takes to settle after you release a wash, and to fade out on Clear (C). Longer = the wash keeps softly drifting and settling, and Clear dissolves away gradually — nice for live performance.",
                      toolbarDragProvider: { toolbarControlDragProvider(.fade) })
            SliderRow(title: "Color", value: inkColorSeparationBinding, defaultValue: 0.5,
                      hint: "Chromatic separation — splits the ink into colour fringes as it bleeds.",
                      toolbarDragProvider: { toolbarControlDragProvider(.colorSeparation) })
            SliderRow(title: "Brush ink", value: inkBrushInkBinding, defaultValue: 0,
                      hint: "How much fresh pigment the wash brush itself lays down as it moves (0 = pure water/smear, no new ink).",
                      toolbarDragProvider: { toolbarControlDragProvider(.brushInk) })
            Picker("Curve", selection: inkCurveFitBinding) {
                ForEach(CurveFit.allCases) { fit in Text(fit.title).tag(fit) }
            }
            .pickerStyle(.segmented)
            .help("How recorded paths are fitted between sampled points: Polyline (straight), Spline / Hobby (smooth curves), Bezier.")
            inkSeedRow

        }
        .disabled(!model.settings.landmarks.inkEnabled)
    }

    @ViewBuilder private var historyTab: some View {
        SectionHeader("Ink actions")
        InkStrokeDataList(
            records: inkStrokeRecords,
            selectedRecordID: $selectedInkPathID
        )
        .frame(minHeight: 180)
        .help("Captured ink actions in chronological order.")

        HStack {
            Button {
                deleteSelectedInk()
            } label: {
                Label("Delete", systemImage: "delete.left")
            }
            .disabled(selectedInkPathID == nil)
            Button {
                rerenderInk()
            } label: {
                Label("Rerender", systemImage: "arrow.clockwise")
            }
            .disabled(inkStrokeRecords.isEmpty)
            Button {
                clearInk()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            Spacer(minLength: 0)
            Text("\(inkStrokeRecords.count) actions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
    }

    @ViewBuilder private var timelineTab: some View {
        SectionHeader("Timeline")
        timelineSummary
    }

    private func deleteSelectedInk() {
        model.cancelInkLiveStroke()
        guard let selectedInkPathID,
              let pathIndex = model.settings.landmarks.inkPaths.firstIndex(where: { $0.id == selectedInkPathID }) else { return }
        var next = model.settings.landmarks.inkPaths
        if let selectedInkPointIndex,
           next[pathIndex].points.indices.contains(selectedInkPointIndex),
           next[pathIndex].points.count > 2 {
            next[pathIndex].points.remove(at: selectedInkPointIndex)
            setInkPaths(next)
            self.selectedInkPointIndex = nil
        } else {
            next.remove(at: pathIndex)
            setInkPaths(next)
            self.selectedInkPathID = nil
            self.selectedInkPointIndex = nil
        }
    }

    private func clearInkSelection() {
        selectedInkPathID = nil
        selectedInkPointIndex = nil
    }

    private func clearInk() {
        model.cancelInkLiveStroke()
        let frameID = activeInkFrameID
        model.clearCanvasActions(frameID: frameID, includeUntagged: frameID == defaultInkFrameID)
        // Fade the canvas out over the Fade duration, then wipe — the engine
        // fades the live-baked + committed ink (incl. immediate-mode marks) and
        // clears the textures when the fade completes.
        mutateActiveInkConfig { $0.clearFadeRevision = ($0.clearFadeRevision ?? 0) + 1 }
        clearInkSelection()
    }

    private func fixInk() {
        mutateActiveInkConfig { $0.fixRevision = ($0.fixRevision ?? 0) + 1 }
    }

    private func unfixInk() {
        mutateActiveInkConfig { $0.unfixRevision = ($0.unfixRevision ?? 0) + 1 }
    }

    private func wetInkCanvas() {
        mutateActiveInkConfig { $0.wetCanvasRevision = ($0.wetCanvasRevision ?? 0) + 1 }
    }

    private func dryInkCanvas() {
        mutateActiveInkConfig { $0.dryCanvasRevision = ($0.dryCanvasRevision ?? 0) + 1 }
    }

    private func rerenderInk() {
        model.cancelInkLiveStroke()
        clearInkSelection()
        mutateActiveInkConfig { $0.rebuildRevision += 1 }
    }

    private func toggleInkMode() {
        mutateActiveInkConfig { $0.brushMode = currentInkMode.toggled }
    }

    private func toggleInkKind() {
        mutateActiveInkConfig { $0.inkKind = currentInkKind.toggled }
    }

    private func toggleImmediatePen() {
        mutateActiveInkConfig { $0.immediatePen.toggle() }
    }

    private func toggleImmediateWash() {
        mutateActiveInkConfig { $0.immediateWash.toggle() }
    }

    private func adjustInkWidth(by delta: Float) {
        mutateActiveInkConfig { $0.penWidth = min(1.5, max(0, $0.penWidth + delta)) }
    }

    private func adjustInkWashWidth(by delta: Float) {
        mutateActiveInkConfig {
            let v = ($0.washWidth ?? 0.5) + delta
            $0.washWidth = min(1.5, max(0, v))
        }
    }

    private func adjustInkBrushInk(by delta: Float) {
        mutateActiveInkConfig {
            let v = ($0.brushInk ?? 0) + delta
            $0.brushInk = min(1, max(0, v))
        }
    }

    private func undoInk() {
        guard model.undoCanvasAction() != nil else { return }
        clearInkSelection()
    }

    private func redoInk() {
        guard model.redoCanvasAction() != nil else { return }
        clearInkSelection()
    }

    private func setInkPaths(_ paths: [InkEditorPath]) {
        model.cancelInkLiveStroke()
        let old = model.settings.landmarks.inkPaths
        guard old != paths else { return }
        model.replaceEditableCanvasPaths(paths)
    }

    private func commitCanvasStrokeRecord(_ record: InkStrokeRecord) {
        if record.isEditable {
            model.commitEditableCanvasStroke(record)
        } else {
            model.commitImmediateCanvasStroke(record)
        }
    }

    private var currentInkMode: InkBrushMode {
        activeInkConfig.brushMode ?? .pen
    }

    private var currentInkKind: InkKind {
        activeInkConfig.inkKind ?? .black
    }

    private var inkPathsBinding: Binding<[InkEditorPath]> {
        Binding(
            get: { model.settings.landmarks.inkPaths },
            set: { setInkPaths($0) }
        )
    }

    private var inkStrokeRecords: [InkStrokeRecord] {
        model.settings.landmarks.resolvedInkStrokeRecords()
    }

    private var inkModeBinding: Binding<InkBrushMode> {
        Binding(
            get: { currentInkMode },
            set: { value in mutateActiveInkConfig { $0.brushMode = value } }
        )
    }

    private var inkKindBinding: Binding<InkKind> {
        Binding(
            get: { currentInkKind },
            set: { value in mutateActiveInkConfig { $0.inkKind = value } }
        )
    }

    private var inkSizeBinding: Binding<Double> {
        Binding(
            // No upper clamp: the slider stays 0…1, but the editable field can
            // type past 1 for a bigger pen (engine caps it safely).
            get: { Double(max(0, activeInkConfig.penWidth)) },
            set: { value in mutateActiveInkConfig { $0.penWidth = Float(value) } }
        )
    }

    private var inkWashSizeBinding: Binding<Double> {
        Binding(
            get: { Double(max(0, activeInkConfig.washWidth ?? 0.5)) },
            set: { value in mutateActiveInkConfig { $0.washWidth = Float(value) } }
        )
    }

    private var inkColorSeparationBinding: Binding<Double> {
        optionalInkConfigFloatBinding(\.colorSeparation, defaultValue: 0.5)
    }

    private var inkBrushInkBinding: Binding<Double> {
        optionalInkConfigFloatBinding(\.brushInk, defaultValue: 0)
    }

    @ViewBuilder private func colorResetButton(_ help: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "arrow.uturn.backward")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .foregroundStyle(.secondary)
        .help(help)
    }

    private var inkColorRGBA: Binding<RGBAColor> {
        Binding(get: { activeInkConfig.inkColor },
                set: { value in mutateActiveInkConfig { $0.inkColor = value } })
    }
    private var inkWashColorRGBA: Binding<RGBAColor> {
        Binding(get: { activeInkConfig.washColor ?? RGBAColor(red: 0.84, green: 0.85, blue: 0.89) },
                set: { value in mutateActiveInkConfig { $0.washColor = value } })
    }
    private var inkPaperColorRGBA: Binding<RGBAColor> {
        Binding(get: { model.settings.landmarks.inkPaperColor },
                set: { model.settings.landmarks.inkPaperColor = $0 })
    }

    private var inkPaperConfigBinding: Binding<PaperConfig> {
        Binding(
            get: {
                if let config = model.settings.landmarks.inkPaperConfig { return config }
                var legacy = PaperConfig.metalDefault
                legacy.tint = model.settings.landmarks.inkPaperColor
                legacy.grain = model.settings.landmarks.inkPaperGrain
                return legacy
            },
            set: { config in
                model.settings.landmarks.inkPaperConfig = config
                model.settings.landmarks.inkPaperColor = config.tint
                model.settings.landmarks.inkPaperGrain = config.grain
            }
        )
    }

    private var inkPaperCompositeBinding: Binding<InkPaperCompositeMode> {
        Binding(
            get: { activeInkConfig.surfaceCompositeMode ?? .none },
            set: { value in mutateActiveInkConfig { $0.surfaceCompositeMode = value } }
        )
    }
    private var inkPaperOpacityBinding: Binding<Double> {
        Binding(
            get: {
                Double(model.settings.landmarks.inkPaperOpacity ?? (model.settings.landmarks.inkPaperEnabled ? 1 : 0))
            },
            set: {
                let opacity = Float(max(0, min(1, $0)))
                model.settings.landmarks.inkPaperOpacity = opacity
                model.settings.landmarks.inkPaperEnabled = opacity > 0.001
            }
        )
    }
    private var inkPaperEnabledBinding: Binding<Bool> {
        Binding(
            get: { inkPaperOpacityBinding.wrappedValue > 0.001 },
            set: { isOn in
                model.settings.landmarks.inkPaperOpacity = isOn ? max(Float(inkPaperOpacityBinding.wrappedValue), 1) : 0
                model.settings.landmarks.inkPaperEnabled = isOn
            }
        )
    }
    private func panelVisibilityBinding(for panel: ControlTab) -> Binding<Bool>? {
        switch panel {
        case .ink:
            return $model.settings.landmarks.inkEnabled
        case .paper:
            return inkPaperEnabledBinding
        default:
            return nil
        }
    }
    private var inkSurfaceInputMenuBinding: Binding<PortBinding?> {
        Binding(
            get: { inkTextureBinding.wrappedValue },
            set: { inkTextureBinding.wrappedValue = $0 ?? .none }
        )
    }
    private var inkDynamicInputMenuBinding: Binding<PortBinding?> {
        Binding(
            get: { activeInkConfig.dynamicInput ?? .none },
            set: { value in mutateActiveInkConfig { $0.dynamicInput = value } }
        )
    }
    private var inkTextureBinding: Binding<PortBinding> {
        Binding(
            get: {
                let graph = (model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)).reconciled(with: model.settings)
                guard let inkNodeID = activeInkNodeID(in: graph),
                      let inkNode = graph.node(inkNodeID),
                      let textureIndex = inkNode.kind.ports.firstIndex(where: { $0.name == "texture" }),
                      inkNode.inputs.indices.contains(textureIndex) else { return .none }
                return inkNode.inputs[textureIndex]
            },
            set: { newValue in
                var graph = (model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)).reconciled(with: model.settings)
                guard let inkNodeID = activeInkNodeID(in: graph),
                      let nodeIndex = graph.nodes.firstIndex(where: { $0.id == inkNodeID }),
                      let textureIndex = graph.nodes[nodeIndex].kind.ports.firstIndex(where: { $0.name == "texture" }),
                      graph.nodes[nodeIndex].inputs.indices.contains(textureIndex) else { return }
                graph.nodes[nodeIndex].inputs[textureIndex] = newValue
                guard (try? graph.validate()) != nil else { return }
                model.settings.layerGraph = graph
                model.settings.useLayerGraph = true
            }
        )
    }
    private var inkSurfaceInputLabel: String {
        portBindingLabel(inkTextureBinding.wrappedValue, noneLabel: "None", nilLabel: "None")
    }
    private var inkDynamicInputLabel: String {
        portBindingLabel(activeInkConfig.dynamicInput ?? .none, noneLabel: "None", nilLabel: "None")
    }

    @ViewBuilder private func inkInputMenu(
        title: String,
        label: String,
        help: String,
        binding: Binding<PortBinding?>
    ) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Menu(label) {
                Button("None") { binding.wrappedValue = PortBinding.none }
                Divider()
                Button("Camera source") { binding.wrappedValue = .source(.camera) }
                Button("Person Key") { binding.wrappedValue = .source(.personMatte) }
                let sources = inkTextureSources()
                if !sources.isEmpty {
                    Divider()
                    ForEach(sources, id: \.id) { source in
                        Button(source.name) { binding.wrappedValue = .node(source.id) }
                    }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(help)
        }
    }

    private func portBindingLabel(_ binding: PortBinding?, noneLabel: String, nilLabel: String) -> String {
        guard let binding else { return nilLabel }
        switch binding {
        case .none:
            return noneLabel
        case .source(let source):
            switch source {
            case .camera: return "Camera source"
            case .personMatte: return "Person Key"
            case .landmarks: return "Landmarks"
            case .mouse: return "Mouse"
            }
        case .node(let id):
            return inkTextureSources().first { $0.id == id }?.name ?? "Layer"
        }
    }
    private func activeInkNodeID(in graph: LayerGraph) -> UUID? {
        if let activeFrameID = activeInkFrameID,
           let workspace = model.settings.workspace,
           let frame = workspace.frame(id: activeFrameID),
           case .layer(let layerID) = frame.material,
           let layer = graph.layers.first(where: { $0.id == layerID }),
           let node = graph.node(layer.node),
           node.kind.family == "ink" {
            return node.id
        }
        return graph.nodes.first(where: { $0.kind.family == "ink" })?.id
    }

    private var activeInkConfig: InkFrameConfig {
        let graph = (model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)).reconciled(with: model.settings)
        guard let nodeID = activeInkNodeID(in: graph),
              let node = graph.node(nodeID) else {
            return InkFrameConfig(landmarks: model.settings.landmarks)
        }
        return node.inkConfig ?? InkFrameConfig(landmarks: model.settings.landmarks)
    }

    private func mutateActiveInkConfig(_ mutate: (inout InkFrameConfig) -> Void) {
        var graph = (model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)).reconciled(with: model.settings)
        guard let nodeID = activeInkNodeID(in: graph),
              let nodeIndex = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        var config = graph.nodes[nodeIndex].inkConfig ?? InkFrameConfig(landmarks: model.settings.landmarks)
        mutate(&config)
        graph.nodes[nodeIndex].inkConfig = config
        model.settings.layerGraph = graph
        model.settings.useLayerGraph = true
    }

    private func inkConfigFloatBinding(_ keyPath: WritableKeyPath<InkFrameConfig, Float>) -> Binding<Double> {
        Binding(
            get: { Double(activeInkConfig[keyPath: keyPath]) },
            set: { value in mutateActiveInkConfig { $0[keyPath: keyPath] = Float(value) } }
        )
    }

    private func optionalInkConfigFloatBinding(_ keyPath: WritableKeyPath<InkFrameConfig, Float?>, defaultValue: Float) -> Binding<Double> {
        Binding(
            get: { Double(activeInkConfig[keyPath: keyPath] ?? defaultValue) },
            set: { value in mutateActiveInkConfig { $0[keyPath: keyPath] = Float(value) } }
        )
    }

    private var inkCurveFitBinding: Binding<CurveFit> {
        Binding(
            get: { activeInkConfig.curveFit },
            set: { value in mutateActiveInkConfig { $0.curveFit = value } }
        )
    }

    private var inkSeedBinding: Binding<Int> {
        Binding(
            get: { activeInkConfig.seed },
            set: { value in mutateActiveInkConfig { $0.seed = value } }
        )
    }

    private func inkTextureSources() -> [(id: UUID, name: String)] {
        let graph = (model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)).reconciled(with: model.settings)
        guard let inkNodeID = activeInkNodeID(in: graph) else { return [] }
        return graph.layers.compactMap { layer in
            guard layer.node != inkNodeID, let node = graph.node(layer.node), node.kind.output == .pixel else { return nil }
            return (id: node.id, name: node.name)
        }
    }
    // "Save stroke" = the inverse of immediate mode (off = immediate).
    private var savePenStrokeBinding: Binding<Bool> {
        Binding(get: { !activeInkConfig.immediatePen },
                set: { value in mutateActiveInkConfig { $0.immediatePen = !value } })
    }
    private var saveWashStrokeBinding: Binding<Bool> {
        Binding(get: { !activeInkConfig.immediateWash },
                set: { value in mutateActiveInkConfig { $0.immediateWash = !value } })
    }

    @ViewBuilder private var overlayOffHint: some View {
        if !model.settings.landmarks.enabled {
            Text("Landmark overlay is off — enable it in Marks to draw.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func rgbaColor(_ color: RGBAColor) -> Color {
        Color(.sRGB, red: Double(color.red), green: Double(color.green), blue: Double(color.blue), opacity: Double(color.alpha))
    }

    @ViewBuilder private func seedRow(_ keyPath: WritableKeyPath<ProcessingSettings, Int>) -> some View {
        SectionHeader("Seed")
        HStack {
            Stepper(
                value: Binding(get: { model.settings[keyPath: keyPath] }, set: { model.settings[keyPath: keyPath] = $0 }),
                in: 0...99_999
            ) {
                Text("Seed \(model.settings[keyPath: keyPath])").monospacedDigit()
            }
            Button("Shuffle") { model.settings[keyPath: keyPath] = Int.random(in: 0..<100_000) }
        }
    }

    @ViewBuilder private var inkSeedRow: some View {
        SectionHeader("Seed")
        HStack {
            Stepper(value: inkSeedBinding, in: 0...99_999) {
                Text("Seed \(activeInkConfig.seed)").monospacedDigit()
            }
            Button("Shuffle") { mutateActiveInkConfig { $0.seed = Int.random(in: 0..<100_000) } }
        }
    }

    /// Editable color list for one algorithm's palette. Starts as one solid
    /// color; "+" adds more (algorithms cycle through them per feature).
    @ViewBuilder private func paletteEditor(
        _ keyPath: WritableKeyPath<ProcessingSettings, DrawingPalette>,
        match: WritableKeyPath<ProcessingSettings, Bool>
    ) -> some View {
        let colors = model.settings[keyPath: keyPath].colors
        VStack(alignment: .leading, spacing: 6) {
            ForEach(colors.indices, id: \.self) { index in
                HStack {
                    ColorPicker("", selection: paletteColorBinding(keyPath, index), supportsOpacity: true)
                        .labelsHidden()
                    Text("Color \(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if colors.count > 1 {
                        Button {
                            model.settings[keyPath: keyPath].colors.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button {
                let last = model.settings[keyPath: keyPath].colors.last ?? .ink
                model.settings[keyPath: keyPath].colors.append(last)
            } label: {
                Label("Add color", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .disabled(model.settings[keyPath: match])
    }

    private func paletteColorBinding(_ keyPath: WritableKeyPath<ProcessingSettings, DrawingPalette>, _ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let colors = model.settings[keyPath: keyPath].colors
                guard colors.indices.contains(index) else { return .black }
                let c = colors[index]
                return Color(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue), opacity: Double(c.alpha))
            },
            set: { newValue in
                guard model.settings[keyPath: keyPath].colors.indices.contains(index),
                      let converted = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                model.settings[keyPath: keyPath].colors[index] = RGBAColor(
                    red: Float(converted.redComponent),
                    green: Float(converted.greenComponent),
                    blue: Float(converted.blueComponent),
                    alpha: Float(converted.alphaComponent)
                )
            }
        )
    }

    // MARK: - Web tab
    //
    // Renders a web page (remote/local URL) as a compositing layer with an
    // optional transparent background, ordered behind or above the drawing.

    @ViewBuilder private var webTab: some View {
        Toggle("Enable web layer", isOn: $model.settings.web.enabled)
            .font(.headline)

        Group {
            SectionHeader("Source")
            Picker("Source", selection: $model.settings.web.useSnippet) {
                Text("URL").tag(false)
                Text("Snippet").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if model.settings.web.useSnippet {
                TextEditor(text: $webSnippetField)
                    .font(.system(.caption, design: .monospaced))
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                Button("Run") {
                    model.settings.web.htmlSnippet = webSnippetField
                    model.settings.web.useSnippet = true
                }
                Text("Paste a full HTML document — inline <style>/<script> are fine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("https://… or local path", text: $webURLField)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.settings.web.urlString = webURLField }
                    Button("Load") { model.settings.web.urlString = webURLField }
                }
                HStack {
                    Button("Choose file…") { model.chooseWebFile() }
                    Spacer()
                    Button { model.webGoBack() } label: { Image(systemName: "chevron.left") }
                    Button { model.webGoForward() } label: { Image(systemName: "chevron.right") }
                    Button { model.webReload() } label: { Image(systemName: "arrow.clockwise") }
                }
                .controlSize(.small)
                Text("Remote URL, or a local file/folder picked via Choose (a typed path is blocked by the sandbox).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            SectionHeader("Layer")
            Toggle("Transparent background", isOn: $model.settings.web.transparentBackground)
                .help("Strip the page's and the web view's background so it composites as a transparent layer.")
            Picker("Order", selection: $model.settings.web.placement) {
                ForEach(WebLayerPlacement.allCases) { p in Text(p.title).tag(p) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            SliderRow(title: "Opacity", value: floatBinding(\.web.opacity), defaultValue: 1)
            SliderRow(title: "Refresh fps", value: floatBinding(\.web.refreshFPS), range: 1...60, precision: 0, defaultValue: 20,
                      hint: "How often the page is re-snapshotted into the frame (independent of output fps).")

            SectionHeader("Interact")
            Toggle("Browser window", isOn: $model.settings.web.interactive)
                .help("Open the page as a real window you can click / scroll / type in. It keeps compositing into the frame; closing the window turns this off.")
        }
        .disabled(!model.settings.web.enabled)
        .onAppear {
            if webURLField.isEmpty { webURLField = model.settings.web.urlString }
            if webSnippetField.isEmpty { webSnippetField = model.settings.web.htmlSnippet }
        }
    }

    // MARK: - Presets tab
    //
    // A preset captures the whole LandmarkSettings — Marks toggles, all three
    // drawing algorithms (each with its own palette/seed/params), and the
    // detection config — so the user can store and recall complete looks.

    @ViewBuilder private var presetsTab: some View {
        SectionHeader("Save current")
        HStack {
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { saveCurrentPreset() }
            Button("Save") { saveCurrentPreset() }
        }

        SectionHeader("Recall")
        Picker("Recall", selection: $recallWholeState) {
            Text("Render style").tag(false)
            Text("Whole state").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(recallWholeState
             ? "Loading applies the entire saved state (effects, threshold, background + drawing)."
             : "Loading applies only the render style (Marks, Drawing algorithms, Detection).")
            .font(.caption)
            .foregroundStyle(.secondary)

        SectionHeader("Presets")
        if presetStore.presets.isEmpty {
            Text("No presets yet — save the current state above.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(presetStore.presets) { preset in
                HStack {
                    Button {
                        apply(preset)
                    } label: {
                        Label(preset.name, systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Button {
                        presetStore.save(name: preset.name, settings: model.settings)
                    } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderless)
                    .help("Overwrite this preset with the current state.")
                    Button {
                        presetStore.delete(preset)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }

        Text("A preset saves the entire state. Recall mode (above) chooses render-style-only or whole-state. Saved across launches.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func apply(_ preset: DrawingPreset) {
        if recallWholeState {
            model.settings = preset.settings
        } else {
            model.settings.landmarks = preset.settings.landmarks
        }
        model.prepareInkStrokeRecordsForCurrentSettings()
    }

    private func saveCurrentPreset() {
        presetStore.save(name: newPresetName, settings: model.settings)
        newPresetName = ""
    }

    // MARK: - Debug tab

    @ViewBuilder private var debugTab: some View {
        LiveDebugGrid(live: model.live, permission: model.cameraPermissionState.rawValue, threshold: model.settings.threshold)


        if let error = model.errorText {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Keys tab

    @ViewBuilder private var keysTab: some View {
        let grouped = Dictionary(grouping: shortcuts.actions, by: \.category)
        ForEach(grouped.keys.sorted(), id: \.self) { category in
            SectionHeader(category)
            ForEach(grouped[category] ?? []) { action in
                HStack {
                    Text(action.title)
                    Spacer()
                    Button {
                        shortcuts.recordingActionID = shortcuts.recordingActionID == action.id ? nil : action.id
                    } label: {
                        Text(shortcuts.recordingActionID == action.id
                             ? "press keys…"
                             : (shortcuts.bindings[action.id]?.display ?? "—"))
                            .monospaced()
                            .frame(minWidth: 70)
                    }
                    Button {
                        shortcuts.resetBinding(for: action.id)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .disabled(shortcuts.isDefault(action.id))
                    .help("Reset to default")
                    Button {
                        shortcuts.setBinding(nil, for: action.id)
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .disabled(shortcuts.bindings[action.id] == nil)
                    .help("Remove binding")
                }
                .controlSize(.small)
            }
        }
        Text("Click a binding, then press the new keys. Esc cancels. Assigning a combo steals it from any conflicting action.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func registerShortcuts() {
        let r = ShortcutRegistry.shared
        r.register(id: "transport.freezePause", title: "Freeze / Pause", category: "Transport",
                   default: KeyBinding(key: "f", modifiers: .command)) { [weak model] in model?.toggleFreezeOrPause() }
        r.register(id: "transport.export", title: "Export Frame", category: "Transport",
                   default: KeyBinding(key: "e", modifiers: .command)) { [weak model] in model?.exportCurrentFrame() }
        r.register(id: "window.panel", title: "Toggle Side Panel (fit canvas)", category: "Window",
                   default: KeyBinding(key: "u", modifiers: [.command, .option])) { [weak windowMode] in windowMode?.togglePanelFit() }
        r.register(id: "window.panelOverlay", title: "Toggle Side Panel (overlay)", category: "Window",
                   default: KeyBinding(key: "u", modifiers: [.shift, .option])) { [weak windowMode] in windowMode?.togglePanelOverlay() }
        r.register(id: "window.leftDock", title: "Toggle Left Dock", category: "Window",
                   default: KeyBinding(key: "b", modifiers: .command)) {
            toggleLeftDockSide()
        }
        r.register(id: "window.rightDock", title: "Toggle Right Dock", category: "Window",
                   default: KeyBinding(key: "b", modifiers: [.command, .option])) {
            toggleRightDockSide()
        }
        r.register(id: "window.decoration", title: "Toggle Window Decoration", category: "Window",
                   default: KeyBinding(key: "d", modifiers: [.option, .shift])) { [weak windowMode] in windowMode?.decorated.toggle() }
        r.register(id: "window.transparent", title: "Toggle Transparent Window", category: "Window",
                   default: KeyBinding(key: "t", modifiers: [.command, .option])) { [weak windowMode] in windowMode?.transparent.toggle() }
        r.register(id: "window.onTop", title: "Toggle Always on Top", category: "Window",
                   default: KeyBinding(key: "t", modifiers: [.option, .shift])) { [weak windowMode] in windowMode?.alwaysOnTop.toggle() }
        r.register(id: "window.pip", title: "Toggle PIP Placement", category: "Window",
                   default: KeyBinding(key: "p", modifiers: [.option, .shift])) { [weak windowMode] in windowMode?.togglePIP() }
        r.register(id: "window.presentation", title: "Presentation Mode", category: "Window",
                   default: KeyBinding(key: "p", modifiers: .command)) { [weak windowMode] in windowMode?.togglePresentationMode() }
        r.register(id: "debug.overlay", title: "Toggle Performance Overlay", category: "Debug",
                   default: KeyBinding(key: "p", modifiers: [.control, .option])) {
            appUI.toggleDebugOverlay()
        }
        r.register(id: "ink.tool.select", title: "Ink: Select Tool", category: "Ink",
                   default: KeyBinding(key: "v", modifiers: [])) {
            guard tab == .ink else { return }
            inkTool = .select
        }
        r.register(id: "ink.tool.selectNumber", title: "Ink: Select Tool (1)", category: "Ink",
                   default: KeyBinding(key: "1", modifiers: [])) {
            guard tab == .ink else { return }
            inkTool = .select
        }
        r.register(id: "ink.tool.draw", title: "Ink: Draw Tool", category: "Ink",
                   default: KeyBinding(key: "p", modifiers: [])) {
            guard tab == .ink else { return }
            inkTool = .draw
        }
        r.register(id: "ink.tool.drawNumber", title: "Ink: Draw Tool (7)", category: "Ink",
                   default: KeyBinding(key: "7", modifiers: [])) {
            guard tab == .ink else { return }
            inkTool = .draw
        }
        r.register(id: "ink.tool.points", title: "Ink: Points Tool", category: "Ink",
                   default: KeyBinding(key: "a", modifiers: [])) {
            guard tab == .ink else { return }
            inkTool = .points
        }
        r.register(id: "ink.delete", title: "Ink: Delete Selected", category: "Ink",
                   default: KeyBinding(key: "delete", modifiers: [])) {
            guard tab == .ink else { return }
            deleteSelectedInk()
        }
        r.register(id: "ink.mode.toggle", title: "Ink: Pen / Wash", category: "Ink",
                   default: KeyBinding(key: "b", modifiers: [])) {
            guard tab == .ink else { return }
            toggleInkMode()
        }
        r.register(id: "ink.kind.toggle", title: "Ink: Black / White", category: "Ink",
                   default: KeyBinding(key: "w", modifiers: [])) {
            guard tab == .ink else { return }
            toggleInkKind()
        }
        r.register(id: "ink.fix", title: "Ink: Fix", category: "Ink",
                   default: KeyBinding(key: "f", modifiers: [.control, .option])) {
            guard tab == .ink else { return }
            fixInk()
        }
        r.register(id: "ink.unfix", title: "Ink: Unfix", category: "Ink",
                   default: KeyBinding(key: "f", modifiers: [.shift, .option])) {
            guard tab == .ink else { return }
            unfixInk()
        }
        r.register(id: "ink.wetCanvas", title: "Ink: Wet Canvas", category: "Ink",
                   default: KeyBinding(key: "w", modifiers: [.control, .option])) {
            guard tab == .ink else { return }
            wetInkCanvas()
        }
        r.register(id: "ink.dryCanvas", title: "Ink: Dry Canvas", category: "Ink",
                   default: KeyBinding(key: "w", modifiers: [.shift, .option])) {
            guard tab == .ink else { return }
            dryInkCanvas()
        }
        r.register(id: "ink.clear", title: "Ink: Clear", category: "Ink",
                   default: KeyBinding(key: "c", modifiers: [])) {
            guard tab == .ink else { return }
            clearInk()
        }
        r.register(id: "ink.save", title: "Ink: Save PNG", category: "Ink",
                   default: KeyBinding(key: "s", modifiers: [])) { [weak model] in
            guard tab == .ink else { return }
            model?.exportCurrentFrame()
        }
        r.register(id: "ink.fullscreen", title: "Ink: Fullscreen", category: "Ink",
                   default: KeyBinding(key: "f", modifiers: [])) { [weak windowMode] in
            guard tab == .ink else { return }
            windowMode?.togglePresentationMode()
        }
        r.register(id: "ink.undo", title: "Ink: Undo", category: "Ink",
                   default: KeyBinding(key: "z", modifiers: .command)) {
            guard tab == .ink else { return }
            undoInk()
        }
        r.register(id: "ink.redo", title: "Ink: Redo", category: "Ink",
                   default: KeyBinding(key: "z", modifiers: [.command, .shift])) {
            guard tab == .ink else { return }
            redoInk()
        }
        r.register(id: "ink.redoAction", title: "Ink: Redo Last Action", category: "Ink",
                   default: KeyBinding(key: "r", modifiers: [.command, .shift])) {
            redoInk()
        }
        r.register(id: "ink.immediate.pen", title: "Ink: Toggle Immediate Pen", category: "Ink",
                   default: KeyBinding(key: "i", modifiers: [])) {
            guard tab == .ink else { return }
            toggleImmediatePen()
        }
        r.register(id: "ink.immediate.wash", title: "Ink: Toggle Immediate Wash", category: "Ink",
                   default: KeyBinding(key: "o", modifiers: [])) {
            guard tab == .ink else { return }
            toggleImmediateWash()
        }
        r.register(id: "ink.size.decrease", title: "Ink: Decrease Brush Size", category: "Ink",
                   default: KeyBinding(key: "[", modifiers: [])) {
            guard tab == .ink else { return }
            adjustInkWidth(by: -0.05)
        }
        r.register(id: "ink.size.increase", title: "Ink: Increase Brush Size", category: "Ink",
                   default: KeyBinding(key: "]", modifiers: [])) {
            guard tab == .ink else { return }
            adjustInkWidth(by: 0.05)
        }
        // Shift+[ / Shift+] resize the WASH brush (the chars are { } once Shift is
        // applied). Pen size uses plain [ ].
        r.register(id: "ink.washSize.decrease", title: "Ink: Decrease Wash Size", category: "Ink",
                   default: KeyBinding(key: "{", modifiers: .shift)) {
            guard tab == .ink else { return }
            adjustInkWashWidth(by: -0.05)
        }
        r.register(id: "ink.washSize.increase", title: "Ink: Increase Wash Size", category: "Ink",
                   default: KeyBinding(key: "}", modifiers: .shift)) {
            guard tab == .ink else { return }
            adjustInkWashWidth(by: 0.05)
        }
        r.register(id: "ink.brushInk.decrease", title: "Ink: Decrease Brush Ink", category: "Ink",
                   default: KeyBinding(key: "<", modifiers: .shift)) {
            guard tab == .ink else { return }
            adjustInkBrushInk(by: -0.05)
        }
        r.register(id: "ink.brushInk.increase", title: "Ink: Increase Brush Ink", category: "Ink",
                   default: KeyBinding(key: ">", modifiers: .shift)) {
            guard tab == .ink else { return }
            adjustInkBrushInk(by: 0.05)
        }
    }

    // MARK: - Bindings

    /// A landmark feature row (enable + color + size), keyed off a track flag
    /// and an ElementStyle on the settings.
    private func featureRow(
        _ title: String,
        track: WritableKeyPath<ProcessingSettings, Bool>,
        style: WritableKeyPath<ProcessingSettings, ElementStyle>
    ) -> some View {
        StyleRow(
            title: title,
            enabled: boolBinding(track),
            color: rgbaBinding(style.appending(path: \.color)),
            size: floatBinding(style.appending(path: \.size)),
            range: 0.7...8
        )
    }

    private func boolBinding(_ keyPath: WritableKeyPath<ProcessingSettings, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { model.settings[keyPath: keyPath] = $0 }
        )
    }

    private var artboardDragCanvasWithScrollBinding: Binding<Bool> {
        Binding(
            get: { model.settings.resolvedArtboardDragCanvasWithScroll },
            set: { model.settings.artboardDragCanvasWithScroll = $0 }
        )
    }

    private func floatBinding(_ keyPath: WritableKeyPath<ProcessingSettings, Float>) -> Binding<Double> {
        Binding(
            get: { Double(model.settings[keyPath: keyPath]) },
            set: { model.settings[keyPath: keyPath] = Float($0) }
        )
    }

    private func optionalLandmarkFloatBinding(_ keyPath: WritableKeyPath<LandmarkSettings, Float?>, defaultValue: Float) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.landmarks[keyPath: keyPath] ?? defaultValue) },
            set: { model.settings.landmarks[keyPath: keyPath] = Float($0) }
        )
    }

    private func rgbaBinding(_ keyPath: WritableKeyPath<ProcessingSettings, RGBAColor>) -> Binding<Color> {
        Binding(
            get: {
                let c = model.settings[keyPath: keyPath]
                return Color(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue), opacity: Double(c.alpha))
            },
            set: { newValue in
                guard let converted = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                model.settings[keyPath: keyPath] = RGBAColor(
                    red: Float(converted.redComponent),
                    green: Float(converted.greenComponent),
                    blue: Float(converted.blueComponent),
                    alpha: Float(converted.alphaComponent)
                )
            }
        )
    }

    private var inkColorPickerBinding: Binding<Color> {
        Binding(
            get: {
                let c = activeInkConfig.inkColor
                return Color(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue), opacity: Double(c.alpha))
            },
            set: { newValue in
                guard let converted = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                mutateActiveInkConfig {
                    $0.inkColor = RGBAColor(
                        red: Float(converted.redComponent),
                        green: Float(converted.greenComponent),
                        blue: Float(converted.blueComponent),
                        alpha: Float(converted.alphaComponent)
                    )
                }
            }
        )
    }
}

// MARK: - Components

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.bold))
            .tracking(0.5)
            .foregroundStyle(.secondary)
            .padding(.top, 5)
    }
}

/// ColorPicker bound to an `RGBAColor`. Keeps the picker's own `Color` state and
/// only writes to the model on real changes (and resyncs only on EXTERNAL model
/// changes) — round-tripping the model binding through sRGB on every micro-edit
/// made the system picker re-derive HSB and jump (hue moved when dragging
/// brightness). This breaks that feedback loop.
private struct RGBAColorPicker: View {
    let label: String
    @Binding var rgba: RGBAColor
    var supportsOpacity: Bool = true
    @State private var color: Color

    init(_ label: String, rgba: Binding<RGBAColor>, supportsOpacity: Bool = true) {
        self.label = label
        self._rgba = rgba
        self.supportsOpacity = supportsOpacity
        self._color = State(initialValue: Self.toColor(rgba.wrappedValue))
    }

    var body: some View {
        ColorPicker(label, selection: $color, supportsOpacity: supportsOpacity)
            .onChange(of: color) { _, new in
                let c = Self.toRGBA(new)
                if c != rgba { rgba = c }
            }
            .onChange(of: rgba) { _, new in
                // Only resync when the model changed externally (e.g. reset),
                // not from our own write above (compare in RGBA space).
                if Self.toRGBA(color) != new { color = Self.toColor(new) }
            }
    }

    static func toColor(_ c: RGBAColor) -> Color {
        Color(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue), opacity: Double(c.alpha))
    }
    static func toRGBA(_ color: Color) -> RGBAColor {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
        return RGBAColor(red: Float(ns.redComponent), green: Float(ns.greenComponent), blue: Float(ns.blueComponent), alpha: Float(ns.alphaComponent))
    }
}

/// The Layers panel (Phase 3a): reorder / show-hide / opacity for the composited
/// layers, driving `settings.layerGraph`. Reorder is via up/down buttons (drag
/// reordering inside a non-List settings panel is unreliable on macOS).
/// The mask control at the top of a layer panel: pick a matte source (None /
/// Person / another named stream) and, when set, the keying mode + invert.
private struct MaskEditor: View {
    @Binding var mask: MaskBinding?
    @Binding var personMatteQuality: SegmentationQuality
    /// Other layers that can serve as a matte (node id + display name).
    let sources: [(id: UUID, name: String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Mask").font(.caption).foregroundStyle(.secondary)
                Menu(currentLabel) {
                    Button("None") { mask = nil }
                    Button("Person Key") { setSource(.source(.personMatte)) }
                    if !sources.isEmpty {
                        Divider()
                        ForEach(sources, id: \.id) { src in
                            Button(src.name) { setSource(.node(src.id)) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if mask != nil {
                if isPersonKeyMask {
                    Toggle("Key out person (invert)", isOn: personKeyInvertBinding).controlSize(.small)
                    Toggle("Silhouette (flat fill)", isOn: personKeySilhouetteBinding).controlSize(.small)
                    if mask?.personKeySilhouette == true {
                        ColorPicker("Fill", selection: personKeyColorBinding, supportsOpacity: true).controlSize(.small)
                    }
                    Picker("Matte", selection: $personMatteQuality) {
                        ForEach(SegmentationQuality.allCases) { q in Text(q.title).tag(q) }
                    }
                    .pickerStyle(.segmented).controlSize(.small)
                }
                Picker("Mode", selection: modeBinding) {
                    Text("Luma").tag(MaskBinding.Mode.luma)
                    Text("Threshold").tag(MaskBinding.Mode.threshold)
                    Text("Inv").tag(MaskBinding.Mode.invThreshold)
                }
                .pickerStyle(.segmented).controlSize(.small)
                if mask?.mode != .luma {
                    HStack {
                        Text("Level").font(.caption2).frame(width: 56, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture(count: 2) { levelBinding.wrappedValue = 0.5 }
                            .help("Double-click to reset")
                        Slider(value: levelBinding, in: 0...1).controlSize(.small)
                    }
                }
                Toggle("Invert matte", isOn: invertBinding).controlSize(.small)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private var currentLabel: String {
        guard let mask else { return "None" }
        switch mask.source {
        case .none: return "None"
        case .source(let s): return s == .personMatte ? "Person Key" : "Source"
        case .node(let id): return sources.first { $0.id == id }?.name ?? "Layer"
        }
    }

    private func setSource(_ source: PortBinding) {
        if var m = mask { m.source = source; mask = m }
        else { mask = MaskBinding(source: source) }
    }

    private var isPersonKeyMask: Bool {
        guard case .source(.personMatte)? = mask?.source else { return false }
        return true
    }

    private var modeBinding: Binding<MaskBinding.Mode> {
        Binding(get: { mask?.mode ?? .luma }, set: { v in if var m = mask { m.mode = v; mask = m } })
    }
    private var levelBinding: Binding<Float> {
        Binding(get: { mask?.level ?? 0.5 }, set: { v in if var m = mask { m.level = v; mask = m } })
    }
    private var invertBinding: Binding<Bool> {
        Binding(get: { mask?.invert ?? false }, set: { v in if var m = mask { m.invert = v; mask = m } })
    }
    private var personKeyInvertBinding: Binding<Bool> {
        Binding(get: { mask?.personKeyInvert ?? false }, set: { v in if var m = mask { m.personKeyInvert = v; mask = m } })
    }
    private var personKeySilhouetteBinding: Binding<Bool> {
        Binding(get: { mask?.personKeySilhouette ?? false }, set: { v in if var m = mask { m.personKeySilhouette = v; mask = m } })
    }
    private var personKeyColorBinding: Binding<Color> {
        Binding(
            get: {
                let c = mask?.personKeyColor ?? RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
                return Color(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue), opacity: Double(c.alpha))
            },
            set: { newValue in
                guard var m = mask, let ns = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                m.personKeyColor = RGBAColor(red: Float(ns.redComponent), green: Float(ns.greenComponent),
                                             blue: Float(ns.blueComponent), alpha: Float(ns.alphaComponent))
                mask = m
            }
        )
    }
}

private struct InputBindingsEditor: View {
    let node: Node
    let binding: (Int) -> Binding<PortBinding>
    let layerSources: (SignalType) -> [(id: UUID, name: String)]

    var body: some View {
        if !node.kind.ports.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Inputs").font(.caption).foregroundStyle(.secondary)
                ForEach(Array(node.kind.ports.enumerated()), id: \.offset) { index, port in
                    let value = binding(index)
                    HStack(spacing: 6) {
                        Text(port.name.capitalized)
                            .font(.caption2)
                            .frame(width: 56, alignment: .leading)
                        Menu(label(for: value.wrappedValue, port: port)) {
                            Button("Default") { value.wrappedValue = .none }
                            let sources = SourceID.allCases.filter { $0.signalType == port.type }
                            if !sources.isEmpty {
                                Divider()
                                Section("Sources") {
                                    ForEach(sources, id: \.self) { source in
                                        Button(source.title) { value.wrappedValue = .source(source) }
                                    }
                                }
                            }
                            let layers = layerSources(port.type)
                            if !layers.isEmpty {
                                Divider()
                                Section("Layers") {
                                    ForEach(layers, id: \.id) { source in
                                        Button(source.name) { value.wrappedValue = .node(source.id) }
                                    }
                                }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
        }
    }

    private func label(for binding: PortBinding, port: SketchCamCore.Port) -> String {
        switch binding {
        case .none:
            return "Default"
        case .source(let source):
            return source.signalType == port.type ? source.title : "Invalid source"
        case .node(let id):
            return layerSources(port.type).first { $0.id == id }?.name ?? "Layer"
        }
    }
}

private extension SourceID {
    var title: String {
        switch self {
        case .camera: return "Camera"
        case .landmarks: return "Landmarks"
        case .mouse: return "Mouse"
        case .personMatte: return "Person matte"
        }
    }
}

private extension SketchCamCore.BlendMode {
    var title: String {
        switch self {
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .add: return "Add"
        case .overlay: return "Overlay"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        case .difference: return "Difference"
        case .subtract: return "Subtract"
        case .softLight: return "Soft Light"
        case .hue: return "Hue"
        case .saturation: return "Saturation"
        case .color: return "Color"
        case .luminosity: return "Luminosity"
        }
    }

    var icon: String {
        switch self {
        case .normal: return "circle.lefthalf.filled"
        case .multiply: return "multiply"
        case .screen: return "circle.dashed"
        case .add: return "plus"
        case .overlay: return "square.on.circle"
        case .darken: return "moon"
        case .lighten: return "sun.max"
        case .difference: return "circle.grid.cross"
        case .subtract: return "minus"
        case .softLight: return "sparkles"
        case .hue: return "paintpalette"
        case .saturation: return "drop.degreesign"
        case .color: return "eyedropper"
        case .luminosity: return "lightbulb"
        }
    }
}

private extension InkPaperCompositeMode {
    var title: String {
        switch self {
        case .none: return "None"
        case .normal: return "Normal"
        case .multiply: return "Multiply"
        case .screen: return "Screen"
        case .add: return "Add"
        case .overlay: return "Overlay"
        case .darken: return "Darken"
        case .lighten: return "Lighten"
        case .difference: return "Difference"
        case .subtract: return "Subtract"
        case .softLight: return "Soft Light"
        }
    }
}

/// A per-layer effect chain: an ordered list of collapsible effect panels
/// (Blender-modifier style) plus an Add menu.
private struct EffectChainEditor: View {
    @Binding var effects: [EffectConfig]
    /// The shared Vision-matte quality, shown inside any Person Key effect.
    @Binding var personMatteQuality: SegmentationQuality

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(effects.enumerated()), id: \.element.id) { idx, effect in
                EffectPanel(
                    effect: binding(effect.id),
                    personMatteQuality: $personMatteQuality,
                    canMoveUp: idx > 0,
                    canMoveDown: idx < effects.count - 1,
                    onMoveUp: { if idx > 0 { effects.swapAt(idx, idx - 1) } },
                    onMoveDown: { if idx < effects.count - 1 { effects.swapAt(idx, idx + 1) } },
                    onDelete: { effects.removeAll { $0.id == effect.id } }
                )
            }
            Menu {
                ForEach(EffectKind.allCases, id: \.self) { kind in
                    Button(kind.title) { effects.append(EffectConfig(kind: kind, amount: defaultAmount(kind))) }
                }
            } label: {
                Label("Add effect", systemImage: "plus.circle")
            }
            .menuStyle(.borderlessButton)
            .controlSize(.small)
        }
    }

    private func binding(_ id: UUID) -> Binding<EffectConfig> {
        Binding(
            get: { effects.first { $0.id == id } ?? EffectConfig(kind: .invert) },
            set: { v in if let i = effects.firstIndex(where: { $0.id == id }) { effects[i] = v } }
        )
    }

    private func defaultAmount(_ k: EffectKind) -> Float {
        switch k {
        case .threshold: return 0.5
        case .outline: return 0.3
        case .blur: return 3
        case .opticalFlow: return 1
        case .invert, .mirror, .personKey, .levels: return 0
        }
    }
}

private struct EffectPanel: View {
    @Binding var effect: EffectConfig
    @Binding var personMatteQuality: SegmentationQuality
    @State private var open = true
    let canMoveUp: Bool
    let canMoveDown: Bool
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { open.toggle() } label: {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.borderless)
                Toggle("", isOn: $effect.enabled).labelsHidden().toggleStyle(.checkbox)
                Text(effect.kind.title).font(.caption).bold()
                Spacer()
                Button { onMoveUp() } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.borderless).disabled(!canMoveUp)
                Button { onMoveDown() } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.borderless).disabled(!canMoveDown)
                Button(role: .destructive) { onDelete() } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
            if open { params }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        .opacity(effect.enabled ? 1 : 0.5)
        .help(helpText)
    }

    private var helpText: String {
        switch effect.kind {
        case .threshold: return "Binarises luminance into ink/paper."
        case .outline: return "Sobel edge outline on a transparent background."
        case .blur: return "Box blur."
        case .invert: return "Inverts this layer's colours."
        case .mirror: return "Flips this layer horizontally."
        case .personKey: return "Keeps only the person (Vision matte). Invert to drop the person and keep the background. Higher matte quality is sharper but costs more."
        case .opticalFlow: return "Visualizes frame-to-frame motion. Red/green encode direction; brightness encodes speed."
        case .levels: return "Remaps black and white points, then applies gamma. Useful before or after analytical effects."
        }
    }

    @ViewBuilder private var params: some View {
        if effect.kind.usesAmount {
            HStack {
                Text(amountLabel).font(.caption2).frame(width: 56, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { effect.amount = defaultAmount }
                    .help("Double-click to reset to \(String(format: "%.2f", defaultAmount))")
                Slider(value: $effect.amount, in: amountRange).controlSize(.small)
                Text(String(format: "%.2f", effect.amount)).font(.caption2).frame(width: 32)
            }
        }
        if effect.kind.usesColor {
            ColorPicker("Stroke", selection: colorBinding, supportsOpacity: true).controlSize(.small)
        }
        if effect.kind.usesThresholdOptions {
            Toggle("Ink only (transparent paper)", isOn: $effect.inkOnly).controlSize(.small)
            Toggle("Invert", isOn: $effect.invert).controlSize(.small)
        }
        if effect.kind == .personKey {
            Toggle("Key out person (invert)", isOn: $effect.invert).controlSize(.small)
            Toggle("Silhouette (flat fill)", isOn: $effect.silhouette).controlSize(.small)
            if effect.silhouette {
                ColorPicker("Fill", selection: colorBinding, supportsOpacity: true).controlSize(.small)
            }
            Picker("Matte", selection: $personMatteQuality) {
                ForEach(SegmentationQuality.allCases) { q in Text(q.title).tag(q) }
            }
            .pickerStyle(.segmented).controlSize(.small)
        }
        if effect.kind == .levels {
            levelSlider("Black", value: $effect.levelBlack, range: 0...0.99, defaultValue: 0)
            levelSlider("White", value: $effect.levelWhite, range: 0.01...1, defaultValue: 1)
            levelSlider("Gamma", value: $effect.levelGamma, range: 0.1...3, defaultValue: 1)
        }
    }

    private func levelSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, defaultValue: Float) -> some View {
        HStack {
            Text(title).font(.caption2).frame(width: 56, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
            Slider(value: value, in: range).controlSize(.small)
            Text(String(format: "%.2f", value.wrappedValue)).font(.caption2).frame(width: 32)
        }
    }

    private var amountLabel: String {
        switch effect.kind {
        case .threshold: return "Level"
        case .outline: return "Strength"
        case .blur: return "Radius"
        case .opticalFlow: return "Gain"
        default: return "Amount"
        }
    }
    private var amountRange: ClosedRange<Float> {
        switch effect.kind {
        case .threshold: return 0...1
        case .outline: return 0...2
        case .blur: return 0...20
        case .opticalFlow: return 0...4
        default: return 0...1
        }
    }
    private var defaultAmount: Float {
        switch effect.kind {
        case .threshold: return 0.52
        case .outline: return 0.25
        case .blur, .opticalFlow: return 0.5
        default: return 0.5
        }
    }
    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(.sRGB, red: Double(effect.color.red), green: Double(effect.color.green),
                         blue: Double(effect.color.blue), opacity: Double(effect.color.alpha)) },
            set: { newValue in
                if let ns = NSColor(newValue).usingColorSpace(.sRGB) {
                    effect.color = RGBAColor(red: Float(ns.redComponent), green: Float(ns.greenComponent),
                                             blue: Float(ns.blueComponent), alpha: Float(ns.alphaComponent))
                }
            }
        )
    }
}

private struct PaperNodeEditor: View {
    @Binding var config: PaperConfig

    var body: some View {
        PaperControls(config: $config)
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }
}

private struct AcrylicNodeEditor: View {
    @Binding var config: AcrylicConfig
    @State private var advanced = false
    @State private var activeStroke: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RGBAColorPicker("Color", rgba: $config.color, supportsOpacity: true)
            acrylicSlider("Size", value: $config.width, range: 0.002...0.15, defaultValue: 0.035)
            acrylicSlider("Loading", value: $config.paintLoading, range: 0...1, defaultValue: 0.65)
            acrylicSlider("Body", value: Binding(get: { config.body }, set: { config.applyBody($0) }), range: 0...1, defaultValue: 0.5)
            Picker("Mixing", selection: $config.mixModel) {
                Text("RGB").tag(AcrylicMixModel.rgb)
                Text("Pigment").tag(AcrylicMixModel.pigment)
            }.pickerStyle(.segmented)
            Canvas { context, size in
                for stroke in config.strokes where stroke.points.count > 1 {
                    var path = Path()
                    path.move(to: CGPoint(x: stroke.points[0].x * size.width, y: stroke.points[0].y * size.height))
                    for point in stroke.points.dropFirst() { path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height)) }
                    context.stroke(path, with: .color(Color(.sRGB, red: Double(stroke.color.red), green: Double(stroke.color.green), blue: Double(stroke.color.blue), opacity: Double(stroke.loading * config.pigmentOpacity))),
                                   style: StrokeStyle(lineWidth: CGFloat(stroke.width) * min(size.width, size.height), lineCap: .round, lineJoin: .round))
                }
            }
            .frame(height: 130)
            .background(Color.white.opacity(0.9))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let point = CGPoint(x: min(max(value.location.x / 240, 0), 1), y: min(max(value.location.y / 130, 0), 1))
                if let id = activeStroke, let index = config.strokes.firstIndex(where: { $0.id == id }) {
                    config.strokes[index].points.append(point)
                } else {
                    let stroke = AcrylicStroke(points: [point], color: config.color, width: config.width,
                                               loading: config.paintLoading, body: config.body, mixModel: config.mixModel)
                    activeStroke = stroke.id; config.strokes.append(stroke)
                }
            }.onEnded { _ in activeStroke = nil })
            HStack {
                Button("Clear") { config.strokes.removeAll(); config.clearRevision += 1 }
                Button("Instant Dry") { config.instantDryRevision += 1 }
                Button("Rerender") { config.rebuildRevision += 1 }
            }.buttonStyle(.borderless)
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                acrylicSlider("Opacity", value: $config.pigmentOpacity, range: 0...2, defaultValue: 0.85)
                acrylicSlider("Viscosity", value: $config.viscosity, range: 0...1, defaultValue: 0.45)
                acrylicSlider("Leveling", value: $config.leveling, range: 0...1, defaultValue: 0.5)
                acrylicSlider("Retention", value: $config.brushRetention, range: 0...1, defaultValue: 0.35)
                acrylicSlider("Flow", value: $config.flow, range: 0...1, defaultValue: 0.55)
                acrylicSlider("Dry rate", value: $config.dryRate, range: 0...1, defaultValue: 0.15)
                acrylicSlider("Paper", value: $config.paperInfluence, range: 0...1, defaultValue: 0)
                acrylicSlider("Live surface", value: $config.liveSurfaceInfluence, range: 0...1, defaultValue: 0)
                acrylicSlider("Motion", value: $config.motionForce, range: 0...2, defaultValue: 0)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
    }

    private func acrylicSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, defaultValue: Float) -> some View {
        HStack {
            Text(title).font(.caption2).frame(width: 72, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
            Slider(value: value, in: range).controlSize(.small)
            Text(String(format: "%.2f", value.wrappedValue)).font(.caption2).monospacedDigit().frame(width: 38)
        }
    }
}

private struct FloatSliderRow: View {
    let title: String
    @Binding var value: Float
    let range: ClosedRange<Float>
    let precision: Int
    let defaultValue: Float
    let hint: String
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption2)
                .frame(width: 76, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value = defaultValue }
            Slider(value: $value, in: range)
                .controlSize(.small)
            TextField("", value: $value,
                      format: .number.precision(.fractionLength(precision)))
                .textFieldStyle(.plain)
                .font(.caption2)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 42)
                .focused($editing)
                .onSubmit { editing = false }
                .onExitCommand { editing = false }
        }
        .contentShape(Rectangle())
        .help("\(hint) Double-click the label to restore the default; type an exact value in the number field and press Return.")
    }
}

private struct PaperControls: View {
    @Binding var config: PaperConfig
    var showsMaterialMap = true
    @State private var physicalExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            paperSlider("Material", value: optional(\.response, 1), range: 0...1, defaultValue: 1,
                        hint: "Master strength of the hidden absorbency, drag, and resistance maps. It affects ink only when Paper influence is above 0.")
            paperSlider("Variation", value: optional(\.variation, 1), range: 0...2, defaultValue: 1,
                        hint: "Contrast of hidden material differences around neutral. 0 is uniform; 1 is natural; values above 1 exaggerate waxy and absorbent regions.")
            RGBAColorPicker("Tint", rgba: $config.tint, supportsOpacity: true)
                .help("Visual only: color and opacity of the rendered paper. It does not tint or strengthen the physical material map.")
            paperSlider("Contrast", value: optional(\.contrast, 1), range: 0...4, defaultValue: 1,
                        hint: "Visual only: contrast of the rendered substrate. It does not strengthen the physical response.")
            paperSlider("Saturation", value: optional(\.saturation, 1), range: 0...2, defaultValue: 1,
                        hint: "Visual only: color saturation of the rendered paper.")
            paperSlider("Vignette", value: optional(\.vignetteStrength, 0.16), range: 0...0.5, defaultValue: 0.16,
                        hint: "Visual only: darkens the paper toward the canvas edges.")

            paperHeading("Fiber")
            paperSlider("Visual strength", value: optional(\.fiberStrength, 0.05), range: 0...0.15, defaultValue: 0.05,
                        hint: "Darkness of the visible fiber pattern. The physical map currently uses fiber scale and angle, but not this visual strength.")
            paperSlider("X scale", value: optional(\.fiberScaleX, 0.055), range: 0.005...0.5, defaultValue: 0.055, precision: 3,
                        hint: "Fiber variation across X. Higher values make finer, more frequent variation. This also changes the hidden material map.")
            paperSlider("Y scale", value: optional(\.fiberScaleY, 0.055), range: 0.005...0.5, defaultValue: 0.055, precision: 3,
                        hint: "Fiber variation across Y. Unequal X and Y scales stretch the pattern into bands. This also changes the hidden material map.")
            paperSlider("Angle", value: optional(\.fiberOrientation, 0), range: -Float.pi...Float.pi, defaultValue: 0,
                        hint: "Rotation in radians of both the visible fibers and their hidden material pattern. Rotation alone does not make fluid flow along the fibers.")

            paperHeading("Tooth")
            paperSlider("Visual strength", value: optional(\.toothStrength, 0.022), range: 0...0.1, defaultValue: 0.022, precision: 3,
                        hint: "Amount of visible mid-scale paper tooth. The physical map currently uses tooth scale, but not this visual strength.")
            paperSlider("X scale", value: optional(\.toothScaleX, 0.42), range: 0.01...1, defaultValue: 0.42,
                        hint: "Tooth variation across X. Higher values make finer variation and also change the hidden material map.")
            paperSlider("Y scale", value: optional(\.toothScaleY, 0.42), range: 0.01...1, defaultValue: 0.42,
                        hint: "Tooth variation across Y. Unequal scales stretch the pattern and also change the hidden material map.")

            paperHeading("Grain")
            paperSlider("Visual strength", value: $config.grain, range: 0...1, defaultValue: 0.45,
                        hint: "Amount of visible fine grain. The physical map currently uses grain scale and seed, but not this visual strength.")
            paperSlider("X scale", value: optional(\.grainScaleX, 0.12), range: 0.005...0.5, defaultValue: 0.12, precision: 3,
                        hint: "Fine-grain variation across X. Higher values make finer variation and also change the hidden material map.")
            paperSlider("Y scale", value: optional(\.grainScaleY, 0.12), range: 0.005...0.5, defaultValue: 0.12, precision: 3,
                        hint: "Fine-grain variation across Y. Unequal scales stretch the pattern and also change the hidden material map.")
            HStack {
                Stepper("Seed \(config.seed ?? 0)", value: seedBinding, in: 0...99_999)
                    .font(.caption2)
                Spacer()
                Button("Shuffle") { config.seed = Int.random(in: 0..<100_000) }
                    .buttonStyle(.borderless)
                    .font(.caption2)
            }

            if showsMaterialMap {
                DisclosureGroup("Material map", isExpanded: $physicalExpanded) {
                    PaperMaterialMapControls(config: $config)
                }
            }
        }
    }

    private func paperHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2).fontWeight(.semibold).foregroundStyle(.secondary)
            .padding(.top, 3)
    }

    private func paperSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, defaultValue: Float, precision: Int = 2, hint: String) -> some View {
        FloatSliderRow(title: title, value: value, range: range, precision: precision,
                       defaultValue: defaultValue, hint: hint)
    }

    private func optional(_ keyPath: WritableKeyPath<PaperConfig, Float?>, _ fallback: Float) -> Binding<Float> {
        Binding(
            get: { config[keyPath: keyPath] ?? fallback },
            set: { config[keyPath: keyPath] = $0 }
        )
    }

    private var seedBinding: Binding<Int> {
        Binding(get: { config.seed ?? 0 }, set: { config.seed = $0 })
    }
}

private struct PaperMaterialMapControls: View {
    @Binding var config: PaperConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            paperSlider("Absorb", value: optional(\.absorbency, 1), range: 0...1, defaultValue: 1,
                        hint: "Strength of absorbent low-noise regions. These alter wetness and drying locally; they do not directly pull pigment into dark visible grooves.")
            paperSlider("Flow drag", value: optional(\.drag, 1), range: 0...1, defaultValue: 1,
                        hint: "Strength of high-noise regions that brake velocity and pigment advection. Drag is a scalar brake; it does not steer flow along fibers.")
            paperSlider("Ink resist", value: optional(\.resist, 1), range: 0...1, defaultValue: 1,
                        hint: "How strongly selected regions reject freshly deposited pigment, like wax. It does not erase or repel pigment already on the canvas.")
            paperSlider("Resist cutoff", value: optional(\.resistThreshold, 0.5), range: 0...1, defaultValue: 0.5,
                        hint: "Selects which high-noise regions resist fresh marks. Higher values leave fewer resistant regions.")
            paperSlider("Edge softness", value: optional(\.resistSoftness, 0.1), range: 0...1, defaultValue: 0.1,
                        hint: "Width of the resistance transition. Low gives a hard wax-mask edge; high gives a gradual transition.")
        }
    }

    private func paperSlider(_ title: String, value: Binding<Float>, range: ClosedRange<Float>, defaultValue: Float, precision: Int = 2, hint: String) -> some View {
        FloatSliderRow(title: title, value: value, range: range, precision: precision,
                       defaultValue: defaultValue, hint: hint)
    }

    private func optional(_ keyPath: WritableKeyPath<PaperConfig, Float?>, _ fallback: Float) -> Binding<Float> {
        Binding(
            get: { config[keyPath: keyPath] ?? fallback },
            set: { config[keyPath: keyPath] = $0 }
        )
    }
}

private struct WorkspaceFrameStackEditor: View {
    @ObservedObject var model: SketchCamViewModel
    @State private var expanded: Set<UUID> = []
    @State private var draggedFrameID: UUID?
    @State private var editingNameID: UUID?
    @State private var editingNameText = ""
    @FocusState private var nameFocused: Bool

    private static let availableBlendModes: [SketchCamCore.BlendMode] = [
        .normal, .multiply, .screen, .add, .overlay, .darken, .lighten, .difference, .subtract, .softLight
    ]

    private var workspace: CollageWorkspace? { model.settings.workspace }
    private var displayFrames: [WorkspaceFrame] { (workspace?.frames ?? []).reversed() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionHeader("Frame stack")
                addFrameMenu
                    .padding(.top, 6)
                Spacer()
            }
            ForEach(displayFrames) { frame in
                let isSelected = workspace?.activeFrameID == frame.id
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Button { toggleExpanded(frame.id) } label: {
                            Image(systemName: expanded.contains(frame.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: 16)
                        }
                        .buttonStyle(.borderless)
                        .help(expanded.contains(frame.id) ? "Hide frame details" : "Show frame details")

                        Button { toggleVisible(frame.id) } label: {
                            Image(systemName: frame.visible ? "eye" : "eye.slash")
                                .frame(width: 20)
                        }
                        .buttonStyle(.borderless)
                        .help(frame.visible ? "Hide frame on artboard" : "Show frame on artboard")

                        Button {
                            let current = includeBinding(frame.id).wrappedValue
                            includeBinding(frame.id).wrappedValue = !current
                        } label: {
                            Image(systemName: includeBinding(frame.id).wrappedValue ? "rectangle.inset.filled" : "rectangle.dashed")
                                .frame(width: 20)
                        }
                        .buttonStyle(.borderless)
                        .help(includeBinding(frame.id).wrappedValue ? "Exclude from output viewport render" : "Include in output viewport render")

                        if editingNameID == frame.id {
                            TextField("", text: $editingNameText)
                                .textFieldStyle(.plain)
                                .focused($nameFocused)
                                .lineLimit(1)
                                .frame(width: 82, alignment: .leading)
                                .onSubmit { commitNameEdit(frame.id) }
                                .onExitCommand { cancelNameEdit() }
                                .help("Rename frame")
                        } else {
                            Text(frame.name)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: 82, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    if NSEvent.modifierFlags.contains(.shift) {
                                        beginNameEdit(frame)
                                    } else {
                                        select(frame.id)
                                    }
                                }
                                .help("Frame name. Shift-click to rename.")
                        }

                        Menu {
                            ForEach(WorkspaceFrameRole.allCases) { role in
                                Button {
                                    setRole(frame.id, role)
                                } label: {
                                    Label(role.rawValue.capitalized, systemImage: icon(for: role))
                                }
                            }
                        } label: {
                            Image(systemName: icon(for: frame.role))
                                .frame(width: 20)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 22)
                        .help("Frame role: \(frame.role.rawValue.capitalized)")

                        Menu {
                            ForEach(Self.availableBlendModes, id: \.self) { blend in
                                Button {
                                    setBlend(frame.id, blend)
                                } label: {
                                    Label(blend.title, systemImage: blend.icon)
                                }
                            }
                        } label: {
                            Image(systemName: frame.blend.icon)
                                .frame(width: 20)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 22)
                        .help("Blend mode: \(frame.blend.title)")

                        Spacer(minLength: 0)

                        Slider(value: opacity(frame.id), in: 0...1)
                            .controlSize(.small)
                            .frame(width: 50)
                            .help("Frame opacity")

                        Button(role: .destructive) { delete(frame.id) } label: {
                            Image(systemName: "trash")
                                .frame(width: 20)
                        }
                        .buttonStyle(.borderless)
                        .help("Delete frame")
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture { select(frame.id) }
                    .opacity(draggedFrameID == frame.id ? 0.55 : 1)
                    .onDrag {
                        draggedFrameID = frame.id
                        return NSItemProvider(object: frame.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: LayerDropDelegate(
                            targetID: frame.id,
                            draggedID: $draggedFrameID,
                            move: reorderForDisplay
                        )
                    )

                    if expanded.contains(frame.id) {
                        frameDetails(frame)
                            .padding(.leading, 20)
                            .padding(.top, 2)
                            .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
        .onAppear { model.reconcileWorkspaceWithGraph() }
        .onChange(of: featureKey) { _, _ in model.reconcileWorkspaceWithGraph() }
    }

    private var addFrameMenu: some View {
        Menu {
            Section("Materials") {
                Button("Camera") { addGraphFrame(kind: .video, name: "Camera", role: .layer) }
                Button("Movie") { addGraphFrame(kind: .movie, name: "Movie", role: .layer) }
                Button("Solid color") {
                    addGraphFrame(kind: .solid(SolidConfig(color: RGBAColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1))), name: "Solid", role: .layer)
                }
                Button("Paper") { addGraphFrame(kind: .paper(PaperConfig()), name: "Paper", role: .layer) }
                Button("Acrylic") { addGraphFrame(kind: .acrylic(AcrylicConfig()), name: "Acrylic", role: .layer) }
                Button("Ink") { addGraphFrame(kind: .ink, name: "Ink", role: .layer) }
                Button("Image...") { openImageFrame() }
            }
            Section("Streams") {
                Button("Drawing") { enableStream(.drawing) }
                Button("Web") { enableStream(.web) }
            }
        } label: {
            Label("Add frame", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder private func frameDetails(_ frame: WorkspaceFrame) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                field("X", value: transformValue(frame.id, get: { $0.tx }, set: { $0.tx = $1 }))
                field("Y", value: transformValue(frame.id, get: { $0.ty }, set: { $0.ty = $1 }))
                field("W", value: boundsValue(frame.id, get: { $0.width }, set: { $0.size.width = max(1, $1) }))
                field("H", value: boundsValue(frame.id, get: { $0.height }, set: { $0.size.height = max(1, $1) }))
            }
            HStack {
                field("Rot", value: rotation(frame.id))
                Picker("Fit", selection: contentFitBinding(frame.id)) {
                    ForEach(WorkspaceContentFit.allCases) { fit in
                        Text(fit.rawValue.capitalized).tag(fit)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
            }
            HStack(spacing: 6) {
                Button {
                    fitFrame(frame.id, to: .viewport)
                } label: {
                    Label("Viewport", systemImage: "viewfinder")
                }
                .help("Fit frame to the live output viewport")

                Button {
                    fitFrame(frame.id, to: .artboard)
                } label: {
                    Label("Artboard", systemImage: "rectangle.expand.vertical")
                }
                .help("Fit frame to a larger artboard backdrop around the live viewport")
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderless)
            .controlSize(.small)
            HStack {
                field("Crop X", value: cropValue(frame.id, keyPath: \.origin.x))
                field("Y", value: cropValue(frame.id, keyPath: \.origin.y))
                field("W", value: cropValue(frame.id, keyPath: \.size.width))
                field("H", value: cropValue(frame.id, keyPath: \.size.height))
            }
            MaskEditor(mask: frameMaskBinding(frame.id),
                       personMatteQuality: $model.settings.segmentation.quality,
                       sources: maskSources(excluding: frame.id))
            if let layerID = linkedLayerID(frame) {
                EffectChainEditor(effects: effectsBinding(layerID),
                                  personMatteQuality: $model.settings.segmentation.quality)
            }
        }
    }

    private func field(_ label: String, value: Binding<Double>) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField(label, value: value, format: .number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder)
                .frame(width: 54)
        }
    }

    private var featureKey: String {
        let l = model.settings.landmarks
        return [l.enabled, l.inkEnabled, l.showDots, l.showStick,
                l.yarnEnabled, l.wrapEnabled, l.lineWalkEnabled, model.settings.web.enabled]
            .map { $0 ? "1" : "0" }.joined()
    }

    private func icon(for role: WorkspaceFrameRole) -> String {
        switch role {
        case .output: return "record.circle"
        case .layer: return "square.3.layers.3d"
        case .reference: return "photo"
        case .preview: return "rectangle.inset.filled"
        }
    }

    private func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    private func select(_ id: UUID) {
        model.ensureWorkspace()
        model.settings.workspace?.activeFrameID = id
        model.settings.workspace?.selectedFrameIDs = [id]
    }

    private func beginNameEdit(_ frame: WorkspaceFrame) {
        select(frame.id)
        editingNameID = frame.id
        editingNameText = frame.name
        DispatchQueue.main.async { nameFocused = true }
    }

    private func commitNameEdit(_ id: UUID) {
        let trimmed = editingNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            mutateFrame(id) { $0.name = trimmed }
        }
        editingNameID = nil
        editingNameText = ""
        nameFocused = false
    }

    private func cancelNameEdit() {
        editingNameID = nil
        editingNameText = ""
        nameFocused = false
    }

    private func mutateFrame(_ id: UUID, _ body: @escaping (inout WorkspaceFrame) -> Void) {
        model.mutateWorkspace { workspace in
            guard let index = workspace.frames.firstIndex(where: { $0.id == id }) else { return }
            body(&workspace.frames[index])
            workspace.activeFrameID = id
            workspace.selectedFrameIDs = [id]
        }
    }

    private enum FrameFitTarget {
        case viewport
        case artboard
    }

    private func fitFrame(_ id: UUID, to target: FrameFitTarget) {
        model.mutateWorkspace { workspace in
            guard let index = workspace.frames.firstIndex(where: { $0.id == id }) else { return }
            let viewport = workspace.outputViewport.frame
            let bounds: CGRect
            switch target {
            case .viewport:
                bounds = viewport
            case .artboard:
                bounds = viewport.insetBy(dx: -viewport.width * 0.5, dy: -viewport.height * 0.5)
            }
            workspace.frames[index].localBounds = CGRect(origin: .zero, size: bounds.size)
            workspace.frames[index].transform = .translation(x: bounds.minX, y: bounds.minY)
            workspace.frames[index].cropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            workspace.activeFrameID = id
            workspace.selectedFrameIDs = [id]
            workspace.viewCenter = CGPoint(x: bounds.midX, y: bounds.midY)
            if target == .artboard {
                workspace.zoom = min(workspace.zoom, 0.7)
            }
        }
    }

    private func linkedLayerID(_ frame: WorkspaceFrame) -> UUID? {
        guard case .layer(let id) = frame.material else { return nil }
        return id
    }

    private func toggleVisible(_ id: UUID) {
        mutateFrame(id) { $0.visible.toggle() }
    }

    private func includeBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { model.settings.workspace?.frame(id: id)?.includeInOutput ?? true },
            set: { value in mutateFrame(id) { $0.includeInOutput = value } }
        )
    }

    private func opacity(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.workspace?.frame(id: id)?.opacity ?? 1) },
            set: { value in mutateFrame(id) { $0.opacity = Float(max(0, min(1, value))) } }
        )
    }

    private func setBlend(_ id: UUID, _ blend: SketchCamCore.BlendMode) {
        mutateFrame(id) { $0.blend = blend }
    }

    private func setRole(_ id: UUID, _ role: WorkspaceFrameRole) {
        mutateFrame(id) {
            $0.role = role
            $0.includeInOutput = role == .layer || role == .output
        }
    }

    private func transformValue(_ id: UUID, get: @escaping (WorkspaceAffineTransform) -> Double, set: @escaping (inout WorkspaceAffineTransform, Double) -> Void) -> Binding<Double> {
        Binding(
            get: { model.settings.workspace?.frame(id: id).map { get($0.transform) } ?? 0 },
            set: { value in mutateFrame(id) { set(&$0.transform, value) } }
        )
    }

    private func boundsValue(_ id: UUID, get: @escaping (CGRect) -> CGFloat, set: @escaping (inout CGRect, CGFloat) -> Void) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.workspace?.frame(id: id).map { get($0.localBounds) } ?? 0) },
            set: { value in mutateFrame(id) { set(&$0.localBounds, CGFloat(value)) } }
        )
    }

    private func cropValue(_ id: UUID, keyPath: WritableKeyPath<CGRect, CGFloat>) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.workspace?.frame(id: id)?.cropRect[keyPath: keyPath] ?? 0) },
            set: { value in
                mutateFrame(id) {
                    $0.cropRect[keyPath: keyPath] = max(0, min(1, CGFloat(value)))
                }
            }
        )
    }

    private func rotation(_ id: UUID) -> Binding<Double> {
        Binding(
            get: {
                guard let t = model.settings.workspace?.frame(id: id)?.transform else { return 0 }
                return atan2(t.b, t.a) * 180 / .pi
            },
            set: { degrees in
                mutateFrame(id) { frame in
                    let t = frame.transform
                    let sx = max(0.0001, hypot(t.a, t.b))
                    let sy = max(0.0001, hypot(t.c, t.d))
                    let radians = degrees * .pi / 180
                    frame.transform.a = cos(radians) * sx
                    frame.transform.b = sin(radians) * sx
                    frame.transform.c = -sin(radians) * sy
                    frame.transform.d = cos(radians) * sy
                }
            }
        )
    }

    private func contentFitBinding(_ id: UUID) -> Binding<WorkspaceContentFit> {
        Binding(
            get: { model.settings.workspace?.frame(id: id)?.contentFit ?? .stretch },
            set: { fit in mutateFrame(id) { $0.contentFit = fit } }
        )
    }

    private func frameMaskBinding(_ id: UUID) -> Binding<MaskBinding?> {
        Binding(
            get: { model.settings.workspace?.frame(id: id)?.mask },
            set: { mask in mutateFrame(id) { $0.mask = mask } }
        )
    }

    private func effectsBinding(_ layerID: UUID) -> Binding<[EffectConfig]> {
        Binding(
            get: { model.settings.layerGraph?.layers.first { $0.id == layerID }?.effects ?? [] },
            set: { effects in
                guard var graph = model.settings.layerGraph,
                      let index = graph.layers.firstIndex(where: { $0.id == layerID }) else { return }
                graph.layers[index].effects = effects
                model.settings.layerGraph = graph
            }
        )
    }

    private func maskSources(excluding frameID: UUID) -> [(id: UUID, name: String)] {
        guard let workspace = model.settings.workspace,
              let graph = model.settings.layerGraph else { return [] }
        return workspace.frames.compactMap { frame in
            guard frame.id != frameID,
                  case .layer(let layerID) = frame.material,
                  let layer = graph.layers.first(where: { $0.id == layerID }),
                  let node = graph.node(layer.node) else { return nil }
            return (id: node.id, name: frame.name)
        }
    }

    private func addGraphFrame(kind: NodeKind, name: String, role: WorkspaceFrameRole) {
        model.ensureWorkspace()
        let frameName = nextGraphFrameName(base: name, family: kind.family)
        let node = Node(
            name: frameName,
            kind: kind,
            inkConfig: kind.family == "ink" ? InkFrameConfig(landmarks: model.settings.landmarks) : nil,
            managed: false
        )
        let layer = Layer(node: node.id)
        var graph = model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)
        graph.nodes.append(node)
        graph.layers.append(layer)
        model.settings.layerGraph = graph
        model.settings.useLayerGraph = true
        if kind.family == "ink" {
            model.settings.landmarks.inkEnabled = true
        }
        model.mutateWorkspace { workspace in
            let outputRect = CGRect(origin: .zero, size: model.outputFormat.size)
            let frame = WorkspaceFrame(
                id: layer.id,
                name: frameName,
                role: role,
                material: .layer(layer.id),
                localBounds: outputRect,
                visible: true,
                includeInOutput: role == .layer || role == .output,
                blend: layer.blend
            )
            workspace.frames.append(frame)
            workspace.activeFrameID = frame.id
            workspace.selectedFrameIDs = [frame.id]
        }
    }

    private func nextGraphFrameName(base: String, family: String) -> String {
        let graph = model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)
        let existing = Set(graph.nodes.compactMap { node -> String? in
            node.kind.family == family ? node.name : nil
        })
        var index = 1
        while existing.contains("\(base) \(index)") || existing.contains("\(base)\(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func openImageFrame() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            addGraphFrame(kind: .image(WorkspaceImageConfig(urlString: url.path)), name: url.deletingPathExtension().lastPathComponent, role: .reference)
        }
    }

    private enum Stream { case drawing, ink, web }

    private func enableStream(_ stream: Stream) {
        switch stream {
        case .drawing:
            model.settings.landmarks.enabled = true
            if !(model.settings.landmarks.showDots || model.settings.landmarks.showStick || model.settings.landmarks.yarnEnabled || model.settings.landmarks.wrapEnabled || model.settings.landmarks.lineWalkEnabled) {
                model.settings.landmarks.showStick = true
            }
        case .ink:
            model.settings.landmarks.inkEnabled = true
        case .web:
            model.settings.web.enabled = true
        }
        model.reconcileWorkspaceWithGraph()
    }

    private func delete(_ id: UUID) {
        guard let frame = model.settings.workspace?.frame(id: id) else { return }
        if case .layer(let layerID) = frame.material,
           var graph = model.settings.layerGraph,
           let layer = graph.layers.first(where: { $0.id == layerID }) {
            graph.layers.removeAll { $0.id == layerID }
            graph.nodes.removeAll { $0.id == layer.node }
            model.settings.layerGraph = graph
        }
        model.mutateWorkspace { workspace in
            workspace.frames.removeAll { $0.id == id }
            if workspace.activeFrameID == id {
                workspace.activeFrameID = workspace.frames.first?.id
                workspace.selectedFrameIDs = workspace.activeFrameID.map { [$0] } ?? []
            }
        }
    }

    private func reorderForDisplay(_ draggedID: UUID, _ targetID: UUID) {
        guard draggedID != targetID else { return }
        model.mutateWorkspace { workspace in
            var displayOrder = Array(workspace.frames.reversed())
            guard let from = displayOrder.firstIndex(where: { $0.id == draggedID }),
                  let to = displayOrder.firstIndex(where: { $0.id == targetID }) else { return }
            let moved = displayOrder.remove(at: from)
            let insertion = from < to ? to : max(0, to)
            displayOrder.insert(moved, at: min(insertion, displayOrder.count))
            workspace.frames = Array(displayOrder.reversed())
        }
    }
}

private struct LayerStackEditor: View {
    @ObservedObject var model: SketchCamViewModel
    @State private var expanded: Set<UUID> = []
    @State private var editingLayer: UUID?
    @State private var editText: String = ""
    @State private var draggedLayerID: UUID?
    @State private var selectedLayerID: UUID?
    @FocusState private var nameFieldFocused: Bool
    private static let availableBlendModes: [SketchCamCore.BlendMode] = [
        .normal, .multiply, .screen, .add, .overlay, .darken, .lighten, .difference, .subtract, .softLight
    ]
    private static let effectControlWidth: CGFloat = 16
    private static let opacitySliderWidth: CGFloat = 58
    private static let layerIconWidth: CGFloat = 20

    /// Layers top→bottom for display (the graph stores them bottom→top).
    private var displayLayers: [Layer] { (model.settings.layerGraph?.layers ?? []).reversed() }

    private func toggleExpanded(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    /// A binding to a layer's mask by layer id.
    private func maskBinding(_ id: UUID) -> Binding<MaskBinding?> {
        Binding(
            get: { model.settings.layerGraph?.layers.first { $0.id == id }?.mask },
            set: { newValue in
                mutate { g in
                    if let i = g.layers.firstIndex(where: { $0.id == id }) { g.layers[i].mask = newValue }
                }
            }
        )
    }

    /// Other layers usable as a matte source for the given layer (node id + name).
    private func maskSources(excluding id: UUID) -> [(id: UUID, name: String)] {
        guard let g = model.settings.layerGraph else { return [] }
        return g.layers.compactMap { layer in
            guard layer.id != id, let node = g.node(layer.node) else { return nil }
            return (id: node.id, name: node.name)
        }
    }

    /// A binding to a layer's effect chain by layer id.
    private func effectsBinding(_ id: UUID) -> Binding<[EffectConfig]> {
        Binding(
            get: { model.settings.layerGraph?.layers.first { $0.id == id }?.effects ?? [] },
            set: { newValue in
                mutate { g in
                    if let i = g.layers.firstIndex(where: { $0.id == id }) { g.layers[i].effects = newValue }
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionHeader("Layer stack")
                addLayerMenu
                    .padding(.top, 6)
                Spacer()
            }
            ForEach(displayLayers, id: \.id) { layer in
                let isSelected = selectedLayerID == layer.id || editingLayer == layer.id
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Button { toggleExpanded(layer.id) } label: {
                            Image(systemName: expanded.contains(layer.id) ? "chevron.down" : "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .frame(width: Self.effectControlWidth, alignment: .center)
                        }
                        .buttonStyle(.borderless)
                        .help("Effect chain for this layer")
                        Button { toggleVisible(layer.id) } label: {
                            Image(systemName: layer.visible ? "eye" : "eye.slash")
                                .frame(width: Self.layerIconWidth)
                        }
                        .buttonStyle(.borderless)
                        .help(layer.visible ? "Hide layer" : "Show layer")
                        if let color = solidColor(layer) {
                            ColorPicker("", selection: color, supportsOpacity: false).labelsHidden()
                        }
                        if editingLayer == layer.id {
                            TextField("", text: $editText)
                                .textFieldStyle(.roundedBorder).frame(width: 68)
                                .focused($nameFieldFocused)
                                .onSubmit { commitRename(layer.id) }
                        } else {
                            Text(displayName(layer))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(width: 56, alignment: .leading)
                                .help("Double-click to rename. The name lets other streams reference this layer as a source.")
                                .onTapGesture {
                                    selectedLayerID = layer.id
                                }
                                .onTapGesture(count: 2) {
                                    selectedLayerID = layer.id
                                    editText = displayName(layer)
                                    editingLayer = layer.id
                                    DispatchQueue.main.async { nameFieldFocused = true }
                                }
                        }
                        Slider(value: opacity(layer.id), in: 0...1).controlSize(.small)
                            .frame(width: Self.opacitySliderWidth)
                            .help("Layer opacity")
                        Menu {
                            ForEach(Self.availableBlendModes, id: \.self) { blend in
                                Button {
                                    setBlend(layer.id, blend)
                                } label: {
                                    Label(blend.title, systemImage: blend.icon)
                                }
                            }
                        } label: {
                            Image(systemName: layer.blend.icon)
                                .frame(width: 22)
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 24)
                        .help("Layer blend mode: \(layer.blend.title)")
                        Spacer(minLength: 0)
                        Button(role: .destructive) { delete(layer.id) } label: {
                            Image(systemName: "trash")
                                .frame(width: 22)
                        }
                            .buttonStyle(.borderless).help("Delete layer")
                    }
                    .contentShape(Rectangle())
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onTapGesture {
                        selectedLayerID = layer.id
                    }
                    .opacity(draggedLayerID == layer.id ? 0.55 : 1)
                    .onDrag {
                        draggedLayerID = layer.id
                        return NSItemProvider(object: layer.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [UTType.plainText],
                        delegate: LayerDropDelegate(
                            targetID: layer.id,
                            draggedID: $draggedLayerID,
                            move: reorderLayerForDisplay
                        )
                    )
                    if expanded.contains(layer.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            if let node = node(for: layer) {
                                InputBindingsEditor(
                                    node: node,
                                    binding: { inputBinding(node.id, index: $0) },
                                    layerSources: { inputSources(excluding: node.id, type: $0) }
                                )
                                if case .paper = node.kind {
                                    PaperNodeEditor(config: paperConfigBinding(node.id))
                                }
                                if case .acrylic = node.kind {
                                    AcrylicNodeEditor(config: acrylicConfigBinding(node.id))
                                }
                            }
                            MaskEditor(mask: maskBinding(layer.id),
                                       personMatteQuality: $model.settings.segmentation.quality,
                                       sources: maskSources(excluding: layer.id))
                            EffectChainEditor(effects: effectsBinding(layer.id),
                                              personMatteQuality: $model.settings.segmentation.quality)
                        }
                        .padding(.leading, 20)
                        .padding(.top, 2)
                        .background(isSelected ? Color.accentColor.opacity(0.06) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }
        }
        .onAppear(perform: normalize)
        // Re-sync the stack when any layer-affecting feature toggles (so enabling
        // Ink/Web/Marks/Drawing or changing placement updates the list live).
        .onChange(of: featureKey) { _, _ in normalize() }
    }

    private var addLayerMenu: some View {
        Menu {
            Section("Sources") {
                Button("Camera") { addNode(.video, name: "Camera") }
                Button("Movie") { addNode(.movie, name: "Movie") }
                Button("Solid color") { addSolid() }
                Button("Paper") { addPaper() }
                Button("Acrylic") { addAcrylic() }
                Button("Ink") { addInkLayer() }
            }
            Section("Streams") {
                Button("Drawing") { addStream(.drawing) }
                    .disabled(streamPresent(.drawing))
                Button("Web") { addStream(.web) }
                    .disabled(streamPresent(.web))
            }
        } label: {
            Label("Add layer", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Add a layer. Solid and Paper support multiple independent instances; stream layers are shared sources.")
    }

    /// A signature of the flags that determine which layers exist.
    private var featureKey: String {
        let l = model.settings.landmarks
        return [l.enabled, l.inkEnabled, l.showDots, l.showStick,
                l.yarnEnabled, l.wrapEnabled, l.lineWalkEnabled,
                model.settings.web.enabled, model.settings.backgroundMode != .live]
            .map { $0 ? "1" : "0" }.joined()
            + l.inkPlacement.rawValue + model.settings.web.placement.rawValue
    }

    /// Adopt the graph as the source of truth and reconcile it with current flags.
    private func normalize() {
        let base = model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)
        model.settings.layerGraph = base.reconciled(with: model.settings)
        model.settings.useLayerGraph = true
    }

    /// The layer's user-facing name (the node's name; renamable, defaults to the
    /// stream kind). Other streams can reference a layer by this name as a source.
    private func displayName(_ layer: Layer) -> String {
        model.settings.layerGraph?.node(layer.node)?.name ?? "Layer"
    }

    private func node(for layer: Layer) -> Node? {
        model.settings.layerGraph?.node(layer.node)
    }

    private func inputBinding(_ nodeID: UUID, index: Int) -> Binding<PortBinding> {
        Binding(
            get: {
                guard let node = model.settings.layerGraph?.node(nodeID),
                      node.inputs.indices.contains(index) else { return .none }
                return node.inputs[index]
            },
            set: { newValue in
                mutateValidated { g in
                    guard let nodeIndex = g.nodes.firstIndex(where: { $0.id == nodeID }),
                          g.nodes[nodeIndex].inputs.indices.contains(index) else { return }
                    g.nodes[nodeIndex].inputs[index] = newValue
                }
            }
        )
    }

    private func inputSources(excluding nodeID: UUID, type: SignalType) -> [(id: UUID, name: String)] {
        guard let g = model.settings.layerGraph else { return [] }
        return g.layers.compactMap { layer in
            guard layer.node != nodeID, let node = g.node(layer.node), node.kind.output == type else { return nil }
            return (id: node.id, name: node.name)
        }
    }

    private func paperConfigBinding(_ nodeID: UUID) -> Binding<PaperConfig> {
        Binding(
            get: {
                guard case .paper(let config)? = model.settings.layerGraph?.node(nodeID)?.kind else {
                    return PaperConfig()
                }
                return config
            },
            set: { newValue in
                mutate { g in
                    guard let i = g.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
                    g.nodes[i].kind = .paper(newValue)
                }
            }
        )
    }

    private func acrylicConfigBinding(_ nodeID: UUID) -> Binding<AcrylicConfig> {
        Binding(
            get: {
                guard let node = model.settings.layerGraph?.node(nodeID), case .acrylic(let config) = node.kind else { return AcrylicConfig() }
                return config
            },
            set: { value in
                mutate { graph in
                    guard let index = graph.nodes.firstIndex(where: { $0.id == nodeID }) else { return }
                    graph.nodes[index].kind = .acrylic(value)
                }
            }
        )
    }

    private func commitRename(_ id: UUID) {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        editingLayer = nil
        guard !trimmed.isEmpty else { return }
        mutate { g in
            if let layer = g.layers.first(where: { $0.id == id }),
               let i = g.nodes.firstIndex(where: { $0.id == layer.node }) {
                g.nodes[i].name = trimmed
            }
        }
    }

    private func isUserCreated(_ layer: Layer) -> Bool {
        model.settings.layerGraph?.node(layer.node)?.managed == false
    }

    /// A colour binding for a user-created solid layer (nil for other kinds).
    private func solidColor(_ layer: Layer) -> Binding<Color>? {
        guard let node = model.settings.layerGraph?.node(layer.node),
              !node.managed, case .solid = node.kind else { return nil }
        return Binding(
            get: {
                guard case .solid(let cfg) = model.settings.layerGraph?.node(layer.node)?.kind else { return .gray }
                return Color(.sRGB, red: Double(cfg.color.red), green: Double(cfg.color.green), blue: Double(cfg.color.blue), opacity: 1)
            },
            set: { newValue in
                guard let ns = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                mutate { g in
                    guard let i = g.nodes.firstIndex(where: { $0.id == layer.node }) else { return }
                    g.nodes[i].kind = .solid(SolidConfig(color: RGBAColor(
                        red: Float(ns.redComponent), green: Float(ns.greenComponent),
                        blue: Float(ns.blueComponent), alpha: 1)))
                }
            }
        )
    }

    /// Shared content streams that can be surfaced as a layer (single instance
    /// each, for now — driven by their feature flag; reconcile inserts the layer).
    private enum Stream { case drawing, ink, web }

    private func streamPresent(_ s: Stream) -> Bool {
        let kinds = (model.settings.layerGraph?.layers ?? []).compactMap {
            model.settings.layerGraph?.node($0.node)?.kind
        }
        switch s {
        case .drawing: return kinds.contains { $0.family == "overlay" }
        case .ink: return kinds.contains { $0.family == "ink" }
        case .web: return kinds.contains { $0.family == "web" }
        }
    }

    /// Enable the source behind a stream so it produces pixels, then reconcile
    /// the graph so its (managed) layer appears in the stack.
    private func addStream(_ s: Stream) {
        switch s {
        case .drawing:
            model.settings.landmarks.enabled = true
            let l = model.settings.landmarks
            if !(l.showDots || l.showStick || l.yarnEnabled || l.wrapEnabled || l.lineWalkEnabled) {
                model.settings.landmarks.showStick = true
            }
        case .ink:
            model.settings.landmarks.inkEnabled = true
        case .web:
            model.settings.web.enabled = true
        }
        normalize()
    }

    /// Add a user-created (unmanaged) stream layer on top of the stack.
    private func addNode(_ kind: NodeKind, name: String) {
        let node = Node(
            name: nextLayerName(base: name, family: kind.family),
            kind: kind,
            inkConfig: kind.family == "ink" ? InkFrameConfig(landmarks: model.settings.landmarks) : nil,
            managed: false
        )
        mutate { g in
            g.nodes.append(node)
            g.layers.append(Layer(node: node.id))
        }
    }

    private func addSolid() {
        let node = Node(name: nextLayerName(base: "Solid", family: "solid"), kind: .solid(SolidConfig(color: RGBAColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1))), managed: false)
        mutate { g in
            g.nodes.append(node)
            g.layers.append(Layer(node: node.id))   // top of the stack
        }
    }

    private func addPaper() {
        let node = Node(name: nextLayerName(base: "Paper", family: "paper"), kind: .paper(PaperConfig()), managed: false)
        mutate { g in
            g.nodes.append(node)
            g.layers.append(Layer(node: node.id))
        }
    }

    private func addInkLayer() {
        model.settings.landmarks.inkEnabled = true
        addNode(.ink, name: "Ink")
    }

    private func nextLayerName(base: String, family: String) -> String {
        let existing = Set((model.settings.layerGraph?.nodes ?? []).compactMap { node -> String? in
            node.kind.family == family ? node.name : nil
        })
        var index = 1
        while existing.contains("\(base) \(index)") || existing.contains("\(base)\(index)") {
            index += 1
        }
        return "\(base) \(index)"
    }

    private func addAcrylic() {
        addNode(.acrylic(AcrylicConfig()), name: "Acrylic")
    }

    private func delete(_ id: UUID) {
        mutate { g in
            guard let layer = g.layers.first(where: { $0.id == id }) else { return }
            g.layers.removeAll { $0.id == id }
            g.nodes.removeAll { $0.id == layer.node }
        }
        if selectedLayerID == id { selectedLayerID = nil }
    }

    private func mutate(_ body: (inout LayerGraph) -> Void) {
        guard var g = model.settings.layerGraph else { return }
        body(&g)
        model.settings.layerGraph = g
    }

    private func mutateValidated(_ body: (inout LayerGraph) -> Void) {
        guard var g = model.settings.layerGraph else { return }
        body(&g)
        guard (try? g.validate()) != nil else { return }
        model.settings.layerGraph = g
    }

    private func toggleVisible(_ id: UUID) {
        mutate { g in
            if let i = g.layers.firstIndex(where: { $0.id == id }) { g.layers[i].visible.toggle() }
        }
    }

    private func opacity(_ id: UUID) -> Binding<Double> {
        Binding(
            get: { Double(model.settings.layerGraph?.layers.first { $0.id == id }?.opacity ?? 1) },
            set: { v in mutate { g in
                if let i = g.layers.firstIndex(where: { $0.id == id }) { g.layers[i].opacity = Float(v) }
            } }
        )
    }

    private func setBlend(_ id: UUID, _ blend: SketchCamCore.BlendMode) {
        mutate { g in
            if let i = g.layers.firstIndex(where: { $0.id == id }) { g.layers[i].blend = blend }
        }
    }

    private func reorderLayerForDisplay(_ draggedID: UUID, _ targetID: UUID) {
        guard draggedID != targetID else { return }
        mutate { g in
            var displayOrder = Array(g.layers.reversed())
            guard let from = displayOrder.firstIndex(where: { $0.id == draggedID }),
                  let to = displayOrder.firstIndex(where: { $0.id == targetID }) else { return }
            let moved = displayOrder.remove(at: from)
            let insertion = from < to ? to : max(0, to)
            displayOrder.insert(moved, at: min(insertion, displayOrder.count))
            g.layers = Array(displayOrder.reversed())
        }
    }
}

private struct LayerDropDelegate: DropDelegate {
    let targetID: UUID
    @Binding var draggedID: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedID, draggedID != targetID else { return }
        move(draggedID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedID = nil
        return true
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var precision: Int = 2
    let defaultValue: Double
    var hint: String?
    var toolbarDragProvider: (() -> NSItemProvider)?
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 6) {
            label
            Slider(value: $value, in: range)
                .controlSize(.small)
            // Editable: click/double-click to type an exact value — and you can
            // go OUTSIDE the slider range (e.g. a slightly negative Bleed) to
            // experiment; the slider thumb just pins to its end. Enter or Escape
            // commits and releases focus so keyboard shortcuts ([, ], etc.) work
            // again (clicking the canvas also releases it).
            TextField("", value: $value, format: .number.precision(.fractionLength(precision)))
                .textFieldStyle(.plain)
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .frame(width: 42, alignment: .trailing)
                .focused($editing)
                .onSubmit { editing = false }
                .onExitCommand { editing = false }
        }
        .frame(minHeight: 22)
        .contentShape(Rectangle())
        .help("\(hint ?? title) Double-click the label to restore the default; type an exact value in the number field and press Return.")
    }

    @ViewBuilder private var label: some View {
        let text = Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .frame(width: 70, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { value = defaultValue }
        if let toolbarDragProvider {
            text
                .onDrag { toolbarDragProvider() }
        } else {
            text
        }
    }
}

private struct OutputExportControls: View {
    @ObservedObject var exporter: OutputStreamExporter
    let chooseDestination: () -> Void
    let exportCurrent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    exportCurrent()
                } label: {
                    Label("Export current", systemImage: "square.and.arrow.down")
                }
                .panelButton()
                Button {
                    chooseDestination()
                } label: {
                    Label("Destination", systemImage: "folder")
                }
                .panelButton()
            }

            Text(exporter.destinationURL?.path(percentEncoded: false) ?? "No export destination")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)

            Picker("Type", selection: outputKind) {
                ForEach(ExportOutputKind.allCases) { kind in
                    Text(outputKindLabel(kind)).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            if exporter.configuration.outputKind == .still || exporter.configuration.outputKind == .imageSequence {
                Picker("Image", selection: imageFormat) {
                    ForEach(ExportImageFormat.allCases) { format in
                        Text(format.rawValue.uppercased()).tag(format)
                    }
                }
            }

            if exporter.configuration.outputKind == .movie {
                Picker("Codec", selection: movieCodec) {
                    ForEach(ExportMovieCodec.allCases) { codec in
                        Text(codecLabel(codec)).tag(codec)
                    }
                }
                Picker("Container", selection: container) {
                    ForEach(ExportContainer.allCases) { container in
                        Text(container.rawValue.uppercased()).tag(container)
                    }
                }
            }

            HStack {
                Text("Size")
                TextField("W", value: width, format: .number)
                    .frame(width: 64)
                Text("x")
                TextField("H", value: height, format: .number)
                    .frame(width: 64)
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Text("FPS")
                TextField("Capture", value: captureFPS, format: .number.precision(.fractionLength(0)))
                    .frame(width: 72)
                Text("->")
                TextField("Playback", value: playbackFPS, format: .number.precision(.fractionLength(0)))
                    .frame(width: 72)
            }
            .textFieldStyle(.roundedBorder)

            Picker("Trigger", selection: trigger) {
                ForEach(CaptureTrigger.allCases) { trigger in
                    Text(triggerLabel(trigger)).tag(trigger)
                }
            }

            HStack {
                TextField("Take", text: takeName)
                    .textFieldStyle(.roundedBorder)
                Button("Capture Next") { exporter.captureNext() }
                    .panelButton()
                    .disabled(exporter.state != .recording)
            }

            HStack {
                Button("Start") { exporter.start() }
                    .panelButton()
                    .disabled(exporter.destinationURL == nil || exporter.state == .recording || exporter.state == .finishing)
                Button("Stop") { exporter.stop() }
                    .panelButton()
                    .disabled(exporter.state != .recording)
                Button("Cancel") { exporter.stop(cancelled: true) }
                    .panelButton()
                    .disabled(exporter.state != .recording)
            }

            Text("\(exporter.statusText) - \(exporter.capturedFrames) frames, \(exporter.droppedFrames) dropped")
                .font(.caption)
                .foregroundStyle(exporter.state == .failed ? .red : .secondary)
            if let progress = exporter.progress {
                ProgressView(value: progress)
            }
        }
        .onChange(of: exporter.configuration) { _, _ in exporter.persistConfiguration() }
    }

    private var outputKind: Binding<ExportOutputKind> {
        Binding {
            exporter.configuration.outputKind
        } set: {
            exporter.configuration.outputKind = $0
            exporter.invalidateIncompatibleDestination()
        }
    }

    private var imageFormat: Binding<ExportImageFormat> {
        Binding {
            exporter.configuration.imageFormat
        } set: {
            exporter.configuration.imageFormat = $0
            exporter.invalidateIncompatibleDestination()
        }
    }

    private var movieCodec: Binding<ExportMovieCodec> {
        Binding {
            exporter.configuration.movieCodec
        } set: {
            exporter.configuration.movieCodec = $0
            exporter.configuration.clamp()
            exporter.invalidateIncompatibleDestination()
        }
    }

    private var container: Binding<ExportContainer> {
        Binding {
            exporter.configuration.container
        } set: {
            exporter.configuration.container = $0
            exporter.invalidateIncompatibleDestination()
        }
    }

    private var width: Binding<Int> {
        Binding {
            exporter.configuration.width
        } set: {
            exporter.configuration.width = $0
            exporter.configuration.clamp()
        }
    }

    private var height: Binding<Int> {
        Binding {
            exporter.configuration.height
        } set: {
            exporter.configuration.height = $0
            exporter.configuration.clamp()
        }
    }

    private var captureFPS: Binding<Double> {
        Binding {
            exporter.configuration.captureFPS
        } set: {
            exporter.configuration.captureFPS = $0
            exporter.configuration.clamp()
        }
    }

    private var playbackFPS: Binding<Double> {
        Binding {
            exporter.configuration.playbackFPS
        } set: {
            exporter.configuration.playbackFPS = $0
            exporter.configuration.clamp()
        }
    }

    private var trigger: Binding<CaptureTrigger> {
        Binding {
            exporter.configuration.trigger
        } set: {
            exporter.configuration.trigger = $0
        }
    }

    private var takeName: Binding<String> {
        Binding {
            exporter.configuration.takeName
        } set: {
            exporter.configuration.takeName = $0
        }
    }

    private func outputKindLabel(_ value: ExportOutputKind) -> String {
        switch value {
        case .still: "Still"
        case .movie: "Movie"
        case .imageSequence: "Sequence"
        case .gif: "GIF"
        }
    }

    private func codecLabel(_ value: ExportMovieCodec) -> String {
        switch value {
        case .h264: "H.264"
        case .hevc: "HEVC"
        case .proRes422: "ProRes 422"
        case .proRes422HQ: "ProRes HQ"
        case .proRes4444: "ProRes 4444"
        }
    }

    private func triggerLabel(_ value: CaptureTrigger) -> String {
        switch value {
        case .cadence: "Continuous rate"
        case .interval: "Interval"
        case .manual: "Manual"
        case .mouseDown: "Mouse down"
        case .mouseUp: "Mouse up"
        case .click: "Click"
        case .dragBegin: "Drag begin"
        case .dragEnd: "Drag end"
        case .drawBegin: "Draw begin"
        case .drawEnd: "Draw end"
        case .drawBoth: "Draw begin/end"
        case .washBegin: "Wash begin"
        case .washEnd: "Wash end"
        case .washBoth: "Wash begin/end"
        case .anyCanvasAction: "Canvas action"
        case .streamCrossing: "Stream crossing"
        }
    }
}

private struct InkToolbarStrip: View {
    let controls: [ToolbarControlID]
    @Binding var mode: InkBrushMode
    @Binding var inkKind: InkKind
    @Binding var inkColor: Color
    @Binding var smooth: Double
    @Binding var size: Double
    @Binding var washSize: Double
    @Binding var smear: Double
    @Binding var flow: Double
    @Binding var bleed: Double
    @Binding var dry: Double
    @Binding var wetDecay: Double
    @Binding var fade: Double
    @Binding var colorSeparation: Double
    @Binding var brushInk: Double
    let controlDragProvider: (ToolbarControlID) -> NSItemProvider
    let removeControl: (ToolbarControlID) -> Void
    let resetControls: () -> Void
    let fix: () -> Void
    let clear: () -> Void
    let save: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 22) {
                ForEach(controls) { control in
                    toolbarControl(control)
                        .onDrag { controlDragProvider(control) }
                        .contextMenu {
                            Button("Remove") { removeControl(control) }
                            Button("Reset Toolbar") { resetControls() }
                        }
                        .help("Option-drag this control to place it in a toolbar container. Right-click to remove or reset the toolbar.")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .controlSize(.small)
    }

    @ViewBuilder private func toolbarControl(_ control: ToolbarControlID) -> some View {
        switch control {
        case .mode:
            buttonControl(control.compactTitle, value: mode.title) { mode = mode.toggled }
        case .inkKind:
            buttonControl(control.compactTitle, value: inkKind.title) { inkKind = inkKind.toggled }
        case .hue:
            VStack(spacing: 5) {
                Text(control.compactTitle)
                    .hudLabel()
                ColorPicker("", selection: $inkColor, supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 26, height: 20)
            }
        case .smooth:
            hudSlider(control.compactTitle, value: $smooth, defaultValue: 0.5)
        case .penSize:
            hudSlider(control.compactTitle, value: $size, defaultValue: 0.5)
        case .washSize:
            hudSlider(control.compactTitle, value: $washSize, defaultValue: 0.5)
        case .smear:
            hudSlider(control.compactTitle, value: $smear, defaultValue: 0.5)
        case .flow:
            hudSlider(control.compactTitle, value: $flow, defaultValue: 0.9)
        case .bleed:
            hudSlider(control.compactTitle, value: $bleed, defaultValue: 0.8)
        case .dry:
            hudSlider(control.compactTitle, value: $dry, defaultValue: 0.25)
        case .wetDecay:
            hudSlider(control.compactTitle, value: $wetDecay, defaultValue: 1)
        case .fade:
            hudSlider(control.compactTitle, value: $fade, defaultValue: 1.2, range: 0.2...5)
        case .colorSeparation:
            hudSlider(control.compactTitle, value: $colorSeparation, defaultValue: 0.5)
        case .brushInk:
            hudSlider(control.compactTitle, value: $brushInk, defaultValue: 0)
        case .fix:
            command(control.compactTitle, systemImage: control.icon, action: fix)
        case .clear:
            command(control.compactTitle, systemImage: control.icon, action: clear)
        case .save:
            command(control.compactTitle, systemImage: control.icon, action: save)
        }
    }

    private func buttonControl(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .hudLabel()
            Button(value, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .tracking(1.6)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(minWidth: 58)
        }
    }

    private func hudSlider(_ label: String, value: Binding<Double>, defaultValue: Double, range: ClosedRange<Double> = 0...1) -> some View {
        VStack(spacing: 5) {
            Text(label)
                .hudLabel()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
            Slider(value: value, in: range)
                .frame(width: 86)
        }
    }

    private func command(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
        }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .help(title)
    }
}

private extension Text {
    func hudLabel() -> some View {
        self
            .font(.system(size: 10, weight: .medium))
            .tracking(4)
            .textCase(.uppercase)
            .foregroundStyle(.secondary.opacity(0.75))
    }
}

/// A 2D pad: drag the dot to set two normalized values at once (x = →, y = ↑,
/// both 0…1). Used for LineWalk's along-path × orthogonal wildness.
private struct XYPad: View {
    @Binding var x: Double
    @Binding var y: Double

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                // crosshair
                Path { p in
                    p.move(to: CGPoint(x: CGFloat(x) * size.width, y: 0))
                    p.addLine(to: CGPoint(x: CGFloat(x) * size.width, y: size.height))
                    p.move(to: CGPoint(x: 0, y: (1 - CGFloat(y)) * size.height))
                    p.addLine(to: CGPoint(x: size.width, y: (1 - CGFloat(y)) * size.height))
                }
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 12, height: 12)
                    .position(x: CGFloat(x) * size.width, y: (1 - CGFloat(y)) * size.height)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    x = min(1, max(0, Double(value.location.x / max(1, size.width))))
                    y = min(1, max(0, Double(1 - value.location.y / max(1, size.height))))
                }
            )
        }
    }
}

/// The generic minimal style control: one row binding a visual element's
/// color (with opacity) and its size — stroke width, dot scale, or
/// thickness depending on the element. Optionally fronted by an enable
/// checkbox (used for the landmark feature rows).
private struct StyleRow: View {
    let title: String
    var enabled: Binding<Bool>?
    @Binding var color: Color
    @Binding var size: Double
    var range: ClosedRange<Double> = 0.5...10

    init(
        title: String,
        enabled: Binding<Bool>? = nil,
        color: Binding<Color>,
        size: Binding<Double>,
        range: ClosedRange<Double> = 0.5...10
    ) {
        self.title = title
        self.enabled = enabled
        self._color = color
        self._size = size
        self.range = range
    }

    var body: some View {
        HStack(spacing: 8) {
            if let enabled {
                Toggle(title, isOn: enabled)
                    .toggleStyle(.checkbox)
                    .frame(width: 64, alignment: .leading)
            } else {
                Text(title)
                    .frame(width: 64, alignment: .leading)
            }
            ColorPicker("", selection: $color, supportsOpacity: true)
                .labelsHidden()
                .frame(width: 36)
            Slider(value: $size, in: range)
                .controlSize(.small)
                .disabled(enabled?.wrappedValue == false)
            Text(size, format: .number.precision(.fractionLength(1)))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

private struct DockPanel<Content: View, Trailing: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DockPanelHeader(title: title, systemImage: systemImage, trailing: trailing)
            content()
        }
    }
}

private struct DockPanelHeader<Trailing: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .help(title)
            Spacer(minLength: 0)
            trailing()
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

private struct TitlebarAccessory<Content: View>: NSViewRepresentable {
    var isVisible: Bool
    let content: Content

    init(isVisible: Bool, @ViewBuilder content: () -> Content) {
        self.isVisible = isVisible
        self.content = content()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.isHidden = true
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(content: content, isVisible: isVisible, from: nsView)
    }

    final class Coordinator {
        private var accessory: NSTitlebarAccessoryViewController?
        private var host: NSHostingController<Content>?

        func update(content: Content, isVisible: Bool, from anchor: NSView) {
            DispatchQueue.main.async { [weak self, weak anchor] in
                guard let self, let anchor else { return }
                if !isVisible {
                    self.removeAccessory()
                    return
                }
                guard let window = anchor.window else { return }
                if let host {
                    host.rootView = content
                    return
                }
                let host = NSHostingController(rootView: content)
                host.view.setFrameSize(host.view.fittingSize)
                host.view.translatesAutoresizingMaskIntoConstraints = false
                let accessory = NSTitlebarAccessoryViewController()
                accessory.layoutAttribute = .right
                accessory.view = host.view
                window.addTitlebarAccessoryViewController(accessory)
                self.host = host
                self.accessory = accessory
            }
        }

        private func removeAccessory() {
            guard let accessory, let window = accessory.view.window else {
                accessory = nil
                host = nil
                return
            }
            if let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            self.accessory = nil
            self.host = nil
        }
    }
}

private struct FocusEscapeHandler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.install()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        private var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53 else { return event }
                guard let window = event.window ?? NSApp.keyWindow else { return event }
                guard window.firstResponder != nil else { return event }
                window.makeFirstResponder(nil)
                return nil
            }
        }
    }
}

private struct TimelineMetric: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 62, alignment: .leading)
    }
}

private extension View {
    func panelButton() -> some View {
        self
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.callout.weight(.medium))
    }

    func dockDropHighlight(isTargeted: Bool) -> some View {
        self
            .background(isTargeted ? Color.accentColor.opacity(0.10) : Color.clear)
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.65), lineWidth: 2)
                        .padding(3)
                }
            }
    }
}

private struct InkStrokeDataList: View {
    let records: [InkStrokeRecord]
    @Binding var selectedRecordID: UUID?

    private var selectedRecord: InkStrokeRecord? {
        guard let selectedRecordID else { return records.last }
        return records.first { $0.id == selectedRecordID } ?? records.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if records.isEmpty {
                Text("No captured strokes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 64, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { index, record in
                            Button {
                                selectedRecordID = record.id
                            } label: {
                                InkStrokeDataRow(index: index, record: record, selected: selectedRecordID == record.id)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: 94)
                if let selectedRecord {
                    InkStrokeDetail(record: selectedRecord)
                }
            }
        }
    }
}

private struct InkStrokeDataRow: View {
    let index: Int
    let record: InkStrokeRecord
    let selected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text("#\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            Text(record.capture.mode.label)
                .font(.caption.weight(.semibold))
                .frame(width: 48, alignment: .leading)
            Text(record.isEditable ? "saved" : "immediate")
                .font(.caption)
                .foregroundStyle(record.isEditable ? .primary : .secondary)
                .frame(width: 68, alignment: .leading)
            Text(durationText(record.capture.duration))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
            Text("\(record.capture.canonicalSamples.count) pts")
                .font(.caption.monospacedDigit())
                .frame(width: 48, alignment: .trailing)
            Text(recipeSummary(record.activeRender))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}

private struct InkStrokeDetail: View {
    let record: InkStrokeRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.id.uuidString)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let frameID = record.frameID {
                Text("frame \(frameID.uuidString)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text("raw \(record.capture.rawSamples.count) / canonical \(record.capture.canonicalSamples.count), seed \(record.capture.seed), \(recipeSummary(record.activeRender))")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(.horizontal, 6)
    }
}

private extension InkStrokeCaptureMode {
    var label: String {
        switch self {
        case .pen: return "pen"
        case .wash: return "wash"
        case .wetOnly: return "wet"
        }
    }
}

private func durationText(_ duration: TimeInterval) -> String {
    String(format: "%.2fs", duration)
}

private func recipeSummary(_ recipe: InkRenderRecipe) -> String {
    "\(recipe.intent.rawValue) \(recipe.inkKind.rawValue) w\(String(format: "%.2f", recipe.width)) f\(String(format: "%.2f", recipe.flow)) \(recipe.algorithm)"
}

private struct InkEditorCanvas: View {
    @Binding var paths: [InkEditorPath]
    let paperColor: Color
    let inkColor: Color
    let inkRGBA: RGBAColor
    let brushMode: InkBrushMode
    let inkKind: InkKind
    let width: Float
    let flow: Float
    let bleed: Float
    let dry: Float
    let colorSeparation: Float
    let brushInk: Float
    @State private var current: [CGPoint] = []

    var body: some View {
        GeometryReader { geo in
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(paperColor))
                drawGrid(in: &context, size: size)
                for path in paths {
                    draw(points: path.points, size: size, context: &context, color: inkColor.opacity(0.72), width: 2.2)
                }
                draw(points: current, size: size, context: &context, color: inkColor, width: 2.8)
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let p = normalized(value.location, size: geo.size)
                        if current.last.map({ distance($0, p) > 0.004 }) ?? true {
                            current.append(p)
                        }
                    }
                    .onEnded { _ in
                        if current.count > 1 {
                            paths.append(InkEditorPath(
                                points: current,
                                brushMode: brushMode,
                                inkKind: inkKind,
                                width: width,
                                flow: flow,
                                bleed: bleed,
                                dry: dry,
                                colorSeparation: colorSeparation,
                                brushInk: brushInk,
                                color: inkRGBA
                            ))
                        }
                        current = []
                    }
            )
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var path = Path()
        let step: CGFloat = 24
        var x: CGFloat = step
        while x < size.width {
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
            x += step
        }
        var y: CGFloat = step
        while y < size.height {
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            y += step
        }
        context.stroke(path, with: .color(Color.secondary.opacity(0.10)), lineWidth: 1)
    }

    private func draw(points: [CGPoint], size: CGSize, context: inout GraphicsContext, color: Color, width: CGFloat) {
        guard let first = points.first else { return }
        var path = Path()
        path.move(to: denormalized(first, size: size))
        for point in points.dropFirst() {
            path.addLine(to: denormalized(point, size: size))
        }
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

    private func normalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(
            x: min(1, max(0, point.x / max(1, size.width))),
            y: min(1, max(0, point.y / max(1, size.height)))
        )
    }

    private func denormalized(_ point: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: point.x * size.width, y: point.y * size.height)
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }
}

private struct InkCanvasDragValue {
    var location: CGPoint
    var startLocation: CGPoint
    var secondary: Bool
    var combined: Bool
    var dissolveWash: Bool
    var shift: Bool
    var charge: Float
}

private struct InkCanvasEventOverlay: NSViewRepresentable {
    var onChanged: (InkCanvasDragValue) -> Void
    var onEnded: (Bool) -> Void

    func makeNSView(context: Context) -> EventView {
        // Deliver every mouse-dragged sample. By default macOS coalesces drag
        // events when the app is busy (and the inkwash sim makes it busier as a
        // session runs / after the queue backs up on tab-in), so fast strokes
        // arrive as a few far-apart points -> the smoothed path collapses to
        // straight chords ("choppy"). Uncoalesced delivery keeps strokes dense.
        NSEvent.isMouseCoalescingEnabled = false
        let view = EventView()
        view.onChanged = onChanged
        view.onEnded = onEnded
        return view
    }

    func updateNSView(_ nsView: EventView, context: Context) {
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
    }

    final class EventView: NSView {
        var onChanged: ((InkCanvasDragValue) -> Void)?
        var onEnded: ((Bool) -> Void)?
        private var startLocation: CGPoint?
        private var secondaryDrag = false
        private var downTimestamp: TimeInterval = 0
        private var dragCharge: Float = 0
        private var chargeLocked = false

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(nil)
            // Ctrl-drag smears like a right-drag (wash), without needing a second
            // mouse button. (If the system already promoted ctrl-click to a
            // rightMouseDown, that path handles it; otherwise we see it here.)
            begin(event, secondary: event.modifierFlags.contains(.control))
        }

        override func mouseDragged(with event: NSEvent) {
            update(event)
        }

        override func mouseUp(with event: NSEvent) {
            finish(event)
        }

        override func rightMouseDown(with event: NSEvent) {
            window?.makeFirstResponder(nil)
            begin(event, secondary: true)
        }

        override func rightMouseDragged(with event: NSEvent) {
            update(event)
        }

        override func rightMouseUp(with event: NSEvent) {
            finish(event)
        }

        private func begin(_ event: NSEvent, secondary: Bool) {
            secondaryDrag = secondary
            let point = convert(event.locationInWindow, from: nil)
            startLocation = point
            downTimestamp = event.timestamp
            dragCharge = 0
            chargeLocked = false
            onChanged?(dragValue(event, location: point, startLocation: point, secondary: secondary, charge: 0))
        }

        private func update(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let start = startLocation ?? point
            // Charge = how long the button was held before the drag actually
            // started moving (a "heavy weapon" wind-up). Locked once moving.
            if !chargeLocked, hypot(point.x - start.x, point.y - start.y) > 4 {
                dragCharge = Float(min(1.2, max(0, event.timestamp - downTimestamp)) / 1.2)
                chargeLocked = true
            }
            onChanged?(dragValue(event, location: point, startLocation: start, secondary: secondaryDrag, charge: dragCharge))
        }

        private func finish(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onChanged?(dragValue(event, location: point, startLocation: startLocation ?? point, secondary: secondaryDrag, charge: dragCharge))
            onEnded?(true)
            startLocation = nil
            secondaryDrag = false
            chargeLocked = false
            dragCharge = 0
        }

        private func dragValue(_ event: NSEvent, location: CGPoint, startLocation: CGPoint, secondary: Bool, charge: Float) -> InkCanvasDragValue {
            let flags = event.modifierFlags
            return InkCanvasDragValue(
                location: location,
                startLocation: startLocation,
                secondary: secondary,
                combined: flags.contains(.option),
                dissolveWash: flags.contains(.command),
                shift: flags.contains(.shift),
                charge: charge
            )
        }
    }
}

private struct ArtboardNavigationEvent {
    var location: CGPoint
    var deltaX: CGFloat
    var deltaY: CGFloat
    var modifiers: NSEvent.ModifierFlags
}

private struct ArtboardMagnifyEvent {
    var location: CGPoint
    var magnification: CGFloat
}

private struct ArtboardNavigationEventMonitor: NSViewRepresentable {
    var onScroll: (ArtboardNavigationEvent) -> Void
    var onMagnify: (ArtboardMagnifyEvent) -> Void

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.installMonitors()
        return view
    }

    func updateNSView(_ nsView: EventView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
    }

    static func dismantleNSView(_ nsView: EventView, coordinator: ()) {
        nsView.removeMonitors()
    }

    final class EventView: NSView {
        var onScroll: ((ArtboardNavigationEvent) -> Void)?
        var onMagnify: ((ArtboardMagnifyEvent) -> Void)?
        private var scrollMonitor: Any?
        private var magnifyMonitor: Any?

        override var isFlipped: Bool { true }

        func installMonitors() {
            guard scrollMonitor == nil, magnifyMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                self?.handleScroll(event)
                return event
            }
            magnifyMonitor = NSEvent.addLocalMonitorForEvents(matching: .magnify) { [weak self] event in
                self?.handleMagnify(event)
                return event
            }
        }

        func removeMonitors() {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
            if let magnifyMonitor {
                NSEvent.removeMonitor(magnifyMonitor)
                self.magnifyMonitor = nil
            }
        }

        private func handleScroll(_ event: NSEvent) {
            guard let point = localPoint(for: event) else { return }
            onScroll?(ArtboardNavigationEvent(
                location: point,
                deltaX: event.scrollingDeltaX,
                deltaY: event.scrollingDeltaY,
                modifiers: event.modifierFlags
            ))
        }

        private func handleMagnify(_ event: NSEvent) {
            guard let point = localPoint(for: event) else { return }
            onMagnify?(ArtboardMagnifyEvent(location: point, magnification: event.magnification))
        }

        private func localPoint(for event: NSEvent) -> CGPoint? {
            guard let window,
                  event.window === window else { return nil }
            let point = convert(event.locationInWindow, from: nil)
            return bounds.contains(point) ? point : nil
        }

        deinit {
            removeMonitors()
        }
    }
}

private func workspaceOutputRect(container: CGSize, outputSize: CGSize, workspace: CollageWorkspace?) -> CGRect {
    let fallbackViewport = CGRect(origin: .zero, size: outputSize)
    let viewport = workspace?.outputViewport.frame ?? fallbackViewport
    guard container.width > 0, container.height > 0,
          viewport.width > 0, viewport.height > 0 else {
        return CGRect(origin: .zero, size: container)
    }
    let fitScale = min(container.width / viewport.width, container.height / viewport.height)
    let scale = fitScale * CGFloat(max(0.05, min(16, workspace?.zoom ?? 1)))
    let center = workspace?.viewCenter ?? CGPoint(x: viewport.midX, y: viewport.midY)
    return CGRect(
        x: container.width * 0.5 + (viewport.minX - center.x) * scale,
        y: container.height * 0.5 + (viewport.minY - center.y) * scale,
        width: viewport.width * scale,
        height: viewport.height * scale
    )
}

private struct WorkspaceArtboardOverlay: View {
    @ObservedObject var model: SketchCamViewModel
    let outputSize: CGSize

    @State private var dragStarted = false
    @State private var dragOperation: DragOperation?
    @State private var magnifyStartZoom: Double?

    private enum DragOperation {
        case pan(startView: CGPoint, startCenter: CGPoint)
        case move(frameID: UUID, startWorld: CGPoint, transform: WorkspaceAffineTransform)
        case scale(frameID: UUID, centerWorld: CGPoint, startDistance: CGFloat, transform: WorkspaceAffineTransform)
    }

    var body: some View {
        GeometryReader { geo in
            let outputRect = workspaceOutputRect(container: geo.size, outputSize: outputSize, workspace: model.settings.workspace)
            ZStack {
                Canvas { context, _ in
                    drawOverlay(context: &context, outputRect: outputRect)
                }
                ArtboardNavigationEventMonitor(
                    onScroll: { event in
                        handleScroll(event, outputRect: outputRect)
                    },
                    onMagnify: { event in
                        handleMagnifyEvent(event, outputRect: outputRect)
                    }
                )
                Color.black.opacity(0.001)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        handleDragChanged(value, outputRect: outputRect)
                    }
                    .onEnded { _ in
                        handleDragEnded()
                    }
            )
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        handleMagnifyChanged(value)
                    }
                    .onEnded { _ in
                        magnifyStartZoom = nil
                    }
            )
        }
    }

    private func drawOverlay(context: inout GraphicsContext, outputRect: CGRect) {
        guard let workspace = model.settings.workspace else { return }
        var viewportPath = Path()
        viewportPath.addRect(outputRect)
        context.stroke(
            viewportPath,
            with: .color(Color.white.opacity(0.34)),
            style: StrokeStyle(lineWidth: 1, dash: [7, 5])
        )

        for frame in workspace.frames where frame.visible {
            let selected = workspace.selectedFrameIDs.contains(frame.id)
            let corners = frameCorners(frame, viewport: workspace.outputViewport.frame, outputRect: outputRect)
            guard corners.count == 4 else { continue }
            var path = Path()
            path.move(to: corners[0])
            for point in corners.dropFirst() {
                path.addLine(to: point)
            }
            path.closeSubpath()

            let color = frameColor(frame, selected: selected)
            if selected {
                context.fill(path, with: .color(color.opacity(0.08)))
            }
            context.stroke(
                path,
                with: .color(color.opacity(selected ? 0.92 : 0.5)),
                style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: frame.role == .reference ? [5, 4] : [])
            )

            if selected {
                for point in corners {
                    let handle = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
                    context.fill(Path(ellipseIn: handle), with: .color(color.opacity(0.95)))
                }
                drawCrop(frame, context: &context, viewport: workspace.outputViewport.frame, outputRect: outputRect, color: color)
            }

            let labelPoint = corners.reduce(corners[0]) { best, point in
                point.y < best.y || (point.y == best.y && point.x < best.x) ? point : best
            }
            let label = context.resolve(
                Text(frame.name)
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundColor(color.opacity(selected ? 0.95 : 0.65))
            )
            context.draw(label, at: CGPoint(x: labelPoint.x + 8, y: labelPoint.y + 12), anchor: .leading)
        }
    }

    private func drawCrop(
        _ frame: WorkspaceFrame,
        context: inout GraphicsContext,
        viewport: CGRect,
        outputRect: CGRect,
        color: Color
    ) {
        guard frame.cropRect != CGRect(x: 0, y: 0, width: 1, height: 1) else { return }
        let crop = frame.cropRect.standardized
        let bounds = frame.localBounds
        let local = CGRect(
            x: bounds.minX + crop.minX * bounds.width,
            y: bounds.minY + crop.minY * bounds.height,
            width: crop.width * bounds.width,
            height: crop.height * bounds.height
        )
        let points = rectCorners(local)
            .map { $0.applying(frame.transform.cgAffineTransform) }
            .map { viewPoint(world: $0, viewport: viewport, outputRect: outputRect) }
        guard points.count == 4 else { return }
        var path = Path()
        path.move(to: points[0])
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        context.stroke(path, with: .color(color.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
    }

    private func handleDragChanged(_ value: DragGesture.Value, outputRect: CGRect) {
        guard outputRect.width > 0,
              outputRect.height > 0,
              let workspace = model.settings.workspace else { return }
        if workspace.activeTool == .pan {
            handlePan(value, outputRect: outputRect, workspace: workspace)
            return
        }
        let world = worldPoint(view: value.location, viewport: workspace.outputViewport.frame, outputRect: outputRect)
        if !dragStarted {
            dragStarted = true
            if let handleHit = hitScaleHandle(at: value.location, workspace: workspace, outputRect: outputRect) {
                model.updateWorkspaceLiveEdit {
                    $0.activeFrameID = handleHit.frame.id
                    $0.selectedFrameIDs = [handleHit.frame.id]
                }
                model.beginWorkspaceLiveEdit()
                dragOperation = .scale(
                    frameID: handleHit.frame.id,
                    centerWorld: handleHit.centerWorld,
                    startDistance: max(1, distance(world, handleHit.centerWorld)),
                    transform: handleHit.frame.transform
                )
            }
            guard let hit = hitFrame(at: world, workspace: workspace, outputRect: outputRect) else {
                if dragOperation != nil { return }
                model.updateWorkspaceLiveEdit {
                    $0.activeFrameID = nil
                    $0.selectedFrameIDs = []
                }
                return
            }
            if dragOperation == nil {
                dragOperation = .move(frameID: hit.id, startWorld: world, transform: hit.transform)
            }
            model.updateWorkspaceLiveEdit {
                $0.activeFrameID = hit.id
                $0.selectedFrameIDs = [hit.id]
            }
            if !hit.locked {
                model.beginWorkspaceLiveEdit()
            }
        }

        switch dragOperation {
        case .pan:
            break
        case .move(let id, let start, let transform):
            let delta = CGPoint(x: world.x - start.x, y: world.y - start.y)
            model.updateWorkspaceLiveEdit { workspace in
                guard let index = workspace.frames.firstIndex(where: { $0.id == id }),
                      !workspace.frames[index].locked else { return }
                workspace.frames[index].transform.tx = transform.tx + delta.x
                workspace.frames[index].transform.ty = transform.ty + delta.y
            }
        case .scale(let id, let center, let startDistance, let transform):
            let scale = max(0.05, distance(world, center) / max(1, startDistance))
            model.updateWorkspaceLiveEdit { workspace in
                guard let index = workspace.frames.firstIndex(where: { $0.id == id }),
                      !workspace.frames[index].locked else { return }
                scaleFrame(&workspace.frames[index], from: transform, around: center, scale: scale)
            }
        case nil:
            break
        }
    }

    private func handleDragEnded() {
        if case .pan = dragOperation {
            model.endWorkspaceLiveEdit(commit: false)
        } else {
            model.endWorkspaceLiveEdit(commit: dragOperation != nil)
        }
        dragStarted = false
        dragOperation = nil
    }

    private func handlePan(_ value: DragGesture.Value, outputRect: CGRect, workspace: CollageWorkspace) {
        let scale = max(0.0001, outputRect.width / max(1, workspace.outputViewport.frame.width))
        if !dragStarted {
            dragStarted = true
            dragOperation = .pan(startView: value.location, startCenter: workspace.viewCenter)
        }
        guard case .pan(let startView, let startCenter) = dragOperation else { return }
        let delta = CGPoint(
            x: (value.location.x - startView.x) / scale,
            y: (value.location.y - startView.y) / scale
        )
        model.updateWorkspaceLiveEdit { workspace in
            workspace.viewCenter = CGPoint(x: startCenter.x - delta.x, y: startCenter.y - delta.y)
        }
    }

    private func handleScroll(_ event: ArtboardNavigationEvent, outputRect: CGRect) {
        guard outputRect.width > 0,
              let workspace = model.settings.workspace else { return }
        if event.modifiers.contains(.option) {
            let factor = pow(1.0018, Double(event.deltaY))
            zoomWorkspace(by: factor, around: event.location, outputRect: outputRect, workspace: workspace)
            return
        }
        let scale = max(0.0001, outputRect.width / max(1, workspace.outputViewport.frame.width))
        let direction: CGFloat = model.settings.resolvedArtboardDragCanvasWithScroll ? -1 : 1
        model.updateWorkspaceLiveEdit { workspace in
            workspace.viewCenter = CGPoint(
                x: workspace.viewCenter.x + direction * event.deltaX / scale,
                y: workspace.viewCenter.y + direction * event.deltaY / scale
            )
        }
    }

    private func handleMagnifyEvent(_ event: ArtboardMagnifyEvent, outputRect: CGRect) {
        guard let workspace = model.settings.workspace else { return }
        zoomWorkspace(by: 1 + Double(event.magnification), around: event.location, outputRect: outputRect, workspace: workspace)
    }

    private func zoomWorkspace(
        by factor: Double,
        around viewPoint: CGPoint,
        outputRect: CGRect,
        workspace: CollageWorkspace
    ) {
        let oldZoom = max(0.05, min(16, workspace.zoom))
        let newZoom = max(0.05, min(16, oldZoom * factor))
        guard abs(newZoom - oldZoom) > 0.0001 else { return }
        let viewport = workspace.outputViewport.frame
        let worldBefore = worldPoint(view: viewPoint, viewport: viewport, outputRect: outputRect)
        let nextOutputRect = outputRectFor(
            container: outputRect,
            viewport: viewport,
            center: workspace.viewCenter,
            zoomRatio: CGFloat(newZoom / oldZoom)
        )
        let worldAfter = worldPoint(view: viewPoint, viewport: viewport, outputRect: nextOutputRect)
        model.updateWorkspaceLiveEdit { workspace in
            workspace.zoom = newZoom
            workspace.viewCenter = CGPoint(
                x: workspace.viewCenter.x + (worldBefore.x - worldAfter.x),
                y: workspace.viewCenter.y + (worldBefore.y - worldAfter.y)
            )
        }
    }

    private func outputRectFor(
        container current: CGRect,
        viewport: CGRect,
        center: CGPoint,
        zoomRatio: CGFloat
    ) -> CGRect {
        let width = current.width * zoomRatio
        let height = current.height * zoomRatio
        return CGRect(
            x: current.midX - width * 0.5,
            y: current.midY - height * 0.5,
            width: width,
            height: height
        )
    }

    private func handleMagnifyChanged(_ value: CGFloat) {
        guard let workspace = model.settings.workspace else { return }
        if magnifyStartZoom == nil {
            magnifyStartZoom = workspace.zoom
        }
        let base = magnifyStartZoom ?? workspace.zoom
        let zoom = max(0.05, min(16, base * Double(value)))
        model.updateWorkspaceLiveEdit { workspace in
            workspace.zoom = zoom
        }
    }

    private func hitScaleHandle(at view: CGPoint, workspace: CollageWorkspace, outputRect: CGRect) -> (frame: WorkspaceFrame, centerWorld: CGPoint)? {
        for frame in workspace.frames.reversed() where workspace.selectedFrameIDs.contains(frame.id) && frame.visible && !frame.locked {
            let corners = frameCorners(frame, viewport: workspace.outputViewport.frame, outputRect: outputRect)
            if corners.contains(where: { distance($0, view) <= 12 }) {
                return (frame, centerWorld(frame))
            }
        }
        return nil
    }

    private func centerWorld(_ frame: WorkspaceFrame) -> CGPoint {
        CGPoint(x: frame.localBounds.midX, y: frame.localBounds.midY)
            .applying(frame.transform.cgAffineTransform)
    }

    private func scaleFrame(
        _ frame: inout WorkspaceFrame,
        from transform: WorkspaceAffineTransform,
        around centerWorld: CGPoint,
        scale: CGFloat
    ) {
        let centerLocal = CGPoint(x: frame.localBounds.midX, y: frame.localBounds.midY)
        let factor = Double(scale)
        frame.transform.a = transform.a * factor
        frame.transform.b = transform.b * factor
        frame.transform.c = transform.c * factor
        frame.transform.d = transform.d * factor
        frame.transform.tx = Double(centerWorld.x) - (Double(centerLocal.x) * frame.transform.a + Double(centerLocal.y) * frame.transform.c)
        frame.transform.ty = Double(centerWorld.y) - (Double(centerLocal.x) * frame.transform.b + Double(centerLocal.y) * frame.transform.d)
    }

    private func hitFrame(at world: CGPoint, workspace: CollageWorkspace, outputRect: CGRect) -> WorkspaceFrame? {
        let tolerance = max(2, workspace.outputViewport.frame.width / max(1, outputRect.width) * 8)
        return workspace.frames.reversed().first { frame in
            guard frame.visible else { return false }
            return frame.worldBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(world)
        }
    }

    private func frameCorners(_ frame: WorkspaceFrame, viewport: CGRect, outputRect: CGRect) -> [CGPoint] {
        rectCorners(frame.localBounds.insetBy(dx: -frame.bleed, dy: -frame.bleed))
            .map { $0.applying(frame.transform.cgAffineTransform) }
            .map { viewPoint(world: $0, viewport: viewport, outputRect: outputRect) }
    }

    private func rectCorners(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func viewPoint(world: CGPoint, viewport: CGRect, outputRect: CGRect) -> CGPoint {
        CGPoint(
            x: outputRect.minX + ((world.x - viewport.minX) / max(1, viewport.width)) * outputRect.width,
            y: outputRect.minY + ((world.y - viewport.minY) / max(1, viewport.height)) * outputRect.height
        )
    }

    private func worldPoint(view: CGPoint, viewport: CGRect, outputRect: CGRect) -> CGPoint {
        CGPoint(
            x: viewport.minX + ((view.x - outputRect.minX) / max(1, outputRect.width)) * viewport.width,
            y: viewport.minY + ((view.y - outputRect.minY) / max(1, outputRect.height)) * viewport.height
        )
    }

    private func frameColor(_ frame: WorkspaceFrame, selected: Bool) -> Color {
        if selected { return .accentColor }
        switch frame.role {
        case .output: return .green
        case .layer: return .white
        case .reference: return .cyan
        case .preview: return .purple
        }
    }

}

private struct InkPreviewDrawingLayer: View {
    @Binding var paths: [InkEditorPath]
    let showLivePath: Bool
    let immediatePen: Bool
    let immediateWash: Bool
    let smoothing: Float
    let onLive: (InkLiveStrokeSample) -> Void
    let onLiveEnd: () -> Void
    let onStrokeCommitted: (InkStrokeRecord) -> Void
    let outputSize: CGSize
    let outputRect: CGRect?
    let workspace: CollageWorkspace?
    let activeFrameID: UUID?
    let inkColor: Color
    let inkRGBA: RGBAColor
    let tool: InkTool
    let brushMode: InkBrushMode
    let inkKind: InkKind
    let width: Float
    let washWidth: Float
    let flow: Float
    let bleed: Float
    let dry: Float
    let colorSeparation: Float
    let brushInk: Float
    @Binding var selectedPathID: UUID?
    @Binding var selectedPointIndex: Int?
    @State private var current: [CGPoint] = []
    @State private var rawCurrent: [CGPoint] = []
    @State private var currentSampleTimes: [TimeInterval] = []
    @State private var currentSampleModifiers: [InkStrokeModifierFlags?] = []
    @State private var rawSampleModifiers: [InkStrokeModifierFlags?] = []
    @State private var currentSampleCharges: [Float?] = []
    @State private var rawSampleCharges: [Float?] = []
    @State private var currentStrokeStartTime: TimeInterval?
    @State private var currentStrokeSeed: UInt64?
    @State private var currentPathID: UUID?
    @State private var currentStrokeMode: InkBrushMode?
    @State private var currentWetOnly = false
    @State private var currentDissolveWash = false
    @State private var dragStartPaths: [InkEditorPath] = []
    @State private var dragStartPoint: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let rect = outputRect ?? fittedRect(container: geo.size, content: outputSize)
            ZStack {
                Color.black.opacity(0.001)
                if showsEditorPaths {
                    ForEach(paths) { path in
                        strokedPath(path.points, in: rect)
                            .stroke(path.id == selectedPathID ? Color.accentColor.opacity(0.8) : editorColor(for: path).opacity(0.24),
                                    style: StrokeStyle(lineWidth: path.id == selectedPathID ? 3 : 2, lineCap: .round, lineJoin: .round))
                        if path.id == selectedPathID {
                            selectionBounds(path.points, in: rect)
                                .stroke(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            ForEach(path.points.indices, id: \.self) { index in
                                Circle()
                                    .fill(index == selectedPointIndex ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                                    .frame(width: 9, height: 9)
                                    .position(viewPoint(path.points[index], in: rect))
                            }
                        }
                    }
                }
                // Thin dashed guide for the live cursor path (the rendered ink
                // lags behind). Off by default — the engine's mark is the truth.
                if showLivePath, !rawCurrent.isEmpty {
                    strokedPath(rawCurrent, in: rect)
                        .stroke(inkColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [4, 4]))
                }
                InkCanvasEventOverlay(
                    onChanged: { value in
                        guard rect.contains(value.location),
                              acceptsInput(value.location, in: rect) else { return }
                        handleDragChanged(value, in: rect)
                    },
                    onEnded: { ended in
                        handleDragEnded(committed: ended)
                    }
                )
            }
            .contentShape(Rectangle())
        }
    }

    private var showsEditorPaths: Bool {
        tool == .select || tool == .points
    }

    private func strokedPath(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: viewPoint(first, in: rect))
        for point in points.dropFirst() {
            path.addLine(to: viewPoint(point, in: rect))
        }
        return path
    }

    private func viewPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        if let mapping = activeFrameMapping(in: rect) {
            let local = CGPoint(
                x: mapping.target.minX + point.x * mapping.target.width,
                y: mapping.target.minY + point.y * mapping.target.height
            )
            let world = local.applying(mapping.frame.transform.cgAffineTransform)
            return viewPoint(world: world, viewport: mapping.viewport, outputRect: rect)
        }
        return CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func handleDragChanged(_ value: InkCanvasDragValue, in rect: CGRect) {
        let p = normalized(value.location, in: rect)
        switch tool {
        case .draw:
            selectedPathID = nil
            selectedPointIndex = nil
            updateLiveStroke(with: p, secondary: value.secondary, combined: value.combined, dissolveWash: value.dissolveWash, shift: value.shift, charge: value.charge)
        case .select:
            if dragStartPaths.isEmpty {
                dragStartPaths = paths
                selectedPointIndex = nil
                if selectedPathID == nil || !hitSelectedPath(at: p) {
                    selectedPathID = nearestPath(to: p, threshold: 0.025)?.id
                }
            }
            moveSelectedPath(from: normalized(value.startLocation, in: rect), to: p)
        case .points:
            if dragStartPaths.isEmpty {
                dragStartPaths = paths
                let hit = nearestPoint(to: p, threshold: 0.025)
                selectedPathID = hit?.pathID ?? nearestPath(to: p, threshold: 0.025)?.id
                selectedPointIndex = hit?.pointIndex
                if selectedPointIndex == nil, let selectedPathID {
                    selectedPointIndex = insertPoint(on: selectedPathID, near: p, threshold: 0.028)
                    dragStartPaths = paths
                }
                dragStartPoint = selectedPoint()
            }
            moveSelectedPoint(to: p)
        }
    }

    private func handleDragEnded(committed: Bool) {
        let strokeMode = currentStrokeMode ?? brushMode
        let immediate = (strokeMode == .pen && immediatePen) || (strokeMode == .brush && immediateWash)
        let record = completedStrokeRecord(strokeMode: strokeMode, immediate: immediate)
        if tool == .draw, committed, current.count > 1 {
            onStrokeCommitted(record)
        }
        onLiveEnd()
        current = []
        rawCurrent = []
        currentSampleTimes = []
        currentSampleModifiers = []
        rawSampleModifiers = []
        currentSampleCharges = []
        rawSampleCharges = []
        currentStrokeStartTime = nil
        currentStrokeSeed = nil
        currentPathID = nil
        currentStrokeMode = nil
        currentWetOnly = false
        currentDissolveWash = false
        dragStartPaths = []
        dragStartPoint = nil
    }

    private func completedStrokeRecord(strokeMode: InkBrushMode, immediate: Bool) -> InkStrokeRecord {
        let id = currentPathID ?? UUID()
        let seed = currentStrokeSeed ?? 0
        let times = currentSampleTimes.count == current.count ? currentSampleTimes : current.indices.map { TimeInterval($0) / 60 }
        let rawTimes = currentSampleTimes.count == rawCurrent.count ? currentSampleTimes : rawCurrent.indices.map { TimeInterval($0) / 60 }
        let rawSamples = rawCurrent.indices.map { index in
            InkStrokeSample(
                point: rawCurrent[index],
                time: rawTimes[index],
                modifiers: rawSampleModifiers.indices.contains(index) ? rawSampleModifiers[index] : nil,
                charge: rawSampleCharges.indices.contains(index) ? rawSampleCharges[index] : nil
            )
        }
        let canonicalSamples = current.indices.map { index in
            InkStrokeSample(
                point: current[index],
                time: times[index],
                modifiers: currentSampleModifiers.indices.contains(index) ? currentSampleModifiers[index] : nil,
                charge: currentSampleCharges.indices.contains(index) ? currentSampleCharges[index] : nil
            )
        }
        let captureMode: InkStrokeCaptureMode = currentWetOnly ? .wetOnly : (strokeMode == .pen ? .pen : .wash)
        let renderIntent: InkRenderIntent = currentWetOnly ? .wetOnly : (strokeMode == .pen ? .pen : .wash)
        let capture = InkStrokeCapture(
            id: id,
            seed: seed,
            rawSamples: rawSamples,
            canonicalSamples: canonicalSamples,
            mode: captureMode
        )
        let recipe = InkRenderRecipe(
            intent: renderIntent,
            inkKind: currentDissolveWash ? .white : inkKind,
            color: inkRGBA,
            width: strokeMode == .brush ? washWidth : width,
            flow: flow,
            bleed: bleed,
            dry: dry,
            colorSeparation: colorSeparation,
            brushInk: currentDissolveWash ? 1 : brushInk,
            smoothing: smoothing
        )
        return InkStrokeRecord(
            capture: capture,
            activeRender: recipe,
            frameID: activeFrameID,
            isEditable: !(immediate || currentWetOnly)
        )
    }

    private func updateLiveStroke(with point: CGPoint, secondary: Bool, combined: Bool, dissolveWash: Bool, shift: Bool, charge: Float) {
        // Per move we send the latest point + params to the engine; the channel
        // accumulates every point so the engine injects along all of them
        // (dense). `current` accumulates locally for the committed path + dashed
        // guide. This never touches the @Published settings struct.
        if current.isEmpty {
            let id = UUID()
            let now = ProcessInfo.processInfo.systemUptime
            currentPathID = id
            currentStrokeStartTime = now
            currentStrokeSeed = UInt64.random(in: UInt64.min...UInt64.max)
            currentStrokeMode = dissolveWash ? .brush : (combined ? .brush : (secondary ? .brush : brushMode))
            currentWetOnly = combined && !dissolveWash
            currentDissolveWash = dissolveWash
            current = [point]
            rawCurrent = [point]
            currentSampleTimes = [0]
            let flags = InkStrokeModifierFlags(shift: shift, option: secondary, command: combined, control: dissolveWash)
            currentSampleModifiers = [flags]
            rawSampleModifiers = [flags]
            currentSampleCharges = [charge]
            rawSampleCharges = [charge]
            emitLiveSamples(point: point, time: 0, shift: shift, charge: charge)
            return
        }
        if rawCurrent.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.0015 }) ?? true {
            let now = ProcessInfo.processInfo.systemUptime
            let eventTime = max(0, now - (currentStrokeStartTime ?? now))
            rawCurrent.append(point)
            let mode = currentStrokeMode ?? brushMode
            let canonicalPoint: CGPoint
            if mode == .pen {
                let amount = min(1, max(0, max(smoothing, shift ? 0.85 : 0)))
                if amount < 0.001 {
                    canonicalPoint = point
                } else {
                    let dt = max(eventTime - (currentSampleTimes.last ?? 0), 1.0 / 240.0)
                    // Responsive streaming streamline: smooth event noise while
                    // keeping the brush close enough to the hand for action
                    // drawing. This is applied once and stored as geometry.
                    let followRate = 14.0 + (1.0 - Double(amount)) * 76.0
                    let alpha = 1.0 - exp(-dt * followRate)
                    let previous = current.last ?? point
                    canonicalPoint = CGPoint(
                        x: previous.x + (point.x - previous.x) * alpha,
                        y: previous.y + (point.y - previous.y) * alpha
                    )
                }
            } else {
                canonicalPoint = point
            }
            current.append(canonicalPoint)
            currentSampleTimes.append(eventTime)
            let flags = InkStrokeModifierFlags(shift: shift, option: secondary, command: combined, control: dissolveWash)
            rawSampleModifiers.append(flags)
            currentSampleModifiers.append(flags)
            rawSampleCharges.append(charge)
            currentSampleCharges.append(charge)
            emitLiveSamples(point: canonicalPoint, time: eventTime, shift: shift, charge: charge)
        } else if (currentStrokeMode ?? brushMode) == .brush {
            let now = ProcessInfo.processInfo.systemUptime
            emitLiveSamples(point: point, time: max(0, now - (currentStrokeStartTime ?? now)), shift: shift, charge: charge)
        }
    }

    private func emitLiveSamples(point: CGPoint, time: TimeInterval, shift: Bool, charge: Float) {
        onLive(makeSample(id: currentPathID ?? UUID(), point: point, time: time, mode: currentStrokeMode ?? brushMode, shift: shift, charge: charge))
    }

    private func makeSample(
        id: UUID,
        point: CGPoint,
        time: TimeInterval,
        mode strokeMode: InkBrushMode,
        widthScale: Float = 1,
        flowScale: Float = 1,
        shift: Bool,
        charge: Float
    ) -> InkLiveStrokeSample {
        return InkLiveStrokeSample(
            id: id,
            seed: currentStrokeSeed ?? 0,
            point: point,
            time: time,
            brushMode: strokeMode,
            inkKind: currentDissolveWash ? .white : inkKind,
            width: (strokeMode == .brush ? washWidth : width) * widthScale,
            flow: flow * flowScale,
            brushInk: currentDissolveWash ? 1 : brushInk,
            color: inkRGBA,
            smoothBoost: shift,
            destructive: strokeMode == .brush && immediateWash && !currentWetOnly,
            wetOnly: currentWetOnly,
            charge: charge
        )
    }

    private func editorColor(for path: InkEditorPath) -> Color {
        if (path.brushMode ?? .pen) == .brush {
            return Color(red: 0.33, green: 0.42, blue: 0.74)
        }
        return (path.inkKind ?? .black) == .white ? .white : inkColor
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        if let mapped = frameNormalized(point, in: rect, clamped: true) {
            return mapped
        }
        return CGPoint(
            x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
            y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height)))
        )
    }

    private struct ActiveFrameMapping {
        var frame: WorkspaceFrame
        var viewport: CGRect
        var target: CGRect
    }

    private func activeFrameMapping(in rect: CGRect) -> ActiveFrameMapping? {
        guard let workspace,
              let frame = workspace.frame(id: activeFrameID),
              rect.width > 0,
              rect.height > 0 else { return nil }
        let target = frame.localBounds.insetBy(dx: -frame.bleed, dy: -frame.bleed)
        guard target.width > 0,
              target.height > 0,
              isInvertible(frame.transform.cgAffineTransform) else { return nil }
        return ActiveFrameMapping(frame: frame, viewport: workspace.outputViewport.frame, target: target)
    }

    private func isInvertible(_ transform: CGAffineTransform) -> Bool {
        abs(transform.a * transform.d - transform.b * transform.c) > 0.000001
    }

    private func acceptsInput(_ point: CGPoint, in rect: CGRect) -> Bool {
        guard activeFrameMapping(in: rect) != nil,
              let normalized = frameNormalized(point, in: rect, clamped: false) else {
            return true
        }
        let slop: CGFloat = 0.01
        return normalized.x >= -slop &&
            normalized.x <= 1 + slop &&
            normalized.y >= -slop &&
            normalized.y <= 1 + slop
    }

    private func frameNormalized(_ point: CGPoint, in rect: CGRect, clamped: Bool) -> CGPoint? {
        guard let mapping = activeFrameMapping(in: rect) else { return nil }
        let world = worldPoint(view: point, viewport: mapping.viewport, outputRect: rect)
        let local = world.applying(mapping.frame.transform.cgAffineTransform.inverted())
        let normalized = CGPoint(
            x: (local.x - mapping.target.minX) / max(1, mapping.target.width),
            y: (local.y - mapping.target.minY) / max(1, mapping.target.height)
        )
        guard clamped else { return normalized }
        return CGPoint(
            x: min(1, max(0, normalized.x)),
            y: min(1, max(0, normalized.y))
        )
    }

    private func viewPoint(world: CGPoint, viewport: CGRect, outputRect: CGRect) -> CGPoint {
        return CGPoint(
            x: outputRect.minX + ((world.x - viewport.minX) / max(1, viewport.width)) * outputRect.width,
            y: outputRect.minY + ((world.y - viewport.minY) / max(1, viewport.height)) * outputRect.height
        )
    }

    private func worldPoint(view: CGPoint, viewport: CGRect, outputRect: CGRect) -> CGPoint {
        return CGPoint(
            x: viewport.minX + ((view.x - outputRect.minX) / max(1, outputRect.width)) * viewport.width,
            y: viewport.minY + ((view.y - outputRect.minY) / max(1, outputRect.height)) * viewport.height
        )
    }

    private func selectionBounds(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }
        let viewPoints = points.map { viewPoint($0, in: rect) }
        let xs = viewPoints.map(\.x)
        let ys = viewPoints.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        let inset: CGFloat = 6
        path.addRect(CGRect(
            x: minX - inset,
            y: minY - inset,
            width: maxX - minX + inset * 2,
            height: maxY - minY + inset * 2
        ))
        return path
    }

    private func nearestPath(to point: CGPoint, threshold: CGFloat) -> InkEditorPath? {
        paths
            .map { ($0, distanceToPath(point, $0.points)) }
            .filter { $0.1 <= threshold }
            .min { $0.1 < $1.1 }?
            .0
    }

    private func nearestPoint(to point: CGPoint, threshold: CGFloat) -> (pathID: UUID, pointIndex: Int)? {
        var best: (UUID, Int, CGFloat)?
        for path in paths {
            for (index, candidate) in path.points.enumerated() {
                let d = hypot(candidate.x - point.x, candidate.y - point.y)
                if d <= threshold, best == nil || d < best!.2 {
                    best = (path.id, index, d)
                }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func hitSelectedPath(at point: CGPoint) -> Bool {
        guard let selectedPathID,
              let path = paths.first(where: { $0.id == selectedPathID }) else { return false }
        return distanceToPath(point, path.points) <= 0.025
    }

    private func moveSelectedPath(from start: CGPoint, to end: CGPoint) {
        guard let selectedPathID,
              let original = dragStartPaths.first(where: { $0.id == selectedPathID }),
              let index = paths.firstIndex(where: { $0.id == selectedPathID }) else { return }
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        paths[index].points = original.points.map {
            CGPoint(x: min(1, max(0, $0.x + delta.x)), y: min(1, max(0, $0.y + delta.y)))
        }
    }

    private func selectedPoint() -> CGPoint? {
        guard let selectedPathID,
              let selectedPointIndex,
              let path = paths.first(where: { $0.id == selectedPathID }),
              path.points.indices.contains(selectedPointIndex) else { return nil }
        return path.points[selectedPointIndex]
    }

    private func moveSelectedPoint(to point: CGPoint) {
        guard let selectedPathID,
              let selectedPointIndex,
              let index = paths.firstIndex(where: { $0.id == selectedPathID }),
              paths[index].points.indices.contains(selectedPointIndex) else { return }
        paths[index].points[selectedPointIndex] = point
    }

    private func insertPoint(on pathID: UUID, near point: CGPoint, threshold: CGFloat) -> Int? {
        guard let pathIndex = paths.firstIndex(where: { $0.id == pathID }) else { return nil }
        let pts = paths[pathIndex].points
        guard pts.count >= 2 else { return nil }
        var best: (segment: Int, distance: CGFloat)?
        for i in 0..<(pts.count - 1) {
            let d = distanceToSegment(point, pts[i], pts[i + 1])
            if d <= threshold, best == nil || d < best!.distance {
                best = (i, d)
            }
        }
        guard let best else { return nil }
        let insertIndex = best.segment + 1
        paths[pathIndex].points.insert(point, at: insertIndex)
        return insertIndex
    }

    private func distanceToPath(_ point: CGPoint, _ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        return (0..<(points.count - 1))
            .map { distanceToSegment(point, points[$0], points[$0 + 1]) }
            .min() ?? .greatestFiniteMagnitude
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let len2 = vx * vx + vy * vy
        guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * vx + (p.y - a.y) * vy) / len2))
        let q = CGPoint(x: a.x + vx * t, y: a.y + vy * t)
        return hypot(p.x - q.x, p.y - q.y)
    }

    private func fittedRect(container: CGSize, content: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0, content.width > 0, content.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: (container.width - size.width) / 2,
            y: (container.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }
}

/// Observers of the high-frequency `LiveReadouts` store. Keeping the observation
/// here (not in ContentView) means the ~4 Hz stats/preview updates only
/// re-evaluate these leaf views, not the whole control panel — which otherwise
/// leaked SwiftUI Picker tag projections / Observation registrars on every pass.
private struct LivePreviewImage: View {
    @ObservedObject var live: LiveReadouts
    var body: some View {
        if let image = live.previewImage {
            Image(image, scale: 1, label: Text("SketchCam preview"))
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            ProgressView()
                .controlSize(.large)
        }
    }
}

private struct LiveDebugGrid: View {
    @ObservedObject var live: LiveReadouts
    let permission: String
    let threshold: Float
    var body: some View {
        DebugGrid(stats: live.stats, permission: permission, threshold: threshold)
    }
}

private struct LiveDebugOverlay: View {
    @ObservedObject var live: LiveReadouts
    let permission: String
    let threshold: Float
    let error: String?
    let close: () -> Void
    @Binding var offset: CGSize
    var body: some View {
        DebugOverlay(stats: live.stats, permission: permission, threshold: threshold, error: error, close: close, offset: $offset)
    }
}

private struct DebugGrid: View {
    let stats: DebugStats
    let permission: String
    let threshold: Float
    var labelColor: Color = .primary
    var valueColor: Color = .primary

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
            row("Permission", permission)
            row("Camera", stats.cameraResolutionText)
            row("Output", stats.outputFormat.displayName)
            row("FPS", String(format: "%.1f", stats.fps))
            row("Frame", "\(stats.frameIndex)")
            row("Virtual", stats.virtualCameraStatus)
            row("Threshold", String(format: "%.2f", threshold))
            ForEach(stats.stageMillis, id: \.stage) { entry in
                row(entry.stage.displayName, String(format: "%.1f ms", entry.millis))
            }
        }
        .font(.caption)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(labelColor)
            Text(value)
                .foregroundStyle(valueColor)
                .lineLimit(2)
        }
    }
}

private struct DebugOverlay: View {
    let stats: DebugStats
    let permission: String
    let threshold: Float
    let error: String?
    let close: () -> Void
    @Binding var offset: CGSize
    @GestureState private var dragTranslation = CGSize.zero

    private var visibleOffset: CGSize {
        CGSize(
            width: offset.width + dragTranslation.width,
            height: offset.height + dragTranslation.height
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("Performance", systemImage: "chart.line.uptrend.xyaxis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark")
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Hide performance overlay")
            }
            DebugGrid(
                stats: stats,
                permission: permission,
                threshold: threshold,
                labelColor: Color.white.opacity(0.82),
                valueColor: .white
            )
            if let error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(Color.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .background(.regularMaterial.opacity(0.62), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
        .offset(visibleOffset)
        .gesture(
            DragGesture()
                .updating($dragTranslation) { value, state, _ in
                    state = value.translation
                }
                .onEnded { value in
                    offset.width += value.translation.width
                    offset.height += value.translation.height
                }
        )
        .help("Drag to move")
    }
}

private struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.10)))
            let square: CGFloat = 12
            var path = Path()
            var y: CGFloat = 0
            var row = 0
            while y < size.height {
                var x: CGFloat = row.isMultiple(of: 2) ? 0 : square
                while x < size.width {
                    path.addRect(CGRect(x: x, y: y, width: square, height: square))
                    x += square * 2
                }
                y += square
                row += 1
            }
            context.fill(path, with: .color(Color(white: 0.16)))
        }
    }
}
