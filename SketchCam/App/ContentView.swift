import AppKit
import SketchCamCore
import SketchCamShared
import SwiftUI

final class AppUIState: ObservableObject {
    @Published var debugOverlayVisible = false

    func toggleDebugOverlay() {
        debugOverlayVisible.toggle()
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
    private enum ControlTab: String, CaseIterable, Identifiable {
        case input = "Settings"
        case layers = "Layers"
        case effect = "Effect"
        case marks = "Marks"
        case yarn = "Yarn"
        case wrap = "Wrap"
        case lineWalk = "Line walk"
        case ink = "Ink"
        case web = "Web"
        case presets = "Presets"
        case keys = "Keys"
        case debug = "Debug"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .input: "gearshape"
            case .layers: "square.3.layers.3d"
            case .effect: "wand.and.stars"
            case .marks: "point.3.connected.trianglepath.dotted"
            case .yarn: "scribble.variable"
            case .wrap: "figure.stand"
            case .lineWalk: "lasso"
            case .ink: "paintbrush.pointed"
            case .web: "globe"
            case .presets: "bookmark"
            case .keys: "keyboard"
            case .debug: "ladybug"
            }
        }
    }

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
    @State private var tab = ControlTab.input
    @State private var inkTool = InkTool.draw
    @State private var selectedInkPathID: UUID?
    @State private var selectedInkPointIndex: Int?
    @State private var inkHUDVisible = false
    @State private var debugOverlayOffset = CGSize.zero
    @State private var inkUndoStack: [[InkEditorPath]] = []
    @State private var inkRedoStack: [[InkEditorPath]] = []

    var body: some View {
        previewPane
            .overlay {
                // Tray overlay inside a GeometryReader: GeometryReader
                // reports no minimum size, so the 360pt panel can never
                // constrain how small the window may shrink (PIP).
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
                if appUI.debugOverlayVisible {
                    DebugOverlay(
                        stats: model.stats,
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
        .background(windowMode.transparent ? Color.clear : Color(nsColor: .windowBackgroundColor))
        .background(WindowAccessor(controller: windowMode))
        .onAppear {
            model.start()
            registerShortcuts()
            ShortcutRegistry.shared.start()
        }
        .onDisappear { model.stop() }
    }

    // MARK: - Preview

    private var previewPane: some View {
        GeometryReader { geo in
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
                } else if model.settings.useMetalPreview, model.settings.previewMode != .split {
                    // Zero-readback GPU display (also the presentation-mode output).
                    SampleBufferDisplayView(controller: model.previewDisplay)
                } else if let previewImage = model.previewImage {
                    Image(previewImage, scale: 1, label: Text("SketchCam preview"))
                        .resizable()
                        .interpolation(.none)
                        .aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                if tab == .ink, model.settings.landmarks.inkEnabled {
                    InkPreviewDrawingLayer(
                        paths: inkPathsBinding,
                        showLivePath: model.settings.landmarks.inkShowLivePath,
                        immediatePen: model.settings.landmarks.inkImmediatePen,
                        immediateWash: model.settings.landmarks.inkImmediateWash,
                        onLive: { model.updateInkLiveStroke($0) },
                        onLiveEnd: { model.endInkLiveStroke() },
                        outputSize: model.outputFormat.size,
                        inkColor: rgbaColor(model.settings.landmarks.inkColor),
                        inkRGBA: model.settings.landmarks.inkColor,
                        tool: inkTool,
                        brushMode: currentInkMode,
                        inkKind: currentInkKind,
                        width: Float(inkSizeBinding.wrappedValue),
                        flow: model.settings.landmarks.inkFlow,
                        bleed: model.settings.landmarks.inkBleed,
                        dry: model.settings.landmarks.inkDry,
                        colorSeparation: Float(inkColorSeparationBinding.wrappedValue),
                        brushInk: Float(inkBrushInkBinding.wrappedValue),
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
                        clear: clearInk,
                        save: model.exportCurrentFrame
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
    }

    // MARK: - Controls

    private var controlsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            Picker("", selection: $tab) {
                ForEach(ControlTab.allCases) { tab in
                    Image(systemName: tab.icon)
                        .help(tab.rawValue)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch tab {
                    case .input: inputTab
                    case .layers: layersTab
                    case .effect: effectTab
                    case .marks: marksTab
                    case .yarn: yarnTab
                    case .wrap: wrapTab
                    case .lineWalk: lineWalkTab
                    case .ink: inkTab
                    case .web: webTab
                    case .presets: presetsTab
                    case .keys: keysTab
                    case .debug: debugTab
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 360)
    }

    /// Always-visible actions with their shortcuts.
    private var actionBar: some View {
        HStack(spacing: 8) {
            Text("SketchCam")
                .font(.headline)
            Spacer()
            Button {
                model.toggleFreezeOrPause()
            } label: {
                Label(
                    freezeButtonTitle,
                    systemImage: isHeld ? "play.fill" : "pause.fill"
                )
            }
            .help("Freeze live input / pause movie")
            Button {
                model.exportCurrentFrame()
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .help("Export current frame as PNG")
            Button {
                appUI.toggleDebugOverlay()
            } label: {
                Label(
                    "Performance",
                    systemImage: appUI.debugOverlayVisible ? "chart.line.uptrend.xyaxis.circle.fill" : "chart.line.uptrend.xyaxis.circle"
                )
            }
            .help("Toggle performance overlay (Control-Option-P)")
        }
        .controlSize(.small)
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

    // MARK: - Input tab

    @ViewBuilder private var inputTab: some View {
        Picker("Source", selection: $model.frameSource) {
            ForEach(SketchCamViewModel.FrameSource.allCases) { source in
                Text(source.title).tag(source)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        if model.frameSource == .camera {
            Picker("Camera", selection: Binding(
                get: { model.selectedDeviceID ?? "" },
                set: { model.selectCamera($0.isEmpty ? nil : $0) }
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
        } else {
            HStack {
                Button("Open Movie…") { model.openMoviePanel() }
                Button("Demo clip") { model.loadDemoClip() }
                Text(model.movieURL?.lastPathComponent ?? "No movie selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack {
                TextField("https://… (stream URL)", text: $movieURLField)
                    .textFieldStyle(.roundedBorder)
                Button("Load") { model.openMovieURL(movieURLField) }
                    .disabled(movieURLField.isEmpty)
            }
            SliderRow(title: "Speed", value: $model.movieRate, range: 0...2, hint: "0 pauses")
        }

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
        ), range: 0...60, precision: 0, hint: "0 = full-tilt (every published frame)")

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

    // MARK: - Layers tab

    @ViewBuilder private var layersTab: some View {
        Toggle("Live input layer", isOn: $model.settings.inputLayerEnabled)
            .onChange(of: model.settings.inputLayerEnabled) { _, enabled in
                // With the input layer off, a "Live" background would still
                // show the raw video — switch to a real canvas.
                if !enabled, model.settings.backgroundMode == .live {
                    model.settings.backgroundMode = .solid
                }
            }

        SectionHeader("Background")
        Picker("Background", selection: $model.settings.backgroundMode) {
            ForEach(BackgroundMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        ColorPicker("Color", selection: rgbaBinding(\.backgroundColor), supportsOpacity: true)
            .disabled(model.settings.backgroundMode != .solid)

        SectionHeader("Person Key")
        Toggle("Person key (Vision)", isOn: $model.settings.segmentation.enabled)
            .onChange(of: model.settings.segmentation.enabled) { _, enabled in
                // Keying against a live background is a visual no-op;
                // default to replacing the background when enabled.
                if enabled, model.settings.backgroundMode == .live {
                    model.settings.backgroundMode = .solid
                }
            }
        Group {
            Picker("Quality", selection: $model.settings.segmentation.quality) {
                ForEach(SegmentationQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }
            .pickerStyle(.segmented)
            Picker("Mode", selection: $model.settings.segmentation.mode) {
                ForEach(SegmentationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Toggle("Invert key", isOn: $model.settings.segmentation.inverted)
            if model.settings.segmentation.mode == .silhouette {
                ColorPicker("Silhouette", selection: rgbaBinding(\.segmentation.silhouetteColor), supportsOpacity: true)
            }
        }
        .disabled(!model.settings.segmentation.enabled)
    }

    // MARK: - Effect tab

    @ViewBuilder private var effectTab: some View {
        Toggle("Effects (master)", isOn: $model.settings.effectsEnabled)
        Group {
            SectionHeader("Threshold")
            Toggle("Threshold layer", isOn: $model.settings.thresholdEnabled)
            SliderRow(title: "Level", value: floatBinding(\.threshold))
            Toggle("Ink only (transparent paper)", isOn: $model.settings.thresholdInkOnly)
            Toggle("Invert", isOn: $model.settings.invert)

            SectionHeader("Outline")
            Toggle("Outline layer", isOn: $model.settings.outlineEnabled)
            SliderRow(title: "Strength", value: floatBinding(\.edgeStrength))
            StyleRow(
                title: "Stroke",
                color: rgbaBinding(\.outlineColor),
                size: floatBinding(\.outlineThickness),
                range: 0...24
            )
        }
        .disabled(!model.settings.effectsEnabled)

        SectionHeader("Frame")
        Toggle("Mirror", isOn: $model.settings.mirror)
        Toggle("Test pattern", isOn: $model.settings.testPatternMode)
    }

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
            SliderRow(title: "Detail", value: floatBinding(\.landmarks.contourDetail),
                      hint: "Person silhouette contour (Vision segmentation). Independent of Layers keying — tracks the outline without the keying composite. Coarse → fine (hugs concavities).")
                .disabled(!model.settings.landmarks.trackContour)
            featureRow("Hull", track: \.landmarks.trackBodyHull, style: \.landmarks.bodyHullStyle)
                .help("Seg-free person outline: convex hull of the tracked landmarks. No segmentation cost, cruder than Person (can't enter concavities). Use alongside Person or on its own.")

            SectionHeader("Labels")
            Toggle("Show IDs", isOn: $model.settings.landmarks.showIDs)
            SliderRow(title: "Size", value: floatBinding(\.landmarks.labelSize), range: 6...24)
                .disabled(!model.settings.landmarks.showIDs)
            Toggle("Match feature colors", isOn: $model.settings.landmarks.labelsMatchColor)
                .disabled(!model.settings.landmarks.showIDs)

            SectionHeader("Detection")
            SliderRow(title: "Rate (Hz)", value: Binding(
                get: { model.settings.landmarks.detectionsPerSecond },
                set: { model.settings.landmarks.detectionsPerSecond = $0.rounded() }
            ), range: 1...30, precision: 0)
            SliderRow(title: "Input px", value: Binding(
                get: { Double(model.settings.landmarks.detectionMaxDimension) },
                set: { model.settings.landmarks.detectionMaxDimension = max(96, Int(($0 / 32).rounded()) * 32) }
            ), range: 128...512, precision: 0,
               hint: "Longest side of the frame handed to Vision (snaps to /32; e.g. 256). NOTE: Vision resizes to a fixed internal size, so this mainly affects precision, NOT speed — to cut detection cost, track fewer categories or lower Rate.")
            Toggle("Predict motion (smooth tracking)", isOn: $model.settings.landmarks.predictiveTracking)
                .help("Extrapolate landmark motion and redraw every frame so the drawing tracks at frame rate and lags the body less — without raising the detection rate.")
            SliderRow(title: "Dot size", value: floatBinding(\.landmarks.dotScale), range: 0.2...4)
            SliderRow(title: "Stick width", value: floatBinding(\.landmarks.stickScale), range: 0.2...4)
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
            SliderRow(title: "Density", value: floatBinding(\.landmarks.subsetRatio),
                      hint: "How many points are woven — higher = denser/heavier, lower = sparser.")
            SliderRow(title: "Weave", value: floatBinding(\.landmarks.yarnWeaveAmount))
            SliderRow(title: "Width", value: floatBinding(\.landmarks.yarnWidth), range: 0.7...8)
            SliderRow(title: "Variation", value: floatBinding(\.landmarks.yarnWidthVariation),
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
            SliderRow(title: "Winding", value: floatBinding(\.landmarks.yarnWinding), range: 1...6, precision: 1,
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
            SliderRow(title: "Density", value: floatBinding(\.landmarks.wrapDensity),
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
            SliderRow(title: "Scale", value: floatBinding(\.landmarks.wrapScale),
                      hint: "Local (fine) → global (coarse, whole-wire drift)")

            SectionHeader("Loops")
            SliderRow(title: "Loop", value: floatBinding(\.landmarks.wrapCircular),
                      hint: "Coil/loop amplitude along the wire.")
            SliderRow(title: "Winding", value: floatBinding(\.landmarks.wrapWinding), range: 1...6, precision: 1,
                      hint: "Loops per segment — >1 makes tangles.")
            SliderRow(title: "Width", value: floatBinding(\.landmarks.wrapWidth), range: 0.7...8)
            SliderRow(title: "Variation", value: floatBinding(\.landmarks.wrapWidthVariation),
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
            SliderRow(title: "Continuity", value: floatBinding(\.landmarks.lineWalkContinuity),
                      hint: "One continuous line → separate semantic paths → fragmented segments")
            SliderRow(title: "Density", value: floatBinding(\.landmarks.lineWalkDensity),
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
            SliderRow(title: "Scale", value: floatBinding(\.landmarks.lineWalkScale),
                      hint: "Local (fine, per sub-stroke) → global (coarse, whole-line drift)")

            SectionHeader("Stroke")
            SliderRow(title: "Width", value: floatBinding(\.landmarks.lineWalkWidth), range: 0.4...8)
            SliderRow(title: "Variation", value: floatBinding(\.landmarks.lineWalkWidthVariation),
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
        Group {
            SectionHeader("Layer")
            Picker("Placement", selection: $model.settings.landmarks.inkPlacement) {
                ForEach(WebLayerPlacement.allCases) { placement in
                    Text(placement.title).tag(placement)
                }
            }
            .pickerStyle(.segmented)
            SliderRow(title: "Opacity", value: floatBinding(\.landmarks.inkOpacity))

            SectionHeader("Editor")
            Picker("Tool", selection: $inkTool) {
                ForEach(InkTool.allCases) { tool in
                    Label(tool.rawValue, systemImage: tool.icon).tag(tool)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            InkEditorCanvas(
                paths: inkPathsBinding,
                paperColor: rgbaColor(model.settings.landmarks.inkPaperColor),
                inkColor: rgbaColor(model.settings.landmarks.inkColor),
                inkRGBA: model.settings.landmarks.inkColor,
                brushMode: currentInkMode,
                inkKind: currentInkKind,
                width: Float(inkSizeBinding.wrappedValue),
                flow: model.settings.landmarks.inkFlow,
                bleed: model.settings.landmarks.inkBleed,
                dry: model.settings.landmarks.inkDry,
                colorSeparation: Float(inkColorSeparationBinding.wrappedValue),
                brushInk: Float(inkBrushInkBinding.wrappedValue)
            )
                .frame(height: 180)
                .help("Scratchpad view of the same full-canvas strokes. You can also draw directly on the preview while this tab is selected.")

            HStack {
                Button {
                    clearInk()
                } label: {
                    Label("Clear", systemImage: "trash")
                }
                .help("Wipe the canvas (committed paths and immediate-mode marks).")
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
                .disabled(model.settings.landmarks.inkPaths.isEmpty)
                .help("Clear and re-simulate every committed path from scratch (with the current curve/params). Immediate-mode marks are not re-simulated.")
                Text("\(model.settings.landmarks.inkPaths.count) paths")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .controlSize(.small)
            Toggle("Show live cursor path", isOn: $model.settings.landmarks.inkShowLivePath)
                .help("Thin dashed guide tracking the cursor while the rendered ink catches up. Off by default.")
            SliderRow(title: "Smoothing", value: floatBinding(\.landmarks.inkSmoothing),
                      hint: "Rounds the stroke as you draw — higher = smoother/laggier. Hold Shift while drawing for extra smoothing.")

            SectionHeader("Pen / Wash")
            Picker("Mode", selection: inkModeBinding) {
                ForEach(InkBrushMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Immediate pen", isOn: $model.settings.landmarks.inkImmediatePen)
                Toggle("Immediate wash", isOn: $model.settings.landmarks.inkImmediateWash)
            }
            .help("Immediate mode paints straight onto the canvas without adding an editable path — good for experimenting without filling the path buffer. These marks aren't selectable, editable, or re-rendered.")
            SliderRow(title: "Smear", value: floatBinding(\.landmarks.inkSmearStrength),
                      hint: "Immediate-wash push strength — how aggressively the wet brush re-mobilizes and drags dried ink. Hold the mouse still before dragging to 'charge' an extra-strong push.")
            Picker("Ink", selection: inkKindBinding) {
                ForEach(InkKind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .pickerStyle(.segmented)
            ColorPicker("Ink", selection: rgbaBinding(\.landmarks.inkColor), supportsOpacity: true)
            SliderRow(title: "Size", value: inkSizeBinding)
            SliderRow(title: "Flow", value: floatBinding(\.landmarks.inkFlow))
            SliderRow(title: "Bleed", value: floatBinding(\.landmarks.inkBleed))
            SliderRow(title: "Dry", value: floatBinding(\.landmarks.inkDry))
            SliderRow(title: "Color", value: inkColorSeparationBinding)
            SliderRow(title: "Brush ink", value: inkBrushInkBinding)
            Picker("Curve", selection: $model.settings.landmarks.inkCurveFit) {
                ForEach(CurveFit.allCases) { fit in Text(fit.title).tag(fit) }
            }
            .pickerStyle(.segmented)
            seedRow(\.landmarks.inkSeed)

            SectionHeader("Paper")
            Toggle("Paper layer", isOn: $model.settings.landmarks.inkPaperEnabled)
            ColorPicker("Paper", selection: rgbaBinding(\.landmarks.inkPaperColor), supportsOpacity: true)
                .disabled(!model.settings.landmarks.inkPaperEnabled)
            SliderRow(title: "Grain", value: floatBinding(\.landmarks.inkPaperGrain))
                .disabled(!model.settings.landmarks.inkPaperEnabled)
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
        setInkPaths([])
        // Force a rebuild so the canvas is wiped even when there were no
        // committed paths (e.g. only immediate-mode marks).
        model.settings.landmarks.inkRebuildRevision += 1
        clearInkSelection()
    }

    private func fixInk() {
        model.settings.landmarks.inkFixRevision = (model.settings.landmarks.inkFixRevision ?? 0) + 1
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

    private func undoInk() {
        guard let previous = inkUndoStack.popLast() else { return }
        model.cancelInkLiveStroke()
        inkRedoStack.append(model.settings.landmarks.inkPaths)
        model.settings.landmarks.inkPaths = previous
        clearInkSelection()
    }

    private func redoInk() {
        guard let next = inkRedoStack.popLast() else { return }
        model.cancelInkLiveStroke()
        inkUndoStack.append(model.settings.landmarks.inkPaths)
        model.settings.landmarks.inkPaths = next
        clearInkSelection()
    }

    private func setInkPaths(_ paths: [InkEditorPath]) {
        model.cancelInkLiveStroke()
        let old = model.settings.landmarks.inkPaths
        guard old != paths else { return }
        inkUndoStack.append(old)
        if inkUndoStack.count > 80 {
            inkUndoStack.removeFirst(inkUndoStack.count - 80)
        }
        inkRedoStack.removeAll()
        model.settings.landmarks.inkPaths = paths
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
            get: { Double(min(1, max(0, model.settings.landmarks.inkWidth))) },
            set: { model.settings.landmarks.inkWidth = Float($0) }
        )
    }

    private var inkColorSeparationBinding: Binding<Double> {
        optionalLandmarkFloatBinding(\.inkColorSeparation, defaultValue: 0.5)
    }

    private var inkBrushInkBinding: Binding<Double> {
        optionalLandmarkFloatBinding(\.inkBrushInk, defaultValue: 0)
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
            SliderRow(title: "Opacity", value: floatBinding(\.web.opacity))
            SliderRow(title: "Refresh fps", value: floatBinding(\.web.refreshFPS), range: 1...60, precision: 0,
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
    }

    private func saveCurrentPreset() {
        presetStore.save(name: newPresetName, settings: model.settings)
        newPresetName = ""
    }

    // MARK: - Debug tab

    @ViewBuilder private var debugTab: some View {
        DebugGrid(stats: model.stats, permission: model.cameraPermissionState.rawValue, threshold: model.settings.threshold)


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
        r.register(id: "window.panel", title: "Toggle Side Panel", category: "Window",
                   default: KeyBinding(key: "u", modifiers: [.command, .option])) { [weak windowMode] in windowMode?.panelVisible.toggle() }
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
                   default: KeyBinding(key: "d", modifiers: [])) {
            guard tab == .ink else { return }
            fixInk()
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

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1
    var precision: Int = 2
    var hint: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 64, alignment: .leading)
            Slider(value: $value, in: range)
                .controlSize(.small)
            Text(value, format: .number.precision(.fractionLength(precision)))
                .monospacedDigit()
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .help(hint ?? title)
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
    let save: () -> Void

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
                hudSlider("size", value: $size)
                hudSlider("flow", value: $flow)
                hudSlider("bleed", value: $bleed)
                hudSlider("dry", value: $dry)
                hudSlider("color", value: $colorSeparation)
                hudSlider("brush ink", value: $brushInk)
                command("fix", action: fix)
                command("clear", action: clear)
                command("save", action: save)
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

    private func hudSlider(_ label: String, value: Binding<Double>) -> some View {
        VStack(spacing: 7) {
            Text(label)
                .hudLabel()
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
    var shift: Bool
    var charge: Float
}

private struct InkCanvasEventOverlay: NSViewRepresentable {
    var onChanged: (InkCanvasDragValue) -> Void
    var onEnded: (Bool) -> Void

    func makeNSView(context: Context) -> EventView {
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
            begin(event, secondary: false)
        }

        override func mouseDragged(with event: NSEvent) {
            update(event)
        }

        override func mouseUp(with event: NSEvent) {
            finish(event)
        }

        override func rightMouseDown(with event: NSEvent) {
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
            onChanged?(InkCanvasDragValue(location: point, startLocation: point, secondary: secondary, shift: event.modifierFlags.contains(.shift), charge: 0))
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
            onChanged?(InkCanvasDragValue(location: point, startLocation: start, secondary: secondaryDrag, shift: event.modifierFlags.contains(.shift), charge: dragCharge))
        }

        private func finish(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            onChanged?(InkCanvasDragValue(location: point, startLocation: startLocation ?? point, secondary: secondaryDrag, shift: event.modifierFlags.contains(.shift), charge: dragCharge))
            onEnded?(true)
            startLocation = nil
            secondaryDrag = false
            chargeLocked = false
            dragCharge = 0
        }
    }
}

private struct InkPreviewDrawingLayer: View {
    @Binding var paths: [InkEditorPath]
    let showLivePath: Bool
    let immediatePen: Bool
    let immediateWash: Bool
    let onLive: (InkLiveStrokeSample) -> Void
    let onLiveEnd: () -> Void
    let outputSize: CGSize
    let inkColor: Color
    let inkRGBA: RGBAColor
    let tool: InkTool
    let brushMode: InkBrushMode
    let inkKind: InkKind
    let width: Float
    let flow: Float
    let bleed: Float
    let dry: Float
    let colorSeparation: Float
    let brushInk: Float
    @Binding var selectedPathID: UUID?
    @Binding var selectedPointIndex: Int?
    @State private var current: [CGPoint] = []
    @State private var currentPathID: UUID?
    @State private var currentStrokeMode: InkBrushMode?
    @State private var dragStartPaths: [InkEditorPath] = []
    @State private var dragStartPoint: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let rect = fittedRect(container: geo.size, content: outputSize)
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
                if showLivePath, !current.isEmpty {
                    strokedPath(current, in: rect)
                        .stroke(inkColor.opacity(0.5), style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round, dash: [4, 4]))
                }
                InkCanvasEventOverlay(
                    onChanged: { value in
                        guard rect.contains(value.location) else { return }
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
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func handleDragChanged(_ value: InkCanvasDragValue, in rect: CGRect) {
        let p = normalized(value.location, in: rect)
        switch tool {
        case .draw:
            selectedPathID = nil
            selectedPointIndex = nil
            updateLiveStroke(with: p, secondary: value.secondary, shift: value.shift, charge: value.charge)
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
        // Immediate mode: the live ink is already baked onto the canvas — keep
        // it, but don't add an editable path (so the buffer doesn't grow).
        if tool == .draw, committed, current.count > 1, !immediate {
            paths.append(InkEditorPath(
                id: currentPathID ?? UUID(),
                points: current,
                brushMode: currentStrokeMode ?? brushMode,
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
        onLiveEnd()
        current = []
        currentPathID = nil
        currentStrokeMode = nil
        dragStartPaths = []
        dragStartPoint = nil
    }

    private func updateLiveStroke(with point: CGPoint, secondary: Bool, shift: Bool, charge: Float) {
        // Per move we send the latest point + params to the engine; the channel
        // accumulates every point so the engine injects along all of them
        // (dense). `current` accumulates locally for the committed path + dashed
        // guide. This never touches the @Published settings struct.
        if current.isEmpty {
            let id = UUID()
            currentPathID = id
            currentStrokeMode = secondary ? .brush : brushMode
            current = [point]
            onLive(makeSample(id: id, point: point, shift: shift, charge: charge))
            return
        }
        if current.last.map({ hypot($0.x - point.x, $0.y - point.y) > 0.0015 }) ?? true {
            current.append(point)
        }
        onLive(makeSample(id: currentPathID ?? UUID(), point: point, shift: shift, charge: charge))
    }

    private func makeSample(id: UUID, point: CGPoint, shift: Bool, charge: Float) -> InkLiveStrokeSample {
        let strokeMode = currentStrokeMode ?? brushMode
        return InkLiveStrokeSample(
            id: id,
            point: point,
            brushMode: strokeMode,
            inkKind: inkKind,
            width: width,
            flow: flow,
            brushInk: brushInk,
            color: inkRGBA,
            smoothBoost: shift,
            destructive: strokeMode == .brush && immediateWash,
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
        CGPoint(
            x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
            y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height)))
        )
    }

    private func selectionBounds(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        guard !points.isEmpty else { return path }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        let inset: CGFloat = 0.008
        path.addRect(CGRect(
            x: rect.minX + (minX - inset) * rect.width,
            y: rect.minY + (minY - inset) * rect.height,
            width: (maxX - minX + inset * 2) * rect.width,
            height: (maxY - minY + inset * 2) * rect.height
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
