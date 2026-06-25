import AppKit
import AVFoundation
import SketchCamCore
import SketchCamShared
import SwiftUI

final class AppUIState: ObservableObject {
    @Published var debugOverlayVisible = false

    func toggleDebugOverlay() {
        debugOverlayVisible.toggle()
    }
}

enum ControlTab: String, CaseIterable, Identifiable {
    case layers = "Layers"
    case camera = "Camera"
    case movie = "Movie"
    case marks = "Marks"
    case yarn = "Yarn"
    case wrap = "Wrap"
    case lineWalk = "Line walk"
    case ink = "Ink"
    case web = "Web"
    case presets = "Presets"
    case keys = "Keys"
    case debug = "Debug"
    case export = "Export"
    case input = "Settings"

    var id: String { rawValue }

    static let defaultVisible: Set<ControlTab> = [.layers, .camera, .export, .input]

    static func visibleTabs(from rawValue: String) -> [ControlTab] {
        guard !rawValue.isEmpty else {
            return allCases.filter { defaultVisible.contains($0) }
        }
        let ids = Set(rawValue.split(separator: ",").map(String.init))
        let shown = allCases.filter { ids.contains($0.id) }
        var result = shown.isEmpty ? allCases.filter { defaultVisible.contains($0) } : shown
        if !result.contains(.export), let index = allCases.firstIndex(of: .export) {
            result.insert(.export, at: min(index, result.count))
        }
        return result
    }

    static func storageValue(for tabs: Set<ControlTab>) -> String {
        allCases
            .filter { tabs.contains($0) }
            .map { $0.id }
            .joined(separator: ",")
    }

    var icon: String {
        switch self {
        case .input: "gearshape"
        case .camera: "camera"
        case .movie: "film"
        case .layers: "square.3.layers.3d"
        case .marks: "point.3.connected.trianglepath.dotted"
        case .yarn: "scribble.variable"
        case .wrap: "figure.stand"
        case .lineWalk: "lasso"
        case .ink: "paintbrush.pointed"
        case .web: "globe"
        case .presets: "bookmark"
        case .keys: "keyboard"
        case .debug: "ladybug"
        case .export: "square.and.arrow.down"
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

struct ContentView: View {
    @StateObject private var model = SketchCamViewModel()
    @StateObject private var windowMode = WindowModeController()
    @StateObject private var presetStore = PresetStore()
    @EnvironmentObject private var appUI: AppUIState
    @State private var newPresetName = ""
    @State private var recallWholeState = false
    @State private var webURLField = ""
    @State private var webSnippetField = ""
    @ObservedObject private var shortcuts = ShortcutRegistry.shared
    @State private var movieURLField = ""
    @State private var tab = ControlTab.layers
    /// Comma-separated ids of the tabs shown in the tab bar. Empty = default visible tabs.
    @AppStorage("visibleControlTabs") private var visibleTabsRaw: String = ""
    @AppStorage(InkUndoPreferences.gpuStateCountKey)
    private var inkUndoGPUStateCount = InkUndoPreferences.defaultGPUStateCount
    @AppStorage("ink.drawAcrossPanels") private var inkDrawAcrossPanels = false
    @State private var inkTool = InkTool.draw
    @State private var selectedInkPathID: UUID?
    @State private var selectedInkPointIndex: Int?
    @State private var inkHUDVisible = false
    @State private var inkPaperSettingsExpanded = false
    @State private var debugOverlayOffset = CGSize.zero
    @State private var exportPointerDown = false
    @State private var exportPointerDragging = false
    @State private var canvasCamera = CanvasCamera()
    @State private var canvasNavigationActive = false
    @AppStorage("canvas.pixelExtent") private var canvasPixelExtent = 8192.0
    @AppStorage("canvas.brushSpace") private var canvasBrushSpaceRaw = CanvasBrushSpace.screen.rawValue
    @AppStorage("export.auxPreviewEnabled") private var exportAuxPreviewEnabled = true

    var body: some View {
        Group {
            if windowMode.panelVisible && windowMode.panelFit {
                // Fit mode: panel sits beside the canvas; the canvas shrinks to
                // the remaining space (fully visible, never under the panel).
                HStack(spacing: 0) {
                    previewPane
                    controlsPane
                        .frame(width: 360)
                        .background(Color(nsColor: .windowBackgroundColor))
                        .overlay(alignment: .leading) { Divider() }
                }
            } else {
                contentWithOverlayPanel
            }
        }
        .overlay { debugOverlay }
        .background(windowMode.transparent ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor(controller: windowMode))
        .onAppear {
            model.start()
            model.replaceEditableCanvasPaths(model.settings.landmarks.inkPaths)
            publishCanvasRenderContext()
            updateExportPreviewActive()
            registerShortcuts()
            ShortcutRegistry.shared.start()
        }
        .onDisappear { model.stop() }
        .onChange(of: canvasCamera) { _, _ in publishCanvasRenderContext() }
        .onChange(of: canvasPixelExtent) { _, _ in publishCanvasRenderContext() }
        .onChange(of: canvasNavigationActive) { _, _ in publishCanvasRenderContext() }
        .onChange(of: canvasBrushSpaceRaw) { _, _ in publishCanvasRenderContext() }
        .onChange(of: model.outputFormat) { _, _ in publishCanvasRenderContext() }
        .onChange(of: tab) { _, _ in updateExportPreviewActive() }
        .onChange(of: exportAuxPreviewEnabled) { _, _ in updateExportPreviewActive() }
        .onChange(of: canvasNavigationActive) { _, _ in updateExportPreviewActive() }
    }

    private var contentWithOverlayPanel: some View {
        previewPane
            .overlay {
                // Overlay mode: panel floats over the canvas inside a
                // GeometryReader (which reports no minimum size, so the 360pt
                // panel can never constrain how small the window may shrink, PIP).
                if windowMode.panelVisible {
                    GeometryReader { _ in
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            controlsPane
                                .background(Color(nsColor: .windowBackgroundColor).opacity(0.92))
                                .overlay(alignment: .leading) { Divider() }
                        }
                    }
                }
            }
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
            let viewportRect = fittedPreviewRect(container: geo.size, content: model.outputFormat.size)
            ZStack {
                // Checkerboard backdrop so an Alpha background (or ink-only
                // threshold) is visibly transparent in the preview instead of
                // reading as black. Hidden in transparent-window mode, where
                // alpha must be ACTUALLY transparent.
                if !windowMode.transparent {
                    CheckerboardBackground()
                }
                ZStack {
                    CanvasWorldSurface(
                        fill: canvasBackdropColor,
                        visible: model.settings.previewEnabled
                    )
                    .frame(width: viewportRect.width, height: viewportRect.height)
                    if model.settings.previewEnabled {
                        if model.settings.useMetalPreview, model.settings.previewMode != .split {
                            // Zero-readback GPU display (also the presentation-mode output).
                            SampleBufferDisplayView(controller: model.previewDisplay)
                                .frame(width: viewportRect.width, height: viewportRect.height)
                                .transaction { $0.animation = nil }
                        } else {
                            // Observes the live store, so the ~4 Hz image updates don't
                            // re-evaluate the whole ContentView body.
                            LivePreviewImage(live: model.live)
                                .frame(width: viewportRect.width, height: viewportRect.height)
                                .transaction { $0.animation = nil }
                        }
                    }
                }
                .frame(width: viewportRect.width, height: viewportRect.height)
                .clipped()
                .position(x: viewportRect.midX, y: viewportRect.midY)
                .allowsHitTesting(false)
                if !model.settings.previewEnabled {
                    Text("Preview off — still publishing")
                        .foregroundStyle(.secondary)
                }
                PreviewNavigationEventOverlay(
                    onPan: { delta in panCanvasViewport(by: delta, container: geo.size) },
                    onZoom: { factor, anchor in zoomCanvasViewport(by: factor, anchor: anchor, container: geo.size) },
                    onNavigationActive: setCanvasNavigationActive,
                    plainDragPans: !inkCanvasInputActive
                )
                .zIndex(10)
                if inkCanvasInputActive {
                    InkPreviewDrawingLayer(
                        paths: inkPathsBinding,
                        showLivePath: model.settings.landmarks.inkShowLivePath,
                        immediatePen: model.settings.landmarks.inkImmediatePen,
                        immediateWash: model.settings.landmarks.inkImmediateWash,
                        smoothing: model.settings.landmarks.inkSmoothing,
                        onLive: { model.updateInkLiveStroke($0) },
                        onLiveEnd: { model.endInkLiveStroke() },
                        onImmediateCommitted: { model.commitImmediateCanvasStroke($0) },
                        onCanvasAction: { model.signalCanvasAction(path: $0) },
                        outputSize: model.outputFormat.size,
                        inkColor: rgbaColor(model.settings.landmarks.inkColor),
                        inkRGBA: model.settings.landmarks.inkColor,
                        tool: .draw,
                        brushMode: currentInkMode,
                        inkKind: currentInkKind,
                        width: Float(inkSizeBinding.wrappedValue),
                        washWidth: Float(inkWashSizeBinding.wrappedValue),
                        flow: model.settings.landmarks.inkFlow,
                        bleed: model.settings.landmarks.inkBleed,
                        dry: model.settings.landmarks.inkDry,
                        colorSeparation: Float(inkColorSeparationBinding.wrappedValue),
                        brushInk: Float(inkBrushInkBinding.wrappedValue),
                        camera: currentCanvasCamera,
                        worldHeight: canvasWorldHeight,
                        worldPixelExtent: CGFloat(canvasPixelExtent),
                        onViewportPan: { delta in panCanvasViewport(by: delta, container: geo.size) },
                        onViewportZoom: { factor, anchor in zoomCanvasViewport(by: factor, anchor: anchor, container: geo.size) },
                        onNavigationActive: setCanvasNavigationActive,
                        brushSpace: canvasBrushSpace,
                        selectedPathID: $selectedInkPathID,
                        selectedPointIndex: $selectedInkPointIndex
                    )
                    .zIndex(20)
                }
                if tab == .ink, model.settings.landmarks.inkEnabled, inkHUDVisible {
                    InkBottomHUD(
                        mode: inkModeBinding,
                        inkKind: inkKindBinding,
                        inkColor: rgbaBinding(\.landmarks.inkColor),
                        size: inkSizeBinding,
                        flow: floatBinding(\.landmarks.inkFlow),
                        bleed: floatBinding(\.landmarks.inkBleed),
                        dry: floatBinding(\.landmarks.inkDry),
                        colorSeparation: inkColorSeparationBinding,
                        brushInk: inkBrushInkBinding,
                        fix: fixInk,
                        clear: clearInk
                    )
                    .padding(.bottom, 20)
                    .transition(.opacity)
                    .zIndex(30)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    inkHUDVisible = tab == .ink && point.y > geo.size.height - 130
                case .ended:
                    inkHUDVisible = false
                }
            }
        }
        .frame(minWidth: 120, minHeight: 68)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !exportPointerDown {
                        exportPointerDown = true
                        model.exporter.signal(.mouseDown)
                    }
                    if !exportPointerDragging,
                       hypot(value.translation.width, value.translation.height) >= 2 {
                        exportPointerDragging = true
                        model.exporter.signal(.dragBegin)
                    }
                }
                .onEnded { value in
                    if exportPointerDragging { model.exporter.signal(.dragEnd) }
                    model.exporter.signal(.mouseUp)
                    if hypot(value.translation.width, value.translation.height) < 2 {
                        model.exporter.signal(.click)
                    }
                    exportPointerDown = false
                    exportPointerDragging = false
                }
        )
    }

    private func panCanvasViewport(by delta: CGSize, container: CGSize) {
        let rect = fittedPreviewRect(container: container, content: model.outputFormat.size)
        let base = max(1, rect.height)
        var camera = currentCanvasCamera
        let worldDelta = CGSize(
            width: -delta.width / base * camera.viewHeight,
            height: -delta.height / base * camera.viewHeight
        )
        camera.center.x += worldDelta.width
        camera.center.y += worldDelta.height
        setCanvasCamera(clamped(camera))
    }

    private func zoomCanvasViewport(by factor: CGFloat, anchor: CGPoint, container: CGSize) {
        guard factor.isFinite, factor > 0, container.width > 0, container.height > 0 else { return }
        let before = worldPoint(fromView: anchor, container: container)
        var camera = currentCanvasCamera
        camera.viewHeight = max(0.08, camera.viewHeight / factor)
        let after = worldPoint(fromView: anchor, container: container, camera: camera)
        camera.center.x += before.x - after.x
        camera.center.y += before.y - after.y
        setCanvasCamera(clamped(camera))
    }

    private func setCanvasNavigationActive(_ active: Bool) {
        guard canvasNavigationActive != active else { return }
        canvasNavigationActive = active
    }

    private func updateExportPreviewActive() {
        model.setExportPreviewActive(tab == .export && exportAuxPreviewEnabled && !canvasNavigationActive)
    }

    private func resetCanvasViewport() {
        setCanvasCamera(homeCanvasCamera)
    }

    private var currentCanvasCamera: CanvasCamera {
        // `CanvasCamera()` used to mean "the normalized 0...1 output frame".
        // In the larger world it should mean "home": a one-frame-tall camera
        // centered in the staging canvas. Treat the default value as that
        // migration/default state so launch is centered, not clamped to the
        // top-left-ish legal edge of a 16:9 viewport.
        canvasCamera == CanvasCamera() ? homeCanvasCamera : clamped(canvasCamera)
    }

    private var homeCanvasCamera: CanvasCamera {
        clamped(CanvasCamera(center: CGPoint(x: canvasWorldHeight * 0.5, y: canvasWorldHeight * 0.5), viewHeight: 1))
    }

    private var canvasWorldHeight: CGFloat {
        let outputHeight = max(1, model.outputFormat.size.height)
        return CGFloat(max(1, min(64, canvasPixelExtent / outputHeight)))
    }

    private var canvasDisplayZoom: CGFloat {
        1 / max(0.000_001, currentCanvasCamera.viewHeight)
    }

    private var canvasBrushSpace: CanvasBrushSpace {
        get { CanvasBrushSpace(rawValue: canvasBrushSpaceRaw) ?? .screen }
        nonmutating set { canvasBrushSpaceRaw = newValue.rawValue }
    }

    private func publishCanvasRenderContext() {
        model.canvasRenderContext = CanvasRenderContext(
            camera: currentCanvasCamera,
            worldPixelExtent: Int(canvasPixelExtent.rounded()),
            worldHeight: canvasWorldHeight,
            navigationActive: canvasNavigationActive,
            brushSpace: canvasBrushSpace
        )
    }

    private func setCanvasCamera(_ camera: CanvasCamera) {
        var next = camera
        next.rotation = 0
        canvasCamera = clamped(next)
    }

    private var canvasPixelExtentBinding: Binding<Double> {
        Binding(
            get: { canvasPixelExtent },
            set: {
                canvasPixelExtent = max(1024, min(65536, $0))
                setCanvasCamera(clamped(currentCanvasCamera))
            }
        )
    }

    private var canvasBackdropColor: Color {
        if model.settings.landmarks.inkPaperEnabled {
            let paper = model.settings.landmarks.inkPaperColor
            let alpha = max(0, min(1, Double(paper.alpha)))
            let r = Double(paper.red) * alpha + (1 - alpha)
            let g = Double(paper.green) * alpha + (1 - alpha)
            let b = Double(paper.blue) * alpha + (1 - alpha)
            return Color(red: r, green: g, blue: b)
        }
        if model.settings.backgroundMode == .solid {
            return rgbaColor(model.settings.backgroundColor)
        }
        return Color(nsColor: .textBackgroundColor)
    }

    private func fittedPreviewRect(container: CGSize, content: CGSize) -> CGRect {
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

    private func clamped(_ camera: CanvasCamera) -> CanvasCamera {
        var next = camera
        let world = canvasWorldHeight
        let aspect = outputAspect
        next.viewHeight = min(world, max(0.08, next.viewHeight))
        let marginX = min(world * 0.5, next.viewHeight * aspect * 0.5)
        let marginY = min(world * 0.5, next.viewHeight * 0.5)
        next.center.x = min(world - marginX, max(marginX, next.center.x))
        next.center.y = min(world - marginY, max(marginY, next.center.y))
        if world <= next.viewHeight || world <= next.viewHeight * aspect {
            next.center = CGPoint(x: world * 0.5, y: world * 0.5)
        }
        return next
    }

    private var outputAspect: CGFloat {
        max(0.000_001, model.outputFormat.size.width / max(1, model.outputFormat.size.height))
    }

    private func worldPoint(fromView point: CGPoint, container: CGSize, camera: CanvasCamera? = nil) -> CGPoint {
        let camera = camera ?? currentCanvasCamera
        let rect = fittedPreviewRect(container: container, content: model.outputFormat.size)
        let base = max(1, rect.height)
        return CGPoint(
            x: camera.center.x + (point.x - rect.midX) / base * camera.viewHeight,
            y: camera.center.y + (point.y - rect.midY) / base * camera.viewHeight
        )
    }

    @ViewBuilder private func canvasViewControls(includeMiniMap: Bool = true) -> some View {
        HStack(spacing: 8) {
            Button {
                resetCanvasViewport()
            } label: {
                Label("Reset view", systemImage: "scope")
            }
            Text("\(Int(canvasDisplayZoom * 100))%")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            Button("4K") { canvasPixelExtentBinding.wrappedValue = 4096 }
            Button("8K") { canvasPixelExtentBinding.wrappedValue = 8192 }
        }
        .controlSize(.small)
        .help("Pan with the trackpad or mouse wheel. Pinch, or Command-scroll, to zoom around the pointer. This changes only the working view; export and the virtual camera stay at the configured output frame.")

        SliderRow(title: "Canvas", value: canvasPixelExtentBinding, range: 1024...16384, precision: 0, defaultValue: 8192,
                  hint: "Square world canvas extent in pixels. The fixed output frame acts as a camera into this world.")
        Picker("Brush space", selection: Binding(
            get: { canvasBrushSpace },
            set: { canvasBrushSpace = $0 }
        )) {
            Text("Screen").tag(CanvasBrushSpace.screen)
            Text("World").tag(CanvasBrushSpace.world)
        }
        .pickerStyle(.segmented)
        .help("Screen keeps the brush the same apparent size while zooming. World makes the brush a fixed physical size on the paper.")
        Text("\(Int(canvasPixelExtent)) × \(Int(canvasPixelExtent)) px world · active viewport \(Int(model.outputFormat.size.width)) × \(Int(model.outputFormat.size.height)) px · \(canvasWorldHeight, specifier: "%.1f") viewport-heights tall")
            .font(.caption)
            .foregroundStyle(.secondary)

        if includeMiniMap {
            CanvasMiniMap(
                camera: Binding(
                    get: { currentCanvasCamera },
                    set: { setCanvasCamera($0) }
                ),
            worldHeight: canvasWorldHeight,
            aspect: outputAspect,
            paths: [],
            selectedPathID: nil
            )
            .frame(height: 150)
            .help("Whole-canvas navigator. The white rectangle is the fixed output viewport/camera; drag inside the minimap to move the working view.")
        }
    }

    // MARK: - Controls

    /// The tabs currently shown in the tab bar, in canonical order.
    private var visibleTabs: [ControlTab] {
        ControlTab.visibleTabs(from: visibleTabsRaw)
    }

    private func isTabVisible(_ t: ControlTab) -> Bool {
        visibleTabs.contains(t)
    }

    private func toggleTabVisible(_ t: ControlTab) {
        guard t != .export else { return }
        var ids = Set(visibleTabs.map { $0.id })
        if ids.contains(t.id) { ids.remove(t.id) } else { ids.insert(t.id) }
        guard !ids.isEmpty else { return }
        visibleTabsRaw = ControlTab.storageValue(for: Set(ControlTab.allCases.filter { ids.contains($0.id) }))
        if !isTabVisible(tab) { tab = visibleTabs.first ?? .layers }
    }

    private var controlsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            HStack(spacing: 8) {
                Picker("", selection: $tab) {
                    ForEach(visibleTabs) { tab in
                        Image(systemName: tab.icon)
                            .help(tab.rawValue)
                            .tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Menu {
                    Text("Show tabs")
                    Divider()
                    ForEach(ControlTab.allCases) { t in
                        Button {
                            toggleTabVisible(t)
                        } label: {
                            Label(
                                t.rawValue,
                                systemImage: isTabVisible(t) ? "checkmark" : ""
                            )
                        }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Choose which tabs to show")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .input: inputTab
                    case .camera: cameraTab
                    case .movie: movieTab
                    case .layers: layersTab
                    case .marks: marksTab
                    case .yarn: yarnTab
                    case .wrap: wrapTab
                    case .lineWalk: lineWalkTab
                    case .ink: inkTab
                    case .web: webTab
                    case .presets: presetsTab
                    case .keys: keysTab
                    case .debug: debugTab
                    case .export: exportTab
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 360)
    }

    private var actionBar: some View {
        Text("SketchCam").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isHeld: Bool {
        model.frameSource == .movie ? model.movieRate == 0 : model.inputFrozen
    }

    /// The canvas drawing surface normally follows the Ink inspector. The
    /// persistent option keeps it available while another inspector is open.
    private var inkCanvasInputActive: Bool {
        model.settings.landmarks.inkEnabled && (tab == .ink || inkDrawAcrossPanels)
    }

    private var freezeButtonTitle: String {
        if model.frameSource == .movie {
            return model.movieRate == 0 ? "Play" : "Pause"
        }
        return model.inputFrozen ? "Unfreeze" : "Freeze"
    }

    @ViewBuilder private var exportTab: some View {
        ExportPanel(
            exporter: model.exporter,
            proxyRecorder: model.inputProxyRecorder,
            live: model.live,
            liveDisplay: model.exportPreviewDisplay,
            usesMetalLivePreview: exportAuxPreviewEnabled && model.settings.useMetalPreview && model.settings.previewMode != .split,
            auxPreviewEnabled: $exportAuxPreviewEnabled,
            camera: Binding(
                get: { currentCanvasCamera },
                set: { setCanvasCamera($0) }
            ),
            worldHeight: canvasWorldHeight,
            outputAspect: model.outputFormat.size.width / max(1, model.outputFormat.size.height),
            paths: model.settings.landmarks.inkPaths,
            selectedPathID: selectedInkPathID,
            currentSize: model.outputFormat.size,
            currentFPS: Double(model.outputFormat.frameRate),
            metricLayers: exportMetricLayers,
            chooseDestination: model.chooseExportDestination,
            exportCurrent: model.exportCurrentFrame,
            startProxy: { model.inputProxyRecorder.start(size: model.outputFormat.size,
                                                         fps: model.exporter.configuration.captureFPS) }
        )
    }

    private var exportMetricLayers: [(id: UUID, name: String)] {
        let graph = (model.settings.layerGraph ?? .defaultGraph(from: model.settings)).reconciled(with: model.settings)
        let layers = graph.layers.compactMap { layer in
            graph.node(layer.node).map { ($0.id, $0.name) }
        }
        let fields = model.settings.resolvedControlFields.providers.map { ($0.id, "Field · \($0.name)") }
        return layers + fields
    }


    // MARK: - Camera tab

    @ViewBuilder private var cameraTab: some View {
        SectionHeader("Camera")
        Button {
            model.toggleFreezeOrPause()
        } label: {
            Label(freezeButtonTitle, systemImage: isHeld ? "play.fill" : "pause.fill")
        }
        .help("Freeze/unfreeze the camera input. For Movie input this becomes Pause/Play.")
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

        SectionHeader("Canvas view")
        canvasViewControls()

        SectionHeader("Frame")
        Toggle("Mirror", isOn: $model.settings.mirror)
            .help("Mirror the source (selfie view). For a creative per-layer flip, add a Mirror effect to a layer instead.")
        Toggle("Test pattern", isOn: $model.settings.testPatternMode)
    }

    // MARK: - Movie tab

    @ViewBuilder private var movieTab: some View {
        SectionHeader("Movie")
        HStack {
            Button("Open Movie…") { model.frameSource = .movie; model.openMoviePanel() }
            Button("Demo clip") { model.frameSource = .movie; model.loadDemoClip() }
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
                .disabled(movieURLField.isEmpty)
        }
        SliderRow(title: "Speed", value: $model.movieRate, range: 0...2, defaultValue: 1, hint: "0 pauses")
    }

    @ViewBuilder private var inputTab: some View {
        SectionHeader("Output")
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

        SectionHeader("Canvas")
        canvasViewControls(includeMiniMap: false)

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

        Button {
            appUI.toggleDebugOverlay()
        } label: {
            Label("Performance overlay", systemImage: appUI.debugOverlayVisible
                  ? "chart.line.uptrend.xyaxis.circle.fill" : "chart.line.uptrend.xyaxis.circle")
        }
        .help("Toggle the performance overlay (Control-Option-P).")

        SectionHeader("Window")
        HStack {
            Toggle("Panel", isOn: $windowMode.panelVisible)
            Toggle("Decoration", isOn: $windowMode.decorated)
        }
        .toggleStyle(.checkbox)
        HStack {
            Toggle("Transparent", isOn: $windowMode.transparent)
            Toggle("On top", isOn: $windowMode.alwaysOnTop)
        }
        .toggleStyle(.checkbox)
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
        LayerStackEditor(model: model)
            .help("Reorder, show/hide, and set opacity for the composited layers. Drawing (marks + algorithms) is one layer for now; per-algorithm layers are coming.")
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

    @ViewBuilder private var inkTab: some View {
        Toggle("Enable Ink", isOn: $model.settings.landmarks.inkEnabled)
            .font(.headline)
            .help("Draw inkwash strokes as a full-canvas layer directly on the preview.")
        Toggle("Draw on canvas in every panel", isOn: $inkDrawAcrossPanels)
            .help("Keep the full-canvas Ink drawing surface active while Export, Layers, Camera, or another panel is selected. Panel controls still receive their own clicks.")
        Group {
            SectionHeader("Paper")
            HStack(spacing: 6) {
                Text("Input").font(.caption).foregroundStyle(.secondary)
                Menu(inkPaperInputLabel) {
                    Button("Internal paper") { inkTextureBinding.wrappedValue = .none }
                    let sources = inkTextureSources()
                    if !sources.isEmpty {
                        Divider()
                        ForEach(sources, id: \.id) { source in
                            Button(source.name) { inkTextureBinding.wrappedValue = .node(source.id) }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Substrate routed into the Ink node's texture input. This is the same input shown in the Layers panel.")
            }
            Toggle("Paper", isOn: inkPaperEnabledBinding)
                .help("Show or hide the Ink layer's paper/substrate. Off makes ink render over transparent.")
            SliderRow(title: "Opacity", value: inkPaperOpacityBinding, defaultValue: 1,
                      hint: "Opacity of the routed or internal paper substrate. 0 = transparent ink-only output.")
            if inkTextureBinding.wrappedValue != .none {
                Picker("Paper blend", selection: inkPaperCompositeBinding) {
                    ForEach(InkPaperCompositeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.menu)
            }
            DisclosureGroup("Paper settings", isExpanded: $inkPaperSettingsExpanded) {
                PaperControls(config: inkPaperConfigBinding)
                    .padding(.top, 4)
            }
            .disabled(inkPaperOpacityBinding.wrappedValue <= 0.001)

            DisclosureGroup("Ink response") {
                SliderRow(title: "Paper influence", value: optionalLandmarkFloatBinding(\.inkPaperInfluence, defaultValue: 0), range: 0...1, defaultValue: 0,
                          hint: "Master coupling from the paper's hidden material map into the ink simulation. 0 = paper is visual only; 1 = full absorbency, drag, and fresh-ink resistance.")
                SliderRow(title: "Live surface", value: optionalLandmarkFloatBinding(\.inkLiveSurfaceInfluence, defaultValue: 0), range: 0...1, defaultValue: 0,
                          hint: "Couples the routed moving image to absorbency, drag, and resistance. This is a changing scalar mask; it does not provide motion direction.")
                SliderRow(title: "Motion force", value: optionalLandmarkFloatBinding(\.inkMotionForce, defaultValue: 0), range: 0...2, defaultValue: 0,
                          hint: "Strength of the routed optical-flow vector pushing wet ink. It can move only pixels that are wet.")
                SliderRow(title: "Motion wetness", value: optionalLandmarkFloatBinding(\.inkMotionWetness, defaultValue: 0), range: 0...1, defaultValue: 0,
                          hint: "Continuously wets pixels where optical flow is detected, allowing that motion to carry pigment.")
                SliderRow(title: "Live absorbency", value: optionalLandmarkFloatBinding(\.inkLiveAbsorbency, defaultValue: 0), range: 0...1, defaultValue: 0,
                          hint: "How strongly the routed live-surface mask accelerates wetting and drying locally.")
                SliderRow(title: "Live drag", value: optionalLandmarkFloatBinding(\.inkLiveDrag, defaultValue: 0.5), range: 0...2, defaultValue: 0.5,
                          hint: "How strongly the routed live-surface mask brakes fluid and pigment movement locally.")
                SliderRow(title: "Live resist", value: optionalLandmarkFloatBinding(\.inkLiveResist, defaultValue: 1), range: 0...1, defaultValue: 1,
                          hint: "How strongly the routed live-surface mask rejects newly deposited pigment. It does not erase existing ink.")
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

            SectionHeader("Editor")
            Text("Path editing is paused for the fixed-viewport world canvas recovery. Legacy paths are preserved in settings but hidden until the world-path layer is redesigned.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Tool", selection: Binding(get: { InkTool.draw }, set: { _ in inkTool = .draw })) {
                Label("Draw", systemImage: InkTool.draw.icon).tag(InkTool.draw)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack {
                Button {
                    clearInk()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Fade the canvas out (over Fade) then wipe it — committed paths, immediate marks, and fixed ink.")
                Button {
                    deleteSelectedInk()
                } label: {
                    Label("Delete", systemImage: "delete.left")
                }
                .disabled(true)
                Button {
                    rerenderInk()
                } label: {
                    Label("Rerender", systemImage: "arrow.clockwise")
                }
                .disabled(true)
                .help("Path rerender is disabled while the world canvas foundation is being recovered.")
                Text("\(model.settings.landmarks.inkPaths.count) paths")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            Toggle("Show live cursor path", isOn: $model.settings.landmarks.inkShowLivePath)
                .help("Thin dashed guide tracking the cursor while the rendered ink catches up. Off by default.")
            SliderRow(title: "Smooth", value: floatBinding(\.landmarks.inkSmoothing), defaultValue: 0.5,
                      hint: "Rounds the stroke as you draw — higher = smoother/laggier. Hold Shift while drawing for extra smoothing.")

            SectionHeader("Pen / Wash")
            Picker("Mode", selection: inkModeBinding) {
                ForEach(InkBrushMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            .help("Pen lays a stroke of ink; Wash uses a wet brush to push, smear and blend the ink in the velocity field.")
            // Ink + Wash colours on one row; the checkbox next to each toggles
            // "save stroke" for that tool (off = immediate: paints straight onto
            // the canvas without recording an editable path).
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    RGBAColorPicker("Ink", rgba: inkColorRGBA, supportsOpacity: true)
                    colorResetButton("Reset ink color") { model.settings.landmarks.inkColor = .ink }
                    Toggle("", isOn: savePenStrokeBinding)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help("Save pen stroke as an editable path. Off = immediate (paints straight onto the canvas, not recorded).")
                }
                Spacer(minLength: 6)
                HStack(spacing: 6) {
                    RGBAColorPicker("Wash", rgba: inkWashColorRGBA, supportsOpacity: true)
                    colorResetButton("Reset wash color") { model.settings.landmarks.inkWashColor = RGBAColor(red: 0.84, green: 0.85, blue: 0.89) }
                    Toggle("", isOn: saveWashStrokeBinding)
                        .labelsHidden()
                        .toggleStyle(.checkbox)
                        .help("Save wash stroke as an editable path. Off = immediate.")
                }
            }
            Picker("Ink", selection: inkKindBinding) {
                ForEach(InkKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            .help("Color = chromatic ink that uses the Ink colour. Dissolve = opaque white pigment that covers / erases (a Dissolve wash clears to paper).")
            Picker("Brush space", selection: Binding(
                get: { canvasBrushSpace },
                set: { canvasBrushSpace = $0 }
            )) {
                Text("Screen").tag(CanvasBrushSpace.screen)
                Text("World").tag(CanvasBrushSpace.world)
            }
            .pickerStyle(.segmented)
            .help("Screen keeps the brush the same apparent size while zooming. World measures Pen and Wash size in pixels on the large paper/world backing store.")
            SliderRow(title: "Pen size", value: inkSizeBinding, range: inkBrushSizeRange,
                      precision: inkBrushSizePrecision, defaultValue: inkBrushDefaultSize,
                      hint: inkBrushSizeHint(kind: "Pen"))
            SliderRow(title: "Wash size", value: inkWashSizeBinding, range: inkBrushSizeRange,
                      precision: inkBrushSizePrecision, defaultValue: inkBrushDefaultSize,
                      hint: inkBrushSizeHint(kind: "Wash"))
            SliderRow(title: "Smear", value: floatBinding(\.landmarks.inkSmearStrength), defaultValue: 0.5,
                      hint: "Wash smear dial, subtle → dramatic. Low = needs a deliberate move and pushes gently (fine control); high = the slightest motion smears hard. Also sets how strongly the wash re-mobilizes dried ink.")
            SliderRow(title: "Flow", value: floatBinding(\.landmarks.inkFlow), defaultValue: 0.9,
                      hint: "Fluid energy — higher = livelier, longer-lived motion, more swirl and bleed; lower = calmer, stays where you put it.")
            SliderRow(title: "Bleed", value: floatBinding(\.landmarks.inkBleed), defaultValue: 0.8,
                      hint: "Diffusion into the paper. 0 = pigment is only pushed around, conserved (acrylic-like); high = watery, dissolves and spreads. (Editable below 0 for an anti-diffuse/sharpening experiment.)")
            SliderRow(title: "Dry", value: floatBinding(\.landmarks.inkDry), defaultValue: 0.25,
                      hint: "How quickly strokes dry and fix into the paper. 0 = stays wet and spreadable indefinitely; high = sets fast.")
            SliderRow(title: "Wet decay", value: optionalLandmarkFloatBinding(\.inkWetnessDecay, defaultValue: 1), range: 0...2, defaultValue: 1,
                      hint: "Direct wetness evaporation multiplier. 0 = wetness does not decay; 1 = normal Dry/Fade behavior; above 1 evaporates faster.")
            SliderRow(title: "Fade", value: optionalLandmarkFloatBinding(\.inkFadeDuration, defaultValue: 1.2), range: 0.2...5, precision: 1, defaultValue: 1.2,
                      hint: "Seconds the ink takes to settle after you release a wash, and to fade out on Clear (C). Longer = the wash keeps softly drifting and settling, and Clear dissolves away gradually — nice for live performance.")
            SliderRow(title: "Color", value: inkColorSeparationBinding, defaultValue: 0.5,
                      hint: "Chromatic separation — splits the ink into colour fringes as it bleeds.")
            SliderRow(title: "Brush ink", value: inkBrushInkBinding, defaultValue: 0,
                      hint: "How much fresh pigment the wash brush itself lays down as it moves (0 = pure water/smear, no new ink).")
            Picker("Curve", selection: $model.settings.landmarks.inkCurveFit) {
                ForEach(CurveFit.allCases) { fit in Text(fit.title).tag(fit) }
            }
            .pickerStyle(.segmented)
            .help("How recorded paths are fitted between sampled points: Polyline (straight), Spline / Hobby (smooth curves), Bezier.")
            seedRow(\.landmarks.inkSeed)

        }
        .disabled(!model.settings.landmarks.inkEnabled)
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
        model.clearCanvasActions()
        setInkPaths([])
        // Fade the canvas out over the Fade duration, then wipe — the engine
        // fades the live-baked + committed ink (incl. immediate-mode marks) and
        // clears the textures when the fade completes.
        model.settings.landmarks.inkClearFadeRevision = (model.settings.landmarks.inkClearFadeRevision ?? 0) + 1
        clearInkSelection()
    }

    private func fixInk() {
        model.settings.landmarks.inkFixRevision = (model.settings.landmarks.inkFixRevision ?? 0) + 1
        model.recordPerformanceCommand(.fix)
    }

    private func unfixInk() {
        model.settings.landmarks.inkUnfixRevision = (model.settings.landmarks.inkUnfixRevision ?? 0) + 1
        model.recordPerformanceCommand(.unfix)
    }

    private func wetInkCanvas() {
        model.settings.landmarks.inkWetCanvasRevision = (model.settings.landmarks.inkWetCanvasRevision ?? 0) + 1
        model.recordPerformanceCommand(.wetCanvas)
    }

    private func dryInkCanvas() {
        model.settings.landmarks.inkDryCanvasRevision = (model.settings.landmarks.inkDryCanvasRevision ?? 0) + 1
        model.recordPerformanceCommand(.dryCanvas)
    }

    private func rerenderInk() {
        model.cancelInkLiveStroke()
        clearInkSelection()
        model.settings.landmarks.inkRebuildRevision += 1
    }

    private func toggleInkMode() {
        model.settings.landmarks.inkBrushMode = currentInkMode.toggled
    }

    private func toggleInkKind() {
        model.settings.landmarks.inkKind = currentInkKind.toggled
    }

    private func toggleImmediatePen() {
        model.settings.landmarks.inkImmediatePen.toggle()
    }

    private func toggleImmediateWash() {
        model.settings.landmarks.inkImmediateWash.toggle()
    }

    private func adjustInkWidth(by delta: Float) {
        model.settings.landmarks.inkWidth = clampedInkBrushSize(model.settings.landmarks.inkWidth + inkBrushKeyboardDelta(delta))
    }

    private func adjustInkWashWidth(by delta: Float) {
        let v = (model.settings.landmarks.inkWashWidth ?? 0.5) + inkBrushKeyboardDelta(delta)
        model.settings.landmarks.inkWashWidth = clampedInkBrushSize(v)
    }

    private func adjustInkBrushInk(by delta: Float) {
        let v = (model.settings.landmarks.inkBrushInk ?? 0) + delta
        model.settings.landmarks.inkBrushInk = min(1, max(0, v))
    }

    private func undoInk() {
        guard let action = model.undoCanvasAction() else { return }
        if action.isEditable {
            model.settings.landmarks.inkPaths.removeAll { $0.id == action.id }
        }
        clearInkSelection()
    }

    private func redoInk() {
        guard let action = model.redoCanvasAction() else { return }
        if action.isEditable, !model.settings.landmarks.inkPaths.contains(where: { $0.id == action.id }) {
            model.settings.landmarks.inkPaths.append(action.path)
        }
        clearInkSelection()
    }

    private func setInkPaths(_ paths: [InkEditorPath]) {
        model.cancelInkLiveStroke()
        let old = model.settings.landmarks.inkPaths
        guard old != paths else { return }
        model.settings.landmarks.inkPaths = paths
        model.replaceEditableCanvasPaths(paths)
    }

    private var currentInkMode: InkBrushMode {
        model.settings.landmarks.inkBrushMode ?? .pen
    }

    private var currentInkKind: InkKind {
        model.settings.landmarks.inkKind ?? .black
    }

    private var inkPathsBinding: Binding<[InkEditorPath]> {
        Binding(
            get: { model.settings.landmarks.inkPaths },
            set: { setInkPaths($0) }
        )
    }

    private var inkModeBinding: Binding<InkBrushMode> {
        Binding(
            get: { currentInkMode },
            set: { model.settings.landmarks.inkBrushMode = $0 }
        )
    }

    private var inkKindBinding: Binding<InkKind> {
        Binding(
            get: { currentInkKind },
            set: { model.settings.landmarks.inkKind = $0 }
        )
    }

    private var inkSizeBinding: Binding<Double> {
        Binding(
            get: { Double(clampedInkBrushSize(model.settings.landmarks.inkWidth)) },
            set: { model.settings.landmarks.inkWidth = clampedInkBrushSize(Float($0)) }
        )
    }

    private var inkWashSizeBinding: Binding<Double> {
        Binding(
            get: { Double(clampedInkBrushSize(model.settings.landmarks.inkWashWidth ?? 0.5)) },
            set: { model.settings.landmarks.inkWashWidth = clampedInkBrushSize(Float($0)) }
        )
    }

    private var inkBrushSizeRange: ClosedRange<Double> {
        canvasBrushSpace == .world ? 1...128 : 0...2
    }

    private var inkBrushDefaultSize: Double {
        canvasBrushSpace == .world ? 6 : 0.5
    }

    private var inkBrushSizePrecision: Int {
        canvasBrushSpace == .world ? 0 : 3
    }

    private func inkBrushSizeHint(kind: String) -> String {
        if canvasBrushSpace == .world {
            return "\(kind) size in pixels on the large world canvas. 1 is one world pixel; larger values stay fixed to the paper as you zoom. Default 6 is tuned for the initial HD viewport."
        }
        return "\(kind) size in screen/viewport space. This is an abstract HD-calibrated apparent-size scale, not pixels; 0 is a subpixel hairline, 0.5 is a thin default, and the brush keeps roughly the same apparent size while zooming."
    }

    private func clampedInkBrushSize(_ value: Float) -> Float {
        let range = inkBrushSizeRange
        return Float(min(range.upperBound, max(range.lowerBound, Double(value))))
    }

    private func inkBrushKeyboardDelta(_ delta: Float) -> Float {
        canvasBrushSpace == .world ? (delta >= 0 ? 1 : -1) : delta
    }

    private var inkColorSeparationBinding: Binding<Double> {
        optionalLandmarkFloatBinding(\.inkColorSeparation, defaultValue: 0.5)
    }

    private var inkBrushInkBinding: Binding<Double> {
        optionalLandmarkFloatBinding(\.inkBrushInk, defaultValue: 0)
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
        Binding(get: { model.settings.landmarks.inkColor },
                set: { model.settings.landmarks.inkColor = $0 })
    }
    private var inkWashColorRGBA: Binding<RGBAColor> {
        Binding(get: { model.settings.landmarks.inkWashColor ?? RGBAColor(red: 0.84, green: 0.85, blue: 0.89) },
                set: { model.settings.landmarks.inkWashColor = $0 })
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
            get: { model.settings.landmarks.inkPaperCompositeMode ?? .multiply },
            set: { model.settings.landmarks.inkPaperCompositeMode = $0 }
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
    private var inkTextureBinding: Binding<PortBinding> {
        Binding(
            get: {
                let graph = (model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)).reconciled(with: model.settings)
                guard let inkNode = graph.nodes.first(where: { $0.kind.family == "ink" }),
                      let textureIndex = inkNode.kind.ports.firstIndex(where: { $0.name == "texture" }),
                      inkNode.inputs.indices.contains(textureIndex) else { return .none }
                return inkNode.inputs[textureIndex]
            },
            set: { newValue in
                var graph = (model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)).reconciled(with: model.settings)
                guard let nodeIndex = graph.nodes.firstIndex(where: { $0.kind.family == "ink" }),
                      let textureIndex = graph.nodes[nodeIndex].kind.ports.firstIndex(where: { $0.name == "texture" }),
                      graph.nodes[nodeIndex].inputs.indices.contains(textureIndex) else { return }
                graph.nodes[nodeIndex].inputs[textureIndex] = newValue
                guard (try? graph.validate()) != nil else { return }
                model.settings.layerGraph = graph
                model.settings.useLayerGraph = true
            }
        )
    }
    private var inkPaperInputLabel: String {
        switch inkTextureBinding.wrappedValue {
        case .none:
            return "Internal paper"
        case .source(let source):
            return source == .personMatte ? "Person Key" : "Source"
        case .node(let id):
            return inkTextureSources().first { $0.id == id }?.name ?? "Layer"
        }
    }
    private func inkTextureSources() -> [(id: UUID, name: String)] {
        let graph = (model.settings.layerGraph ?? LayerGraph.defaultGraph(from: model.settings)).reconciled(with: model.settings)
        guard let inkNode = graph.nodes.first(where: { $0.kind.family == "ink" }) else { return [] }
        return graph.layers.compactMap { layer in
            guard layer.node != inkNode.id, let node = graph.node(layer.node), node.kind.output == .pixel else { return nil }
            return (id: node.id, name: node.name)
        }
    }
    // "Save stroke" = the inverse of immediate mode (off = immediate).
    private var savePenStrokeBinding: Binding<Bool> {
        Binding(get: { !model.settings.landmarks.inkImmediatePen },
                set: { model.settings.landmarks.inkImmediatePen = !$0 })
    }
    private var saveWashStrokeBinding: Binding<Bool> {
        Binding(get: { !model.settings.landmarks.inkImmediateWash },
                set: { model.settings.landmarks.inkImmediateWash = !$0 })
    }

    private var inkWashColorBinding: Binding<Color> {
        Binding(
            get: {
                let c = model.settings.landmarks.inkWashColor ?? RGBAColor(red: 0.84, green: 0.85, blue: 0.89)
                return Color(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue), opacity: Double(c.alpha))
            },
            set: { newValue in
                guard let converted = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                model.settings.landmarks.inkWashColor = RGBAColor(
                    red: Float(converted.redComponent),
                    green: Float(converted.greenComponent),
                    blue: Float(converted.blueComponent),
                    alpha: Float(converted.alphaComponent)
                )
            }
        )
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
        model.replaceEditableCanvasPaths(model.settings.landmarks.inkPaths)
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
        r.register(id: "export.captureNext", title: "Capture Next Frame", category: "Export",
                   default: KeyBinding(key: "e", modifiers: [.command, .shift])) { [weak model] in
            model?.exporter.captureNext()
        }
        r.register(id: "window.panel", title: "Toggle Side Panel (fit canvas)", category: "Window",
                   default: KeyBinding(key: "u", modifiers: [.command, .option])) { [weak windowMode] in windowMode?.togglePanelFit() }
        r.register(id: "window.panelOverlay", title: "Toggle Side Panel (overlay)", category: "Window",
                   default: KeyBinding(key: "u", modifiers: [.shift, .option])) { [weak windowMode] in windowMode?.togglePanelOverlay() }
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
}

// MARK: - Components

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title.uppercased())
            .font(.caption)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
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

            DisclosureGroup("Material map", isExpanded: $physicalExpanded) {
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

private struct LayerStackEditor: View {
    @ObservedObject var model: SketchCamViewModel
    @State private var expanded: Set<UUID> = []
    @State private var editingLayer: UUID?
    @State private var editText: String = ""
    @FocusState private var nameFieldFocused: Bool
    private static let availableBlendModes: [SketchCamCore.BlendMode] = [
        .normal, .multiply, .screen, .add, .overlay, .darken, .lighten, .difference, .subtract, .softLight
    ]

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
            ForEach(Array(displayLayers.enumerated()), id: \.element.id) { display, layer in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Button { toggleVisible(layer.id) } label: {
                            Image(systemName: layer.visible ? "eye" : "eye.slash")
                        }
                        .buttonStyle(.borderless)
                        .help(layer.visible ? "Hide layer" : "Show layer")
                        if let color = solidColor(layer) {
                            ColorPicker("", selection: color, supportsOpacity: false).labelsHidden()
                        }
                        if editingLayer == layer.id {
                            TextField("", text: $editText)
                                .textFieldStyle(.roundedBorder).frame(width: 80)
                                .focused($nameFieldFocused)
                                .onSubmit { commitRename(layer.id) }
                        } else {
                            Text(displayName(layer)).frame(width: 64, alignment: .leading)
                                .help("Double-click to rename. The name lets other streams reference this layer as a source.")
                                .onTapGesture(count: 2) {
                                    editText = displayName(layer)
                                    editingLayer = layer.id
                                    DispatchQueue.main.async { nameFieldFocused = true }
                                }
                        }
                        Slider(value: opacity(layer.id), in: 0...1).controlSize(.small)
                            .help("Layer opacity")
                        Menu(layer.blend.title) {
                            ForEach(Self.availableBlendModes, id: \.self) { blend in
                                Button(blend.title) { setBlend(layer.id, blend) }
                            }
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 78, alignment: .leading)
                        .help("Layer blend mode")
                        Button { toggleExpanded(layer.id) } label: {
                            Image(systemName: expanded.contains(layer.id) ? "chevron.down.circle.fill" : "chevron.down.circle")
                            if layer.effects.isEmpty == false {
                                Text("\(layer.effects.count)").font(.caption2)
                            }
                        }
                        .buttonStyle(.borderless)
                        .help("Effect chain for this layer")
                        Button { move(layer.id, towardTop: true) } label: { Image(systemName: "chevron.up") }
                            .buttonStyle(.borderless).disabled(display == 0)
                        Button { move(layer.id, towardTop: false) } label: { Image(systemName: "chevron.down") }
                            .buttonStyle(.borderless).disabled(display == displayLayers.count - 1)
                        Button(role: .destructive) { delete(layer.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Delete layer")
                    }
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
            }
            Section("Streams") {
                Button("Drawing") { addStream(.drawing) }
                    .disabled(streamPresent(.drawing))
                Button("Ink") { addStream(.ink) }
                    .disabled(streamPresent(.ink))
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
        let node = Node(name: name, kind: kind, managed: false)
        mutate { g in
            g.nodes.append(node)
            g.layers.append(Layer(node: node.id))
        }
    }

    private func addSolid() {
        let node = Node(name: "Solid", kind: .solid(SolidConfig(color: RGBAColor(red: 0.85, green: 0.3, blue: 0.3, alpha: 1))), managed: false)
        mutate { g in
            g.nodes.append(node)
            g.layers.append(Layer(node: node.id))   // top of the stack
        }
    }

    private func addPaper() {
        let node = Node(name: "Paper", kind: .paper(PaperConfig()), managed: false)
        mutate { g in
            g.nodes.append(node)
            g.layers.append(Layer(node: node.id))
        }
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

    /// towardTop = toward the visual top = later in the bottom→top array.
    private func move(_ id: UUID, towardTop: Bool) {
        mutate { g in
            guard let i = g.layers.firstIndex(where: { $0.id == id }) else { return }
            let j = towardTop ? i + 1 : i - 1
            guard g.layers.indices.contains(j) else { return }
            g.layers.swapAt(i, j)
        }
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var precision: Int = 2
    let defaultValue: Double
    var hint: String?
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 64, alignment: .leading)
                .contentShape(Rectangle())
                // Double-click the label to reset this parameter to its default.
                .onTapGesture(count: 2) { value = defaultValue }
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
        .contentShape(Rectangle())
        .help("\(hint ?? title) Double-click the label to restore the default; type an exact value in the number field and press Return.")
    }
}

private struct InkBottomHUD: View {
    @Binding var mode: InkBrushMode
    @Binding var inkKind: InkKind
    @Binding var inkColor: Color
    @Binding var size: Double
    @Binding var flow: Double
    @Binding var bleed: Double
    @Binding var dry: Double
    @Binding var colorSeparation: Double
    @Binding var brushInk: Double
    let fix: () -> Void
    let clear: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 22) {
                buttonControl("mode", value: mode.title) { mode = mode.toggled }
                buttonControl("ink", value: inkKind.rawValue) { inkKind = inkKind.toggled }
                VStack(spacing: 7) {
                    Text("hue")
                        .hudLabel()
                    ColorPicker("", selection: $inkColor, supportsOpacity: false)
                        .labelsHidden()
                        .frame(width: 22, height: 22)
                }
                hudSlider("size", value: $size, defaultValue: 0.5)
                hudSlider("flow", value: $flow, defaultValue: 0.9)
                hudSlider("bleed", value: $bleed, defaultValue: 0.8)
                hudSlider("dry", value: $dry, defaultValue: 0.25)
                hudSlider("color", value: $colorSeparation, defaultValue: 0.5)
                hudSlider("brush ink", value: $brushInk, defaultValue: 0)
                command("fix", action: fix)
                command("clear", action: clear)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.10)))
        .controlSize(.small)
    }

    private func buttonControl(_ label: String, value: String, action: @escaping () -> Void) -> some View {
        VStack(spacing: 7) {
            Text(label)
                .hudLabel()
            Button(value, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .tracking(3)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .frame(minWidth: 58)
        }
    }

    private func hudSlider(_ label: String, value: Binding<Double>, defaultValue: Double) -> some View {
        VStack(spacing: 7) {
            Text(label)
                .hudLabel()
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
            Slider(value: value, in: 0...1)
                .frame(width: 86)
        }
    }

    private func command(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .tracking(3)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .padding(.bottom, 1)
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

private struct CanvasMiniMap: View {
    @Binding var camera: CanvasCamera
    let worldHeight: CGFloat
    let aspect: CGFloat
    let paths: [InkEditorPath]
    let selectedPathID: UUID?

    var body: some View {
        GeometryReader { geo in
            let rect = mapRect(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.16))
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                Canvas { context, _ in
                    var world = Path()
                    world.addRect(rect)
                    context.fill(world, with: .color(Color(nsColor: .textBackgroundColor).opacity(0.09)))

                    for path in paths {
                        guard let first = path.points.first else { continue }
                        var p = Path()
                        p.move(to: viewPoint(first, in: rect))
                        for point in path.points.dropFirst() {
                            p.addLine(to: viewPoint(point, in: rect))
                        }
                        let selected = path.id == selectedPathID
                        context.stroke(
                            p,
                            with: .color(selected ? Color.accentColor.opacity(0.95) : Color.white.opacity(0.42)),
                            style: StrokeStyle(lineWidth: selected ? 2 : 1.2, lineCap: .round, lineJoin: .round)
                        )
                    }

                    var frame = Path()
                    frame.addRect(viewportRect(in: rect))
                    context.stroke(frame, with: .color(.white.opacity(0.92)), style: StrokeStyle(lineWidth: 1.4, dash: [5, 3]))

                    var guardFrame = Path()
                    guardFrame.addRect(guardRect(in: rect))
                    context.stroke(guardFrame, with: .color(.white.opacity(0.25)), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                }
                VStack {
                    HStack {
                        Text("Whole canvas")
                        Spacer()
                        Text("\(Int(1 / max(0.000_001, camera.viewHeight) * 100))%")
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    Spacer()
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard rect.contains(value.location) else { return }
                        var next = camera
                        next.center = worldPoint(value.location, in: rect)
                        camera = clamped(next)
                    }
            )
        }
    }

    private func mapRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 12
        let side = max(1, min(size.width, size.height) - inset * 2)
        return CGRect(
            x: (size.width - side) * 0.5,
            y: (size.height - side) * 0.5,
            width: side,
            height: side
        )
    }

    private func viewPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let maxCoord = max(1, worldHeight)
        return CGPoint(
            x: rect.minX + point.x / maxCoord * rect.width,
            y: rect.minY + point.y / maxCoord * rect.height
        )
    }

    private func worldPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let maxCoord = max(1, worldHeight)
        return CGPoint(
            x: min(maxCoord, max(0, (point.x - rect.minX) / max(1, rect.width) * maxCoord)),
            y: min(maxCoord, max(0, (point.y - rect.minY) / max(1, rect.height) * maxCoord))
        )
    }

    private func viewportRect(in rect: CGRect) -> CGRect {
        let maxCoord = max(1, worldHeight)
        let viewHeight = min(maxCoord, max(0.08, camera.viewHeight))
        let viewWidth = min(maxCoord, viewHeight * max(0.000_001, aspect))
        return CGRect(
            x: rect.minX + (camera.center.x - viewWidth * 0.5) / maxCoord * rect.width,
            y: rect.minY + (camera.center.y - viewHeight * 0.5) / maxCoord * rect.height,
            width: viewWidth / maxCoord * rect.width,
            height: viewHeight / maxCoord * rect.height
        )
    }

    private func guardRect(in rect: CGRect) -> CGRect {
        viewportRect(in: rect).insetBy(
            dx: -rect.width * camera.guardFraction * camera.viewHeight / max(1, worldHeight),
            dy: -rect.height * camera.guardFraction * camera.viewHeight / max(1, worldHeight)
        )
    }

    private func clamped(_ camera: CanvasCamera) -> CanvasCamera {
        let maxCoord = max(1, worldHeight)
        let aspect = max(0.000_001, aspect)
        var next = camera
        next.rotation = 0
        next.viewHeight = min(maxCoord, max(0.08, next.viewHeight))
        let marginX = min(maxCoord * 0.5, next.viewHeight * aspect * 0.5)
        let marginY = min(maxCoord * 0.5, next.viewHeight * 0.5)
        next.center.x = min(maxCoord - marginX, max(marginX, next.center.x))
        next.center.y = min(maxCoord - marginY, max(marginY, next.center.y))
        if maxCoord <= next.viewHeight || maxCoord <= next.viewHeight * aspect {
            next.center = CGPoint(x: maxCoord * 0.5, y: maxCoord * 0.5)
        }
        return next
    }
}

private struct CanvasWorldSurface: View {
    let fill: Color
    let visible: Bool

    var body: some View {
        if visible {
            ZStack {
                Rectangle()
                    .fill(fill)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [.white.opacity(0.035), .black.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Rectangle()
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
        }
    }
}

private struct PreviewNavigationEventOverlay: NSViewRepresentable {
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    var onNavigationActive: (Bool) -> Void
    var plainDragPans: Bool

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.onPan = onPan
        view.onZoom = onZoom
        view.onNavigationActive = onNavigationActive
        view.plainDragPans = plainDragPans
        return view
    }

    func updateNSView(_ nsView: EventView, context: Context) {
        nsView.onPan = onPan
        nsView.onZoom = onZoom
        nsView.onNavigationActive = onNavigationActive
        nsView.plainDragPans = plainDragPans
    }

    final class EventView: NSView {
        var onPan: ((CGSize) -> Void)?
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        var onNavigationActive: ((Bool) -> Void)?
        var plainDragPans = false
        private var lastDragLocation: CGPoint?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private static var spaceKeyDown: Bool {
            CGEventSource.keyState(.combinedSessionState, key: 49)
        }

        override func scrollWheel(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
                onNavigationActive?(true)
                onZoom?(exp(CGFloat(dy) * 0.01), point)
                onNavigationActive?(false)
            } else {
                onNavigationActive?(true)
                onPan?(CGSize(width: dx, height: dy))
                onNavigationActive?(false)
            }
        }

        override func magnify(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onNavigationActive?(true)
            onZoom?(max(0.05, 1 + event.magnification), point)
            onNavigationActive?(false)
        }

        override func mouseDown(with event: NSEvent) {
            guard plainDragPans || Self.spaceKeyDown else {
                lastDragLocation = nil
                return
            }
            lastDragLocation = convert(event.locationInWindow, from: nil)
            onNavigationActive?(true)
        }

        override func mouseDragged(with event: NSEvent) {
            guard plainDragPans || Self.spaceKeyDown else { return }
            let point = convert(event.locationInWindow, from: nil)
            if let lastDragLocation {
                onPan?(CGSize(width: point.x - lastDragLocation.x, height: point.y - lastDragLocation.y))
            }
            lastDragLocation = point
        }

        override func mouseUp(with event: NSEvent) {
            lastDragLocation = nil
            onNavigationActive?(false)
        }
    }
}

private struct InkCanvasEventOverlay: NSViewRepresentable {
    var onChanged: (InkCanvasDragValue) -> Void
    var onEnded: (Bool) -> Void
    var onScroll: (CGSize) -> Void
    var onMagnify: (CGFloat, CGPoint) -> Void
    var onNavigationActive: (Bool) -> Void

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
        view.onScroll = onScroll
        view.onMagnify = onMagnify
        view.onNavigationActive = onNavigationActive
        return view
    }

    func updateNSView(_ nsView: EventView, context: Context) {
        nsView.onChanged = onChanged
        nsView.onEnded = onEnded
        nsView.onScroll = onScroll
        nsView.onMagnify = onMagnify
        nsView.onNavigationActive = onNavigationActive
    }

    final class EventView: NSView {
        var onChanged: ((InkCanvasDragValue) -> Void)?
        var onEnded: ((Bool) -> Void)?
        var onScroll: ((CGSize) -> Void)?
        var onMagnify: ((CGFloat, CGPoint) -> Void)?
        var onNavigationActive: ((Bool) -> Void)?
        private var startLocation: CGPoint?
        private var secondaryDrag = false
        private var navigationDrag = false
        private var lastNavigationLocation: CGPoint?
        private var downTimestamp: TimeInterval = 0
        private var dragCharge: Float = 0
        private var chargeLocked = false

        override var isFlipped: Bool { true }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private static var spaceKeyDown: Bool {
            CGEventSource.keyState(.combinedSessionState, key: 49)
        }

        override func mouseDown(with event: NSEvent) {
            if Self.spaceKeyDown {
                beginNavigation(event)
                return
            }
            // Ctrl-drag smears like a right-drag (wash), without needing a second
            // mouse button. (If the system already promoted ctrl-click to a
            // rightMouseDown, that path handles it; otherwise we see it here.)
            begin(event, secondary: event.modifierFlags.contains(.control))
        }

        override func mouseDragged(with event: NSEvent) {
            if navigationDrag {
                updateNavigation(event)
                return
            }
            update(event)
        }

        override func mouseUp(with event: NSEvent) {
            if navigationDrag {
                finishNavigation()
                return
            }
            finish(event)
        }

        override func rightMouseDown(with event: NSEvent) {
            if Self.spaceKeyDown {
                beginNavigation(event)
                return
            }
            begin(event, secondary: true)
        }

        override func rightMouseDragged(with event: NSEvent) {
            if navigationDrag {
                updateNavigation(event)
                return
            }
            update(event)
        }

        override func rightMouseUp(with event: NSEvent) {
            if navigationDrag {
                finishNavigation()
                return
            }
            finish(event)
        }

        override func scrollWheel(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let flags = event.modifierFlags
            let dx = event.hasPreciseScrollingDeltas ? event.scrollingDeltaX : event.scrollingDeltaX * 8
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 8
            if flags.contains(.command) || flags.contains(.control) {
                let factor = exp(CGFloat(dy) * 0.01)
                onNavigationActive?(true)
                onMagnify?(factor, point)
                onNavigationActive?(false)
            } else {
                onNavigationActive?(true)
                onScroll?(CGSize(width: dx, height: dy))
                onNavigationActive?(false)
            }
        }

        override func magnify(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onNavigationActive?(true)
            onMagnify?(max(0.05, 1 + event.magnification), point)
            onNavigationActive?(false)
        }

        override func smartMagnify(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onMagnify?(event.clickCount > 1 ? 0.5 : 2, point)
        }

        private func beginNavigation(_ event: NSEvent) {
            navigationDrag = true
            let point = convert(event.locationInWindow, from: nil)
            lastNavigationLocation = point
            onNavigationActive?(true)
        }

        private func updateNavigation(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if let lastNavigationLocation {
                onScroll?(CGSize(width: point.x - lastNavigationLocation.x, height: point.y - lastNavigationLocation.y))
            }
            lastNavigationLocation = point
        }

        private func finishNavigation() {
            navigationDrag = false
            lastNavigationLocation = nil
            onNavigationActive?(false)
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

private struct InkPreviewDrawingLayer: View {
    @Binding var paths: [InkEditorPath]
    let showLivePath: Bool
    let immediatePen: Bool
    let immediateWash: Bool
    let smoothing: Float
    let onLive: (InkLiveStrokeSample) -> Void
    let onLiveEnd: () -> Void
    let onImmediateCommitted: (InkEditorPath) -> Void
    let onCanvasAction: (InkEditorPath?) -> Void
    let outputSize: CGSize
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
    let camera: CanvasCamera
    let worldHeight: CGFloat
    let worldPixelExtent: CGFloat
    let onViewportPan: (CGSize) -> Void
    let onViewportZoom: (CGFloat, CGPoint) -> Void
    let onNavigationActive: (Bool) -> Void
    let brushSpace: CanvasBrushSpace
    @Binding var selectedPathID: UUID?
    @Binding var selectedPointIndex: Int?
    @State private var current: [CGPoint] = []
    @State private var rawCurrent: [CGPoint] = []
    @State private var currentSampleTimes: [TimeInterval] = []
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
            let activeRect = fittedRect(container: geo.size, content: outputSize)
            ZStack {
                Color.black.opacity(0.001)
                if showsEditorPaths {
                    ForEach(paths) { path in
                        strokedPath(path.points, in: activeRect)
                            .stroke(path.id == selectedPathID ? Color.accentColor.opacity(0.8) : editorColor(for: path).opacity(0.24),
                                    style: StrokeStyle(lineWidth: path.id == selectedPathID ? 3 : 2, lineCap: .round, lineJoin: .round))
                        if path.id == selectedPathID {
                            selectionBounds(path.points, in: activeRect)
                                .stroke(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                            ForEach(path.points.indices, id: \.self) { index in
                                Circle()
                                    .fill(index == selectedPointIndex ? Color.accentColor : Color(nsColor: .windowBackgroundColor))
                                    .overlay(Circle().stroke(Color.accentColor, lineWidth: 1.5))
                                    .frame(width: 9, height: 9)
                                    .position(viewPoint(path.points[index], in: activeRect))
                            }
                        }
                    }
                }
                // Thin dashed guide for the live cursor path (the rendered ink
                // lags behind). Off by default — the engine's mark is the truth.
                if showLivePath, !rawCurrent.isEmpty {
                    strokedPath(rawCurrent, in: activeRect)
                        .stroke(inkColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [4, 4]))
                }
                InkCanvasEventOverlay(
                    onChanged: { value in
                        guard activeRect.contains(value.location) else { return }
                        handleDragChanged(value, in: activeRect)
                    },
                    onEnded: { ended in
                        handleDragEnded(committed: ended)
                    },
                    onScroll: onViewportPan,
                    onMagnify: { factor, anchor in
                        onViewportZoom(factor, anchor)
                    },
                    onNavigationActive: onNavigationActive
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
        let scale = rect.height / max(0.000_001, camera.viewHeight)
        return CGPoint(
            x: rect.midX + (point.x - camera.center.x) * scale,
            y: rect.midY + (point.y - camera.center.y) * scale
        )
    }

    private func handleDragChanged(_ value: InkCanvasDragValue, in rect: CGRect) {
        let p = worldPoint(value.location, in: rect)
        switch tool {
        case .draw:
            selectedPathID = nil
            selectedPointIndex = nil
            updateLiveStroke(with: p, secondary: value.secondary, combined: value.combined, dissolveWash: value.dissolveWash, shift: value.shift, charge: value.charge)
        case .select:
            let threshold = 0.025 * max(0.08, camera.viewHeight)
            if dragStartPaths.isEmpty {
                dragStartPaths = paths
                selectedPointIndex = nil
                if selectedPathID == nil || !hitSelectedPath(at: p) {
                    selectedPathID = nearestPath(to: p, threshold: threshold)?.id
                }
            }
            moveSelectedPath(from: worldPoint(value.startLocation, in: rect), to: p)
        case .points:
            let threshold = 0.025 * max(0.08, camera.viewHeight)
            if dragStartPaths.isEmpty {
                dragStartPaths = paths
                let hit = nearestPoint(to: p, threshold: threshold)
                selectedPathID = hit?.pathID ?? nearestPath(to: p, threshold: threshold)?.id
                selectedPointIndex = hit?.pointIndex
                if selectedPointIndex == nil, let selectedPathID {
                    selectedPointIndex = insertPoint(on: selectedPathID, near: p, threshold: 0.028 * max(0.08, camera.viewHeight))
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
        let completedPath = InkEditorPath(
            id: currentPathID ?? UUID(),
            points: current,
            sampleTimes: currentSampleTimes.count == current.count ? currentSampleTimes : nil,
            strokeSeed: currentStrokeSeed,
            brushMode: strokeMode,
            inkKind: currentDissolveWash ? .white : inkKind,
            width: engineWidth(for: strokeMode),
            flow: flow,
            bleed: bleed,
            dry: dry,
            colorSeparation: colorSeparation,
            brushInk: currentDissolveWash ? 1 : brushInk,
            color: inkRGBA
        )
        // Immediate mode: the live ink is already baked onto the canvas — keep
        // it, but don't add an editable path (so the buffer doesn't grow).
        if tool == .draw, committed, current.count > 1 {
            if immediate || currentWetOnly {
                onImmediateCommitted(completedPath)
            } else {
                paths.append(completedPath)
                onCanvasAction(completedPath)
            }
        } else if committed, tool != .draw, !dragStartPaths.isEmpty {
            onCanvasAction(nil)
        }
        onLiveEnd()
        current = []
        rawCurrent = []
        currentSampleTimes = []
        currentStrokeStartTime = nil
        currentStrokeSeed = nil
        currentPathID = nil
        currentStrokeMode = nil
        currentWetOnly = false
        currentDissolveWash = false
        dragStartPaths = []
        dragStartPoint = nil
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
        flowScale: Float = 1,
        shift: Bool,
        charge: Float
    ) -> InkLiveStrokeSample {
        return InkLiveStrokeSample(
            id: id,
            seed: currentStrokeSeed ?? 0,
            point: normalizedWorldPoint(point),
            time: time,
            brushMode: strokeMode,
            inkKind: currentDissolveWash ? .white : inkKind,
            width: engineWidth(for: strokeMode),
            directRadius: directBrushRadius(for: strokeMode),
            flow: flow * flowScale,
            brushInk: currentDissolveWash ? 1 : brushInk,
            color: inkRGBA,
            smoothBoost: shift,
            destructive: strokeMode == .brush && immediateWash && !currentWetOnly,
            wetOnly: currentWetOnly,
            charge: charge
        )
    }

    private func directBrushRadius(for strokeMode: InkBrushMode) -> Float? {
        let uiSize = max(0, CGFloat(strokeMode == .brush ? washWidth : width))
        let pixelExtent = max(1, worldPixelExtent)
        switch brushSpace {
        case .world:
            // Literal-ish diameter in world-backing pixels. The UI minimum is
            // still labelled as 1 for now, but visually that was too chunky at
            // the initial HD viewport; map it to a tenth-world-pixel hairline
            // internally while preserving the rest of the range.
            let diameterPixels = max(0.025, uiSize * 0.10)
            return Float((diameterPixels * 0.5) / pixelExtent)
        case .screen:
            // Apparent viewport diameter in screen/output pixels. Convert that
            // through the current camera scale so Screen mode does NOT get
            // larger/smaller as the camera zooms over the world canvas.
            let diameterPixels: CGFloat
            if strokeMode == .brush {
                diameterPixels = 0.15 + pow(min(uiSize, 2) / 2, 1.15) * 3.4
            } else {
                diameterPixels = 0.065 + pow(min(uiSize, 2) / 2, 1.35) * 0.435
            }
            let outputPixelsY = max(1, outputSize.height)
            let radiusWorldUnits = (diameterPixels * 0.5) * camera.viewHeight / outputPixelsY
            return Float(radiusWorldUnits / max(0.000_001, worldHeight))
        }
    }

    private func engineWidth(for strokeMode: InkBrushMode) -> Float {
        let uiSize = max(0, strokeMode == .brush ? washWidth : width)
        guard brushSpace == .screen else { return uiSize }
        // Screen mode is not literal pixels. It is an HD-calibrated apparent
        // size that should look good at the default 1920×1080 viewport. The
        // older direct 0…2 curve was tuned for zoomed-out/8K viewing and made
        // the default viewport feel like a chunky marker. Compress it before it
        // reaches the inkwash engine: 0 = subpixel hairline, 0.5 = thin pen,
        // 1 = expressive pen, 2 = marker-ish but not a giant blob.
        let normalized = min(1, uiSize / 2)
        return 0.20 * sqrt(normalized)
    }

    private func normalizedWorldPoint(_ point: CGPoint) -> CGPoint {
        let world = max(0.000_001, worldHeight)
        return CGPoint(
            x: min(1, max(0, point.x / world)),
            y: min(1, max(0, point.y / world))
        )
    }

    private func editorColor(for path: InkEditorPath) -> Color {
        if (path.brushMode ?? .pen) == .brush {
            return Color(red: 0.33, green: 0.42, blue: 0.74)
        }
        return (path.inkKind ?? .black) == .white ? .white : inkColor
    }

    private func normalized(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
            y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height)))
        )
    }

    private func worldPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let scale = max(1, rect.height)
        let p = CGPoint(
            x: camera.center.x + (point.x - rect.midX) / scale * camera.viewHeight,
            y: camera.center.y + (point.y - rect.midY) / scale * camera.viewHeight
        )
        return clampToWorld(p)
    }

    private func liveRasterPoint(fromWorld point: CGPoint) -> CGPoint {
        viewportPoint(fromWorld: point)
    }

    private func viewportPoint(fromWorld point: CGPoint) -> CGPoint {
        let aspect = max(0.000_001, outputSize.width / max(1, outputSize.height))
        let viewHeight = max(0.000_001, camera.viewHeight)
        return CGPoint(
            x: (point.x - camera.center.x) / (viewHeight * aspect) + 0.5,
            y: (point.y - camera.center.y) / viewHeight + 0.5
        )
    }

    private func clampToWorld(_ point: CGPoint) -> CGPoint {
        let maxCoord = max(1, worldHeight)
        return CGPoint(x: min(maxCoord, max(0, point.x)),
                       y: min(maxCoord, max(0, point.y)))
    }

    private func selectionBounds(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }
        let viewPoints = points.map { viewPoint($0, in: rect) }
        let xs = viewPoints.map(\.x)
        let ys = viewPoints.map(\.y)
        let minX = xs.min() ?? rect.minX
        let maxX = xs.max() ?? rect.minX
        let minY = ys.min() ?? rect.minY
        let maxY = ys.max() ?? rect.minY
        let inset: CGFloat = 8
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
        return distanceToPath(point, path.points) <= 0.025 * max(0.08, camera.viewHeight)
    }

    private func moveSelectedPath(from start: CGPoint, to end: CGPoint) {
        guard let selectedPathID,
              let original = dragStartPaths.first(where: { $0.id == selectedPathID }),
              let index = paths.firstIndex(where: { $0.id == selectedPathID }) else { return }
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        paths[index].points = original.points.map {
            clampToWorld(CGPoint(x: $0.x + delta.x, y: $0.y + delta.y))
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
        paths[index].points[selectedPointIndex] = clampToWorld(point)
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

private struct ExportCropInsets: Equatable {
    var left: Double
    var top: Double
    var right: Double
    var bottom: Double
}

private struct ExportPreviewCanvas: View {
    @ObservedObject var live: LiveReadouts
    let liveDisplay: SampleBufferDisplayController
    let usesMetalLivePreview: Bool
    let reviewImage: CGImage?
    let isLoading: Bool
    let outputSize: CGSize
    let framing: ExportFraming
    @Binding var cropInsets: ExportCropInsets
    let cropIsEditable: Bool
    let cropDidEndEditing: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let canvas = aspectFitRect(
                aspect: max(0.01, outputSize.width / max(1, outputSize.height)),
                inside: CGRect(origin: .zero, size: proxy.size)
            )
            ZStack {
                Color.black.opacity(0.28)
                ZStack {
                    if let reviewImage {
                        ExportPreviewImage(image: reviewImage, framing: .stretch)
                    } else if usesMetalLivePreview {
                        SampleBufferDisplayView(
                            controller: liveDisplay,
                            videoGravity: framing.videoGravity
                        )
                    } else if let image = live.previewImage {
                        ExportPreviewImage(image: image, framing: framing)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                    if cropIsEditable {
                        ExportCropEditor(insets: $cropInsets, didEndEditing: cropDidEndEditing)
                    }
                    if isLoading { ProgressView().controlSize(.small) }
                }
                .frame(width: canvas.width, height: canvas.height)
                .position(x: canvas.midX, y: canvas.midY)
                .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private func aspectFitRect(aspect: CGFloat, inside bounds: CGRect) -> CGRect {
        let boundsAspect = bounds.width / max(1, bounds.height)
        let size = boundsAspect > aspect
            ? CGSize(width: bounds.height * aspect, height: bounds.height)
            : CGSize(width: bounds.width, height: bounds.width / aspect)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}

private extension ExportFraming {
    var videoGravity: AVLayerVideoGravity {
        switch self {
        case .fit: .resizeAspect
        case .fill: .resizeAspectFill
        case .stretch: .resize
        }
    }
}

private struct ExportPreviewImage: View {
    let image: CGImage
    let framing: ExportFraming

    var body: some View {
        GeometryReader { proxy in
            let content = Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.none)
            switch framing {
            case .fit:
                content.scaledToFit().frame(width: proxy.size.width, height: proxy.size.height)
            case .fill:
                content.scaledToFill().frame(width: proxy.size.width, height: proxy.size.height).clipped()
            case .stretch:
                content.frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
    }
}

private struct ExportWorldPreviewCanvas: View {
    @ObservedObject var live: LiveReadouts
    let liveDisplay: SampleBufferDisplayController
    let usesMetalLivePreview: Bool
    let reviewImage: CGImage?
    let isLoading: Bool
    let outputSize: CGSize
    let framing: ExportFraming
    @Binding var camera: CanvasCamera
    let worldHeight: CGFloat
    let outputAspect: CGFloat
    let paths: [InkEditorPath]
    let selectedPathID: UUID?
    @Binding var cropInsets: ExportCropInsets
    let cropIsEditable: Bool
    let cropDidEndEditing: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let world = worldRect(in: proxy.size)
            let viewport = viewportRect(in: world)
            let crop = cropRect(in: viewport)

            ZStack {
                Color.black.opacity(0.30)

                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.12))
                    .frame(width: world.width, height: world.height)
                    .position(x: world.midX, y: world.midY)

                ForEach(paths) { path in
                    PreviewPathShape(points: path.points, worldHeight: worldHeight)
                        .stroke(path.id == selectedPathID ? Color.accentColor.opacity(0.9) : Color.white.opacity(0.30),
                                style: StrokeStyle(lineWidth: path.id == selectedPathID ? 1.4 : 0.9,
                                                   lineCap: .round,
                                                   lineJoin: .round))
                        .frame(width: world.width, height: world.height)
                        .position(x: world.midX, y: world.midY)
                }

                ZStack {
                    if let reviewImage {
                        ExportPreviewImage(image: reviewImage, framing: .stretch)
                    } else if usesMetalLivePreview {
                        SampleBufferDisplayView(
                            controller: liveDisplay,
                            videoGravity: framing.videoGravity
                        )
                    } else if let image = live.previewImage {
                        ExportPreviewImage(image: image, framing: framing)
                    } else {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.18))
                        ProgressView().controlSize(.small)
                    }
                    if isLoading { ProgressView().controlSize(.small) }
                }
                .frame(width: viewport.width, height: viewport.height)
                .position(x: viewport.midX, y: viewport.midY)
                .clipped()

                Canvas { context, size in
                    var outsideCrop = Path(CGRect(origin: .zero, size: size))
                    outsideCrop.addRect(crop)
                    context.fill(outsideCrop, with: .color(.black.opacity(0.42)),
                                 style: FillStyle(eoFill: true))

                    var worldPath = Path()
                    worldPath.addRect(world)
                    context.stroke(worldPath, with: .color(.white.opacity(0.16)), lineWidth: 1)

                    var guardPath = Path()
                    guardPath.addRect(guardRect(in: world))
                    context.stroke(guardPath,
                                   with: .color(.white.opacity(0.20)),
                                   style: StrokeStyle(lineWidth: 1, dash: [2, 3]))

                    var viewportPath = Path()
                    viewportPath.addRect(viewport)
                    context.stroke(viewportPath,
                                   with: .color(.white.opacity(0.90)),
                                   style: StrokeStyle(lineWidth: 1.3, dash: [5, 4]))

                    if cropIsEditable {
                        drawCropFrame(crop, in: &context)
                    }
                }
                .allowsHitTesting(false)

                if cropIsEditable {
                    ExportWorldPreviewInteractionOverlay(
                        camera: $camera,
                        cropInsets: $cropInsets,
                        worldRect: world,
                        viewportRect: viewport,
                        worldHeight: worldHeight,
                        outputAspect: outputAspect,
                        cropDidEndEditing: cropDidEndEditing
                    )
                } else {
                    ExportWorldPreviewInteractionOverlay(
                        camera: $camera,
                        cropInsets: .constant(cropInsets),
                        worldRect: world,
                        viewportRect: viewport,
                        worldHeight: worldHeight,
                        outputAspect: outputAspect,
                        cropDidEndEditing: {}
                    )
                }

                VStack {
                    HStack {
                        Text("Whole canvas")
                        Spacer()
                        Text("\(Int(1 / max(0.000_001, camera.viewHeight) * 100))%")
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.72))
                    .padding(8)
                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .help("Drag to move the viewport. Shift-drag inside the crop or its handles to adjust export crop.")
            .accessibilityLabel("Whole canvas preview")
        }
    }

    private func worldRect(in size: CGSize) -> CGRect {
        let inset: CGFloat = 8
        let available = CGSize(width: max(1, size.width - inset * 2),
                               height: max(1, size.height - inset * 2))
        let side = max(1, min(available.width, available.height))
        return CGRect(x: (size.width - side) * 0.5,
                      y: (size.height - side) * 0.5,
                      width: side,
                      height: side)
    }

    private func viewportRect(in world: CGRect) -> CGRect {
        let maxCoord = max(1, worldHeight)
        let viewHeight = min(maxCoord, max(0.08, camera.viewHeight))
        let viewWidth = min(maxCoord, viewHeight * max(0.000_001, outputAspect))
        return CGRect(
            x: world.minX + (camera.center.x - viewWidth * 0.5) / maxCoord * world.width,
            y: world.minY + (camera.center.y - viewHeight * 0.5) / maxCoord * world.height,
            width: viewWidth / maxCoord * world.width,
            height: viewHeight / maxCoord * world.height
        )
    }

    private func guardRect(in world: CGRect) -> CGRect {
        viewportRect(in: world).insetBy(
            dx: -world.width * camera.guardFraction * camera.viewHeight / max(1, worldHeight) * max(0.000_001, outputAspect),
            dy: -world.height * camera.guardFraction * camera.viewHeight / max(1, worldHeight)
        )
    }

    private func cropRect(in viewport: CGRect) -> CGRect {
        CGRect(x: viewport.minX + viewport.width * cropInsets.left,
               y: viewport.minY + viewport.height * cropInsets.top,
               width: viewport.width * max(0.02, 1 - cropInsets.left - cropInsets.right),
               height: viewport.height * max(0.02, 1 - cropInsets.top - cropInsets.bottom))
    }

    private func drawCropFrame(_ crop: CGRect, in context: inout GraphicsContext) {
        var cropPath = Path()
        cropPath.addRect(crop)
        context.stroke(cropPath,
                       with: .color(.white.opacity(0.96)),
                       style: StrokeStyle(lineWidth: 1.6, dash: [5, 3]))

        for handle in ExportWorldPreviewInteractionOverlay.Handle.allCases where handle != .move {
            let point = ExportWorldPreviewInteractionOverlay.handlePoint(handle, crop: crop)
            let edge = handle == .top || handle == .bottom || handle == .left || handle == .right
            let size = CGSize(width: edge && (handle == .top || handle == .bottom) ? 18 : 9,
                              height: edge && (handle == .left || handle == .right) ? 18 : 9)
            let rect = CGRect(x: point.x - size.width * 0.5,
                              y: point.y - size.height * 0.5,
                              width: size.width,
                              height: size.height)
            let handlePath = Path(roundedRect: rect, cornerRadius: 2)
            context.fill(handlePath, with: .color(.white))
            context.stroke(handlePath, with: .color(.black.opacity(0.85)), lineWidth: 1)
        }
    }
}

private struct PreviewPathShape: Shape {
    let points: [CGPoint]
    let worldHeight: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: viewPoint(first, in: rect))
        for point in points.dropFirst() {
            path.addLine(to: viewPoint(point, in: rect))
        }
        return path
    }

    private func viewPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        let maxCoord = max(1, worldHeight)
        return CGPoint(
            x: rect.minX + point.x / maxCoord * rect.width,
            y: rect.minY + point.y / maxCoord * rect.height
        )
    }
}

private struct ExportWorldPreviewInteractionOverlay: NSViewRepresentable {
    enum Handle: CaseIterable {
        case move, top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
    }

    @Binding var camera: CanvasCamera
    @Binding var cropInsets: ExportCropInsets
    let worldRect: CGRect
    let viewportRect: CGRect
    let worldHeight: CGFloat
    let outputAspect: CGFloat
    let cropDidEndEditing: () -> Void

    static func handlePoint(_ handle: Handle, crop: CGRect) -> CGPoint {
        switch handle {
        case .top: CGPoint(x: crop.midX, y: crop.minY)
        case .bottom: CGPoint(x: crop.midX, y: crop.maxY)
        case .left: CGPoint(x: crop.minX, y: crop.midY)
        case .right: CGPoint(x: crop.maxX, y: crop.midY)
        case .topLeft: CGPoint(x: crop.minX, y: crop.minY)
        case .topRight: CGPoint(x: crop.maxX, y: crop.minY)
        case .bottomLeft: CGPoint(x: crop.minX, y: crop.maxY)
        case .bottomRight: CGPoint(x: crop.maxX, y: crop.maxY)
        case .move: CGPoint(x: crop.midX, y: crop.midY)
        }
    }

    func makeNSView(context: Context) -> EventView {
        let view = EventView()
        view.onCamera = { camera = $0 }
        view.onCrop = { cropInsets = $0 }
        view.cropDidEndEditing = cropDidEndEditing
        return view
    }

    func updateNSView(_ nsView: EventView, context: Context) {
        nsView.camera = camera
        nsView.cropInsets = cropInsets
        nsView.worldRect = worldRect
        nsView.viewportRect = viewportRect
        nsView.worldHeight = worldHeight
        nsView.outputAspect = outputAspect
        nsView.onCamera = { camera = $0 }
        nsView.onCrop = { cropInsets = $0 }
        nsView.cropDidEndEditing = cropDidEndEditing
    }

    final class EventView: NSView {
        var camera = CanvasCamera()
        var cropInsets = ExportCropInsets(left: 0, top: 0, right: 0, bottom: 0)
        var worldRect = CGRect.zero
        var viewportRect = CGRect.zero
        var worldHeight: CGFloat = 1
        var outputAspect: CGFloat = 16.0 / 9.0
        var onCamera: ((CanvasCamera) -> Void)?
        var onCrop: ((ExportCropInsets) -> Void)?
        var cropDidEndEditing: (() -> Void)?
        private var dragMode: DragMode?

        override var isFlipped: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            let shift = event.modifierFlags.contains(.shift)
            if shift, viewportRect.contains(point) {
                dragMode = .crop(handle: hitCropHandle(point), startPoint: point, startInsets: cropInsets)
            } else if worldRect.contains(point) {
                dragMode = .viewport(startPoint: point, startCamera: camera)
            } else {
                dragMode = nil
            }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let dragMode else { return }
            let point = convert(event.locationInWindow, from: nil)
            switch dragMode {
            case let .viewport(startPoint, startCamera):
                var next = startCamera
                let dx = (point.x - startPoint.x) / max(1, worldRect.width) * max(1, worldHeight)
                let dy = (point.y - startPoint.y) / max(1, worldRect.height) * max(1, worldHeight)
                next.center.x -= dx
                next.center.y -= dy
                onCamera?(clamped(next))
            case let .crop(handle, startPoint, startInsets):
                let dx = Double((point.x - startPoint.x) / max(1, viewportRect.width))
                let dy = Double((point.y - startPoint.y) / max(1, viewportRect.height))
                onCrop?(updatedCrop(handle: handle, start: startInsets, dx: dx, dy: dy))
            }
        }

        override func mouseUp(with event: NSEvent) {
            if case .crop = dragMode {
                cropDidEndEditing?()
            }
            dragMode = nil
        }

        private enum DragMode {
            case viewport(startPoint: CGPoint, startCamera: CanvasCamera)
            case crop(handle: Handle, startPoint: CGPoint, startInsets: ExportCropInsets)
        }

        private func cropRect() -> CGRect {
            CGRect(x: viewportRect.minX + viewportRect.width * cropInsets.left,
                   y: viewportRect.minY + viewportRect.height * cropInsets.top,
                   width: viewportRect.width * max(0.02, 1 - cropInsets.left - cropInsets.right),
                   height: viewportRect.height * max(0.02, 1 - cropInsets.top - cropInsets.bottom))
        }

        private func hitCropHandle(_ point: CGPoint) -> Handle {
            let crop = cropRect()
            let hitRadius: CGFloat = 12
            for handle in Handle.allCases where handle != .move {
                let p = ExportWorldPreviewInteractionOverlay.handlePoint(handle, crop: crop)
                if abs(point.x - p.x) <= hitRadius, abs(point.y - p.y) <= hitRadius {
                    return handle
                }
            }
            return .move
        }

        private func updatedCrop(handle: Handle, start: ExportCropInsets, dx: Double, dy: Double) -> ExportCropInsets {
            let minimumSpan = 0.02
            var next = start
            if handle == .move {
                let horizontal = min(max(dx, -start.left), start.right)
                let vertical = min(max(dy, -start.top), start.bottom)
                next.left = start.left + horizontal
                next.right = start.right - horizontal
                next.top = start.top + vertical
                next.bottom = start.bottom - vertical
            } else {
                if handle == .left || handle == .topLeft || handle == .bottomLeft {
                    next.left = min(max(0, start.left + dx), 1 - start.right - minimumSpan)
                }
                if handle == .right || handle == .topRight || handle == .bottomRight {
                    next.right = min(max(0, start.right - dx), 1 - start.left - minimumSpan)
                }
                if handle == .top || handle == .topLeft || handle == .topRight {
                    next.top = min(max(0, start.top + dy), 1 - start.bottom - minimumSpan)
                }
                if handle == .bottom || handle == .bottomLeft || handle == .bottomRight {
                    next.bottom = min(max(0, start.bottom - dy), 1 - start.top - minimumSpan)
                }
            }
            return next
        }

        private func clamped(_ camera: CanvasCamera) -> CanvasCamera {
            let maxCoord = max(1, worldHeight)
            let aspect = max(0.000_001, outputAspect)
            var next = camera
            next.rotation = 0
            next.viewHeight = min(maxCoord, max(0.08, next.viewHeight))
            let marginX = min(maxCoord * 0.5, next.viewHeight * aspect * 0.5)
            let marginY = min(maxCoord * 0.5, next.viewHeight * 0.5)
            next.center.x = min(maxCoord - marginX, max(marginX, next.center.x))
            next.center.y = min(maxCoord - marginY, max(marginY, next.center.y))
            if maxCoord <= next.viewHeight || maxCoord <= next.viewHeight * aspect {
                next.center = CGPoint(x: maxCoord * 0.5, y: maxCoord * 0.5)
            }
            return next
        }
    }
}

private struct ExportCropEditor: View {
    private enum Handle: CaseIterable, Identifiable {
        case move, top, bottom, left, right, topLeft, topRight, bottomLeft, bottomRight
        var id: Self { self }
    }

    @Binding var insets: ExportCropInsets
    let didEndEditing: () -> Void
    @State private var dragStart: ExportCropInsets?
    private let minimumSpan = 0.02

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let crop = cropRect(in: bounds)
            ZStack {
                Canvas { context, size in
                    var shade = Path(CGRect(origin: .zero, size: size))
                    shade.addRect(crop)
                    context.fill(shade, with: .color(.black.opacity(0.56)),
                                 style: FillStyle(eoFill: true))
                }
                .allowsHitTesting(false)

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
                    .gesture(dragGesture(.move, size: proxy.size))
                    .help("Drag to reposition the crop")

                Rectangle()
                    .stroke(.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    .shadow(color: .black.opacity(0.8), radius: 1)
                    .frame(width: crop.width, height: crop.height)
                    .position(x: crop.midX, y: crop.midY)
                    .allowsHitTesting(false)

                ForEach(Handle.allCases.filter { $0 != .move }) { handle in
                    cropHandle(handle, crop: crop, size: proxy.size)
                }
            }
        }
    }

    private func cropHandle(_ handle: Handle, crop: CGRect, size: CGSize) -> some View {
        let point = handlePoint(handle, crop: crop)
        let edge = handle == .top || handle == .bottom || handle == .left || handle == .right
        return RoundedRectangle(cornerRadius: 2)
            .fill(.white)
            .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.8), lineWidth: 1))
            .frame(width: edge && (handle == .top || handle == .bottom) ? 18 : 9,
                   height: edge && (handle == .left || handle == .right) ? 18 : 9)
            .contentShape(Rectangle().inset(by: -7))
            .position(point)
            .gesture(dragGesture(handle, size: size))
            .help("Drag to resize the crop")
    }

    private func cropRect(in bounds: CGRect) -> CGRect {
        CGRect(x: bounds.width * insets.left,
               y: bounds.height * insets.top,
               width: bounds.width * max(minimumSpan, 1 - insets.left - insets.right),
               height: bounds.height * max(minimumSpan, 1 - insets.top - insets.bottom))
    }

    private func handlePoint(_ handle: Handle, crop: CGRect) -> CGPoint {
        switch handle {
        case .top: CGPoint(x: crop.midX, y: crop.minY)
        case .bottom: CGPoint(x: crop.midX, y: crop.maxY)
        case .left: CGPoint(x: crop.minX, y: crop.midY)
        case .right: CGPoint(x: crop.maxX, y: crop.midY)
        case .topLeft: CGPoint(x: crop.minX, y: crop.minY)
        case .topRight: CGPoint(x: crop.maxX, y: crop.minY)
        case .bottomLeft: CGPoint(x: crop.minX, y: crop.maxY)
        case .bottomRight: CGPoint(x: crop.maxX, y: crop.maxY)
        case .move: CGPoint(x: crop.midX, y: crop.midY)
        }
    }

    private func dragGesture(_ handle: Handle, size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = insets }
                guard let start = dragStart else { return }
                let dx = Double(value.translation.width / max(1, size.width))
                let dy = Double(value.translation.height / max(1, size.height))
                var next = start

                if handle == .move {
                    let horizontal = min(max(dx, -start.left), start.right)
                    let vertical = min(max(dy, -start.top), start.bottom)
                    next.left = start.left + horizontal; next.right = start.right - horizontal
                    next.top = start.top + vertical; next.bottom = start.bottom - vertical
                } else {
                    if handle == .left || handle == .topLeft || handle == .bottomLeft {
                        next.left = min(max(0, start.left + dx), 1 - start.right - minimumSpan)
                    }
                    if handle == .right || handle == .topRight || handle == .bottomRight {
                        next.right = min(max(0, start.right - dx), 1 - start.left - minimumSpan)
                    }
                    if handle == .top || handle == .topLeft || handle == .topRight {
                        next.top = min(max(0, start.top + dy), 1 - start.bottom - minimumSpan)
                    }
                    if handle == .bottom || handle == .bottomLeft || handle == .bottomRight {
                        next.bottom = min(max(0, start.bottom - dy), 1 - start.top - minimumSpan)
                    }
                }
                insets = next
            }
            .onEnded { _ in
                dragStart = nil
                didEndEditing()
            }
    }
}

private struct ExportPanel: View {
    @ObservedObject var exporter: OutputStreamExporter
    @ObservedObject var proxyRecorder: TemporaryInputProxyRecorder
    let live: LiveReadouts
    let liveDisplay: SampleBufferDisplayController
    let usesMetalLivePreview: Bool
    @Binding var auxPreviewEnabled: Bool
    @Binding var camera: CanvasCamera
    let worldHeight: CGFloat
    let outputAspect: CGFloat
    let paths: [InkEditorPath]
    let selectedPathID: UUID?
    let currentSize: CGSize
    let currentFPS: Double
    let metricLayers: [(id: UUID, name: String)]
    let chooseDestination: () -> Void
    let exportCurrent: () -> Void
    let startProxy: () -> Void
    @State private var previewShowsReview = false

    private var config: Binding<ExportConfiguration> { $exporter.configuration }

    var body: some View {
        SectionHeader("Export")

        GroupBox("Preview") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Aux previews", isOn: $auxPreviewEnabled)
                    .toggleStyle(.checkbox)
                    .help("Show the Export live/review preview and whole-canvas minimap. Turn this off while tuning navigation performance to keep the main canvas on the Metal display path only.")
                if auxPreviewEnabled {
                    if exporter.reviewImage != nil {
                        Picker("", selection: $previewShowsReview) {
                            Text("Live").tag(false)
                            Text("Review").tag(true)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    ExportWorldPreviewCanvas(
                        live: live,
                        liveDisplay: liveDisplay,
                        usesMetalLivePreview: usesMetalLivePreview,
                        reviewImage: previewShowsReview ? exporter.reviewImage : nil,
                        isLoading: previewShowsReview && exporter.reviewIsLoading,
                        outputSize: CGSize(width: max(1, exporter.configuration.width),
                                           height: max(1, exporter.configuration.height)),
                        framing: exporter.configuration.framing,
                        camera: $camera,
                        worldHeight: worldHeight,
                        outputAspect: outputAspect,
                        paths: paths,
                        selectedPathID: selectedPathID,
                        cropInsets: cropInsets,
                        cropIsEditable: !previewShowsReview,
                        cropDidEndEditing: exporter.refreshReviewPreview
                    )
                    .frame(height: 300)
                } else {
                    Text("Aux previews are off. The main canvas still renders/publishes normally; this avoids extra preview surfaces while panning and zooming.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if auxPreviewEnabled, previewShowsReview, exporter.reviewImage != nil {
                    if exporter.reviewFrameCount > 1 {
                        Slider(value: Binding(
                            get: { Double(exporter.reviewFrame) },
                            set: { exporter.seekReview(frame: Int($0.rounded())) }
                        ), in: 0...Double(exporter.reviewFrameCount - 1), step: 1)
                    }
                    HStack {
                        Button { exporter.stepReview(-1) } label: { Image(systemName: "backward.frame") }
                        Button { exporter.stepReview(1) } label: { Image(systemName: "forward.frame") }
                        Text("Frame \(exporter.reviewFrame + 1) / \(max(1, exporter.reviewFrameCount)) · \(exporter.reviewTime, format: .number.precision(.fractionLength(2))) s")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("Continue from frame") { exporter.continueFromReview() }
                        Button("Re-export clip") { exporter.reexportReview() }
                    }
                    .disabled(exporter.state != .idle || exporter.reviewFrameCount == 0 || exporter.destinationURL == nil)
                    Text("Continue creates a new take with the reviewed prefix, then appends new captures. The original remains untouched.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Drag the whole-canvas preview to move the viewport. Shift-drag the crop frame or handles to edit the export crop. Completed exports are available under Review.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .onChange(of: exporter.reviewURL) { _, url in
            if url != nil { previewShowsReview = true }
        }

        GroupBox("Presets") {
            VStack(spacing: 6) {
                HStack {
                    Text("Workflow")
                    Spacer()
                    Menu(exporter.selectedBuiltInPreset?.title ?? "Choose…") {
                        ForEach(OutputStreamExporter.BuiltInPreset.allCases) { preset in
                            Button(preset.title) { exporter.applyPreset(preset, outputFPS: currentFPS) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                }
                Text(exporter.selectedBuiltInPreset?.summary ?? "Choose a ready-made workflow, then adjust any setting and optionally save it as your own preset.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    TextField("Preset name", text: $exporter.presetName)
                    Button("Save") { exporter.saveNamedPreset() }.disabled(exporter.presetName.isEmpty)
                    Menu("Load") {
                        ForEach(exporter.presets) { preset in
                            Button(preset.name) { exporter.applyPreset(preset) }
                        }
                        if !exporter.presets.isEmpty {
                            Divider()
                            Menu("Delete") {
                                ForEach(exporter.presets) { preset in
                                    Button(preset.name, role: .destructive) { exporter.deletePreset(preset) }
                                }
                            }
                        }
                    }.disabled(exporter.presets.isEmpty)
                }
            }
            .controlSize(.small)
        }

        GroupBox("Destination") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Take name", text: config.takeName)
                HStack {
                    Button("Choose…", action: chooseDestination)
                    Text(exporter.destinationURL?.path(percentEncoded: false) ?? "No destination")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        .truncationMode(.middle)
                }
                Picker("If output exists", selection: resolvedCollisionPolicy) {
                    Text("Create new take").tag(ExportCollisionPolicy.newTake)
                    Text("Replace").tag(ExportCollisionPolicy.replace)
                }
            }
        }

        GroupBox("Output") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Type", selection: resolvedOutputKind) {
                    ForEach(ExportOutputKind.allCases) { Text(exportLabel($0)).tag($0) }
                }
                Picker("Render", selection: config.renderMode) {
                    Text("Live").tag(ExportRenderMode.live)
                    Text("NRT · replay").tag(ExportRenderMode.nrtReplay)
                    Text("NRT · continue").tag(ExportRenderMode.nrtContinue)
                }
                if exporter.configuration.renderMode == .nrtContinue {
                    Text("Continue clones the exact pigment, wetness, velocity, pressure, lock, and fixed-pigment fields into an isolated renderer. The live canvas is unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if exporter.configuration.renderMode != .live {
                    Picker("Live inputs", selection: resolvedLiveInputMode) {
                        Text("Freeze latest").tag(ExportLiveInputMode.freezeLatest)
                        Text("Recorded proxy").tag(ExportLiveInputMode.recordedProxy)
                    }
                }
                if exporter.configuration.outputKind == .still || exporter.configuration.outputKind == .imageSequence {
                    Picker("Format", selection: resolvedImageFormat) {
                        ForEach(ExportImageFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                } else if exporter.configuration.outputKind == .movie {
                    Picker("Codec", selection: config.movieCodec) {
                        ForEach(ExportMovieCodec.allCases) { Text(codecLabel($0)).tag($0) }
                    }
                    Picker("Container", selection: resolvedContainer) {
                        ForEach(ExportContainer.allCases) { Text($0.rawValue.uppercased()).tag($0) }
                    }
                }
                HStack {
                    Text("Size")
                    TextField("Width", value: Binding(
                        get: { exporter.configuration.width },
                        set: { exporter.configuration.width = $0; exporter.refreshReviewPreview() }
                    ), format: .number).frame(width: 70)
                    Text("×")
                    TextField("Height", value: Binding(
                        get: { exporter.configuration.height },
                        set: { exporter.configuration.height = $0; exporter.refreshReviewPreview() }
                    ), format: .number).frame(width: 70)
                    Button("Current") {
                        exporter.configuration.width = Int(currentSize.width)
                        exporter.configuration.height = Int(currentSize.height)
                        exporter.refreshReviewPreview()
                    }
                }
                Text("Size sets the final export aspect. Crop is enlarged to fill that frame.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Framing", selection: Binding(
                    get: { exporter.configuration.framing },
                    set: { exporter.configuration.framing = $0; exporter.refreshReviewPreview() }
                )) {
                    ForEach(ExportFraming.allCases) { Text($0.rawValue.capitalized).tag($0) }
                }
                Picker("Color", selection: config.colorSpace) {
                    Text("sRGB").tag(ExportColorSpace.sRGB)
                    Text("Display P3").tag(ExportColorSpace.displayP3)
                }
                LabeledContent("Quality") { Slider(value: config.quality, in: 0...1) }
                Toggle("Alpha", isOn: config.includeAlpha)
                    .disabled(exporter.configuration.outputKind == .movie && !exporter.configuration.movieCodec.supportsAlpha)
            }
            .textFieldStyle(.roundedBorder)
        }


        GroupBox("Crop & transform") {
            VStack(spacing: 8) {
                HStack {
                    PercentField("Left", value: optionalPercent(\.cropLeft))
                    PercentField("Right", value: optionalPercent(\.cropRight))
                }
                HStack {
                    PercentField("Top", value: optionalPercent(\.cropTop))
                    PercentField("Bottom", value: optionalPercent(\.cropBottom))
                }
                HStack {
                    Button("1:1") { setCropAspect(1) }
                    Button("4:3") { setCropAspect(4.0 / 3.0) }
                    Button("16:9") { setCropAspect(16.0 / 9.0) }
                    Button("Reset", action: resetTransform)
                }
                Picker("Rotate", selection: resolvedRotation) {
                    ForEach(ExportRotation.allCases) { Text("\($0.rawValue)°").tag($0) }
                }
                HStack {
                    Toggle("Flip horizontal", isOn: resolvedFlipHorizontal)
                    Toggle("Flip vertical", isOn: resolvedFlipVertical)
                }
            }
            .controlSize(.small)
        }

        GroupBox("Timing") {
            VStack(spacing: 8) {
                RateField("Capture FPS", value: config.captureFPS)
                RateField("Playback FPS", value: config.playbackFPS)
                if exporter.configuration.renderMode != .live {
                    RateField("Simulation FPS", value: config.simulationFPS)
                    Picker("Replay timing", selection: config.replayTiming) {
                        Text("Original").tag(ExportReplayTiming.original)
                        Text("Remove idle gaps").tag(ExportReplayTiming.removeIdleGaps)
                        Text("Fixed gap").tag(ExportReplayTiming.fixedGap)
                    }
                    if exporter.configuration.replayTiming == .fixedGap {
                        RateField("Fixed gap", value: config.fixedReplayGap, range: 0...3600, suffix: "s")
                    }
                    RateField("Speed", value: config.replaySpeed, range: 0.01...100, suffix: "×")
                }
            }
        }

        GroupBox("Capture rule") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Trigger", selection: config.trigger) {
                    ForEach(CaptureTrigger.allCases) { Text(triggerLabel($0)).tag($0) }
                }
                Text(captureRuleHelp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                RateField("Debounce", value: config.minimumEventInterval, range: 0...60, suffix: "s")
                ForEach(exporter.configuration.gates) { gate in
                    VStack(spacing: 4) {
                        HStack {
                            Toggle("", isOn: gateBinding(gate, \.enabled)).labelsHidden()
                            Picker("", selection: gateBinding(gate, \.kind)) {
                                ForEach(CaptureGateKind.allCases) { Text(gateLabel($0)).tag($0) }
                            }.labelsHidden()
                            Picker("", selection: gateBinding(gate, \.comparison)) {
                                ForEach(CaptureComparator.allCases) { Text($0.rawValue).tag($0) }
                            }.labelsHidden().frame(width: 76)
                            Button(role: .destructive) { exporter.configuration.removeGate(id: gate.id) } label: {
                                Image(systemName: "minus.circle")
                            }.buttonStyle(.plain)
                        }
                        HStack {
                            if gate.kind == .streamMetric {
                                Picker("Layer", selection: gateBinding(gate, \.layerID)) {
                                    Text("Final output").tag(UUID?.none)
                                    ForEach(metricLayers, id: \.id) { layer in
                                        Text(layer.name).tag(Optional(layer.id))
                                    }
                                }.labelsHidden()
                                Picker("Metric", selection: gateBinding(gate, \.metric)) {
                                    ForEach(ExportMetric.allCases) { Text(camelLabel($0.rawValue)).tag($0) }
                                }.labelsHidden()
                            }
                            TextField("lower", value: gateBinding(gate, \.lowerBound), format: .number)
                            if gate.comparison == .inside || gate.comparison == .outside {
                                TextField("upper", value: gateBinding(gate, \.upperBound), format: .number)
                            }
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }
                Button("Add AND gate") {
                    exporter.configuration.gates.append(CaptureGate(kind: .inkPixelsChanging))
                }
            }
        }

        GroupBox("Rotoscope") {
            VStack(spacing: 8) {
                HStack {
                    Button(proxyRecorder.isRecording ? "Stop input proxy" : "Record input proxy") {
                        proxyRecorder.isRecording ? proxyRecorder.stop() : startProxy()
                    }
                    Button("Clear", action: proxyRecorder.clear)
                        .disabled(proxyRecorder.isRecording || proxyRecorder.recordedDuration == 0)
                }
                Text(proxyRecorder.statusText).font(.caption).foregroundStyle(.secondary)
                LabeledContent("Advance frames") {
                    TextField("0", value: config.sourceAdvanceFrames, format: .number).frame(width: 72)
                }
                RateField("Advance seconds", value: config.sourceAdvanceSeconds, range: 0...3600, suffix: "s")
                Toggle("Loop source", isOn: config.loopSource)
                RateField("Source start", value: sourceStart, range: 0...864000, suffix: "s")
                RateField("Source end", value: sourceEnd, range: 0...864000, suffix: "s")
                Text("Set Source end to 0 to use the full source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }

        GroupBox("Limits & extras") {
            VStack(spacing: 8) {
                LabeledContent("Maximum frames") {
                    TextField("0 = unlimited", value: config.maximumFrames, format: .number).frame(width: 100)
                }
                RateField("Maximum duration", value: config.maximumDuration, range: 0...864000, suffix: "s")
                RateField("Keep disk free", value: config.minimumFreeDiskGB, range: 0...1024, suffix: "GB")
                Toggle("Metadata sidecar", isOn: config.writeMetadata)
                Toggle("Poster still", isOn: config.writePoster)
            }
        }

        HStack {
            Button("Export Current", action: exportCurrent)
            Button("Capture Next") { exporter.captureNext() }
                .disabled(exporter.state != .recording)
        }
        HStack {
            Button("Start") { exporter.start() }
                .disabled(exporter.destinationURL == nil || exporter.state == .recording || exporter.state == .finishing)
            Button("Stop") { exporter.stop() }.disabled(exporter.state != .recording)
            Button("Cancel") { exporter.stop(cancelled: true) }.disabled(exporter.state != .recording)
        }
        Text("\(exporter.statusText) · \(exporter.capturedFrames) frames · \(exporter.duplicatedFrames) duplicate · \(exporter.droppedFrames) dropped")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if let progress = exporter.progress {
            ProgressView(value: progress)
        }
        if exporter.configuration.outputKind == .gif {
            Text("GIF uses an indexed palette; transparency and sub-centisecond frame delays are approximate.")
                .font(.caption).foregroundStyle(.orange)
        }
    }

    private func gateBinding<T>(_ gate: CaptureGate, _ keyPath: WritableKeyPath<CaptureGate, T>) -> Binding<T> {
        Binding {
            exporter.configuration.gate(id: gate.id)?[keyPath: keyPath] ?? gate[keyPath: keyPath]
        } set: { value in
            exporter.configuration.updateGate(id: gate.id, keyPath: keyPath, value: value)
        }
    }

    private var resolvedLiveInputMode: Binding<ExportLiveInputMode> {
        Binding { exporter.configuration.resolvedLiveInputMode }
        set: { exporter.configuration.liveInputMode = $0 }
    }

    private var resolvedOutputKind: Binding<ExportOutputKind> {
        Binding { exporter.configuration.outputKind }
        set: { value in
            exporter.configuration.outputKind = value
            exporter.invalidateIncompatibleDestination()
        }
    }

    private var resolvedImageFormat: Binding<ExportImageFormat> {
        Binding { exporter.configuration.imageFormat }
        set: { value in
            exporter.configuration.imageFormat = value
            exporter.invalidateIncompatibleDestination()
        }
    }

    private var resolvedContainer: Binding<ExportContainer> {
        Binding { exporter.configuration.container }
        set: { value in
            exporter.configuration.container = value
            exporter.invalidateIncompatibleDestination()
        }
    }

    private var resolvedCollisionPolicy: Binding<ExportCollisionPolicy> {
        Binding { exporter.configuration.resolvedCollisionPolicy }
        set: { exporter.configuration.collisionPolicy = $0 }
    }

    private var sourceStart: Binding<Double> {
        Binding { exporter.configuration.sourceStartSeconds ?? 0 }
        set: { exporter.configuration.sourceStartSeconds = $0 > 0 ? $0 : nil }
    }

    private var sourceEnd: Binding<Double> {
        Binding { exporter.configuration.sourceEndSeconds ?? 0 }
        set: { exporter.configuration.sourceEndSeconds = $0 > 0 ? $0 : nil }
    }

    private var resolvedRotation: Binding<ExportRotation> {
        Binding { exporter.configuration.resolvedRotation }
        set: { exporter.configuration.rotation = $0; exporter.refreshReviewPreview() }
    }

    private var cropInsets: Binding<ExportCropInsets> {
        Binding {
            ExportCropInsets(
                left: exporter.configuration.cropLeft ?? 0,
                top: exporter.configuration.cropTop ?? 0,
                right: exporter.configuration.cropRight ?? 0,
                bottom: exporter.configuration.cropBottom ?? 0
            )
        } set: { value in
            exporter.configuration.cropLeft = value.left
            exporter.configuration.cropTop = value.top
            exporter.configuration.cropRight = value.right
            exporter.configuration.cropBottom = value.bottom
        }
    }

    private var resolvedFlipHorizontal: Binding<Bool> {
        Binding { exporter.configuration.resolvedFlipHorizontal }
        set: { exporter.configuration.flipHorizontal = $0; exporter.refreshReviewPreview() }
    }

    private var resolvedFlipVertical: Binding<Bool> {
        Binding { exporter.configuration.resolvedFlipVertical }
        set: { exporter.configuration.flipVertical = $0; exporter.refreshReviewPreview() }
    }

    private func optionalPercent(_ keyPath: WritableKeyPath<ExportConfiguration, Double?>) -> Binding<Double> {
        Binding { exporter.configuration[keyPath: keyPath] ?? 0 }
        set: {
            exporter.configuration[keyPath: keyPath] = min(0.95, max(0, $0))
            exporter.refreshReviewPreview()
        }
    }

    private func resetTransform() {
        exporter.configuration.cropLeft = 0; exporter.configuration.cropRight = 0
        exporter.configuration.cropTop = 0; exporter.configuration.cropBottom = 0
        exporter.configuration.rotation = .degrees0
        exporter.configuration.flipHorizontal = false; exporter.configuration.flipVertical = false
        exporter.refreshReviewPreview()
    }

    private func setCropAspect(_ target: CGFloat) {
        let source = CGFloat(max(1, exporter.configuration.width)) /
            CGFloat(max(1, exporter.configuration.height))
        exporter.configuration.cropLeft = 0; exporter.configuration.cropRight = 0
        exporter.configuration.cropTop = 0; exporter.configuration.cropBottom = 0
        if source > target {
            let inset = (1 - target / source) / 2
            exporter.configuration.cropLeft = Double(inset)
            exporter.configuration.cropRight = Double(inset)
        } else {
            let inset = (1 - source / target) / 2
            exporter.configuration.cropTop = Double(inset)
            exporter.configuration.cropBottom = Double(inset)
        }
        exporter.refreshReviewPreview()
    }

    private func exportLabel(_ value: ExportOutputKind) -> String {
        switch value { case .still: "Still"; case .movie: "Movie"; case .imageSequence: "Image sequence"; case .gif: "GIF" }
    }
    private func codecLabel(_ value: ExportMovieCodec) -> String {
        switch value { case .h264: "H.264"; case .hevc: "HEVC"; case .proRes422: "ProRes 422"; case .proRes422HQ: "ProRes 422 HQ"; case .proRes4444: "ProRes 4444" }
    }
    private func triggerLabel(_ value: CaptureTrigger) -> String {
        switch value {
        case .cadence: "Continuous rate"
        case .interval: "Fixed interval"
        case .manual: "Capture Next only"
        default: camelLabel(value.rawValue)
        }
    }
    private var captureRuleHelp: String {
        switch exporter.configuration.trigger {
        case .cadence:
            "Samples continuously at Capture FPS. Enabled gates are checked for every scheduled frame."
        case .interval:
            "Samples once per 1 ÷ Capture FPS seconds. Enabled gates must pass at that instant."
        case .manual:
            "Waits for Capture Next; the first fully composed frame after the command is saved."
        default:
            "The event arms one capture, fulfilled by the first fully composed frame for which all gates pass."
        }
    }
    private func gateLabel(_ value: CaptureGateKind) -> String {
        camelLabel(value.rawValue)
    }
    private func camelLabel(_ value: String) -> String {
        value.replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression).capitalized
    }
}

private struct RateField: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double> = 0.001...360, suffix: String = "") {
        self.title = title; self._value = value; self.range = range; self.suffix = suffix
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, value: $value, format: .number.precision(.fractionLength(0...3)))
                    .frame(width: 86).textFieldStyle(.roundedBorder)
                    .onSubmit { value = min(range.upperBound, max(range.lowerBound, value)) }
                if !suffix.isEmpty { Text(suffix).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct PercentField: View {
    let title: String
    @Binding var value: Double

    init(_ title: String, value: Binding<Double>) {
        self.title = title; self._value = value
    }

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 3) {
                TextField(title, value: Binding(
                    get: { value * 100 },
                    set: { value = min(0.95, max(0, $0 / 100)) }
                ), format: .number.precision(.fractionLength(0...1)))
                .frame(width: 54).textFieldStyle(.roundedBorder)
                Text("%").foregroundStyle(.secondary)
            }
        }
    }
}
