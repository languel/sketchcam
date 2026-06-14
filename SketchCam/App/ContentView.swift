import SketchCamCore
import SketchCamShared
import SwiftUI

struct ContentView: View {
    private enum ControlTab: String, CaseIterable, Identifiable {
        case input = "Input"
        case layers = "Layers"
        case effect = "Effect"
        case marks = "Marks"
        case drawing = "Drawing"
        case keys = "Keys"
        case debug = "Debug"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .input: "video"
            case .layers: "square.3.layers.3d"
            case .effect: "wand.and.stars"
            case .marks: "point.3.connected.trianglepath.dotted"
            case .drawing: "scribble.variable"
            case .keys: "keyboard"
            case .debug: "ladybug"
            }
        }
    }

    @StateObject private var model = SketchCamViewModel()
    @StateObject private var windowMode = WindowModeController()
    @ObservedObject private var shortcuts = ShortcutRegistry.shared
    @State private var movieURLField = ""
    @State private var tab = ControlTab.input

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
                    case .drawing: drawingTab
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

    @ViewBuilder private var drawingTab: some View {
        Picker("Algorithm", selection: $model.settings.landmarks.drawingStyle) {
            ForEach(DrawingStyle.allCases) { style in
                Text(style.title).tag(style)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()

        Group {
            // Shared across algorithms.
            SectionHeader("Palette")
            paletteEditor
            Toggle("Match landmark colors", isOn: $model.settings.landmarks.drawingMatchesLandmarkColors)

            SectionHeader("Seed")
            HStack {
                Stepper(value: $model.settings.landmarks.seed, in: 0...99_999) {
                    Text("Seed \(model.settings.landmarks.seed)")
                        .monospacedDigit()
                }
                Button("Shuffle") { model.settings.landmarks.seed = Int.random(in: 0..<100_000) }
            }

            // Per-algorithm controls.
            switch model.settings.landmarks.drawingStyle {
            case .off:
                EmptyView()
            case .yarn:
                SectionHeader("Yarn")
                SliderRow(title: "Density", value: floatBinding(\.landmarks.subsetRatio),
                          hint: "How many points are woven — higher = denser/heavier, lower = sparser (fewer lines, more wire-like).")
                SliderRow(title: "Weave", value: floatBinding(\.landmarks.yarnWeaveAmount))
                SliderRow(title: "Width", value: floatBinding(\.landmarks.yarnWidth), range: 0.7...8)
                Toggle("Wrap the person", isOn: $model.settings.landmarks.yarnWrap)
                    .help("Weave yarn through points sampled INSIDE the person (Person silhouette / Hull / on-the-fly hull) — the figure wrapped in yarn — instead of per feature.")

                SectionHeader("Noise")
                HStack(alignment: .top, spacing: 10) {
                    XYPad(
                        x: floatBinding(\.landmarks.yarnLinear),
                        y: floatBinding(\.landmarks.yarnCircular)
                    )
                    .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("→ linear (zigzag)")
                        Text("↑ circular (loops)")
                        Text("drag the dot")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                SliderRow(title: "Winding", value: floatBinding(\.landmarks.yarnWinding), range: 1...6, precision: 1,
                          hint: "Loops per segment for the circular noise — >1 makes local tangles/coils.")
            case .lineWalk:
                SectionHeader("Line walk")
                SliderRow(title: "Continuity", value: floatBinding(\.landmarks.lineWalkContinuity),
                          hint: "One continuous line → separate semantic paths → fragmented segments")
                SliderRow(title: "Density", value: floatBinding(\.landmarks.lineWalkDensity),
                          hint: "Few points (minimal) → dense sampling with subdivided lines")
                Picker("Curve", selection: $model.settings.landmarks.lineWalkCurveFit) {
                    ForEach(CurveFit.allCases) { fit in
                        Text(fit.title).tag(fit)
                    }
                }
                .pickerStyle(.segmented)

                SectionHeader("Wildness")
                HStack(alignment: .top, spacing: 10) {
                    XYPad(
                        x: floatBinding(\.landmarks.lineWalkWildnessAlong),
                        y: floatBinding(\.landmarks.lineWalkWildnessOrtho)
                    )
                    .frame(width: 96, height: 96)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("→ along path")
                        Text("↑ orthogonal")
                        Text("drag the dot")
                            .foregroundStyle(.tertiary)
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
            }
        }
        .disabled(model.settings.landmarks.drawingStyle == .off)

        if !model.settings.landmarks.enabled {
            Text("Landmark overlay is off — enable it in Marks to draw.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Editable color list for the active drawing algorithm. Starts as one
    /// solid color; "+" adds more (algorithms cycle through them per feature).
    @ViewBuilder private var paletteEditor: some View {
        let colors = model.settings.landmarks.drawingPalette.colors
        VStack(alignment: .leading, spacing: 6) {
            ForEach(colors.indices, id: \.self) { index in
                HStack {
                    ColorPicker("", selection: paletteColorBinding(index), supportsOpacity: true)
                        .labelsHidden()
                    Text("Color \(index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if colors.count > 1 {
                        Button {
                            model.settings.landmarks.drawingPalette.colors.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
            Button {
                let last = model.settings.landmarks.drawingPalette.colors.last ?? .ink
                model.settings.landmarks.drawingPalette.colors.append(last)
            } label: {
                Label("Add color", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
        .disabled(model.settings.landmarks.drawingMatchesLandmarkColors)
    }

    private func paletteColorBinding(_ index: Int) -> Binding<Color> {
        Binding(
            get: {
                let colors = model.settings.landmarks.drawingPalette.colors
                guard colors.indices.contains(index) else { return .black }
                let c = colors[index]
                return Color(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue), opacity: Double(c.alpha))
            },
            set: { newValue in
                guard model.settings.landmarks.drawingPalette.colors.indices.contains(index),
                      let converted = NSColor(newValue).usingColorSpace(.sRGB) else { return }
                model.settings.landmarks.drawingPalette.colors[index] = RGBAColor(
                    red: Float(converted.redComponent),
                    green: Float(converted.greenComponent),
                    blue: Float(converted.blueComponent),
                    alpha: Float(converted.alphaComponent)
                )
            }
        )
    }

    // MARK: - Debug tab

    @ViewBuilder private var debugTab: some View {
        DebugGrid(stats: model.stats, permission: model.cameraPermissionState.rawValue, threshold: model.settings.threshold)

        SectionHeader("Experimental")
        Toggle("GPU drawing (Metal)", isOn: $model.settings.landmarks.useMetalDrawing)
            .help("Render Line walk strokes on the GPU instead of the CPU. Marks (dots/stick/labels) stay CPU. Watch the Overlay ms.")

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

private struct DebugGrid: View {
    let stats: DebugStats
    let permission: String
    let threshold: Float

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
                .foregroundStyle(.secondary)
            Text(value)
                .lineLimit(2)
        }
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
