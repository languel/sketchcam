import SketchCamCore
import SketchCamShared
import SwiftUI

struct ContentView: View {
    private enum ControlTab: String, CaseIterable, Identifiable {
        case input = "Input"
        case layers = "Layers"
        case effect = "Effect"
        case marks = "Marks"
        case debug = "Debug"

        var id: String { rawValue }
    }

    @StateObject private var model = SketchCamViewModel()
    @State private var movieURLField = ""
    @State private var tab = ControlTab.input

    var body: some View {
        HStack(spacing: 0) {
            previewPane
            Divider()
            controlsPane
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: - Preview

    private var previewPane: some View {
        ZStack {
            // Checkerboard backdrop so an Alpha background (or ink-only
            // threshold) is visibly transparent in the preview instead of
            // reading as black.
            CheckerboardBackground()
            if !model.settings.previewEnabled {
                Text("Preview off — still publishing")
                    .foregroundStyle(.secondary)
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
                    Text(tab.rawValue).tag(tab)
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
            .keyboardShortcut("f", modifiers: .command)
            .help("Freeze live input / pause movie (⌘F)")
            Button {
                model.exportCurrentFrame()
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .keyboardShortcut("e", modifiers: .command)
            .help("Export current frame as PNG (⌘E)")
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
        } else {
            HStack {
                Button("Open Movie…") { model.openMoviePanel() }
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
        Picker("Processing", selection: $model.settings.processingQuality) {
            ForEach(ProcessingQuality.allCases) { quality in
                Text(quality.title).tag(quality)
            }
        }
        .pickerStyle(.segmented)

        SectionHeader("Preview")
        Picker("Mode", selection: $model.settings.previewMode) {
            ForEach(PreviewMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Toggle("Show preview", isOn: $model.settings.previewEnabled)

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
            Picker("Style", selection: $model.settings.landmarks.visualizationMode) {
                ForEach(LandmarkVisualizationMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            SectionHeader("Features")
            StyleRow(
                title: "Face",
                enabled: $model.settings.landmarks.trackFace,
                color: rgbaBinding(\.landmarks.faceStyle.color),
                size: floatBinding(\.landmarks.faceStyle.size),
                range: 0.7...8
            )
            StyleRow(
                title: "Body",
                enabled: $model.settings.landmarks.trackBody,
                color: rgbaBinding(\.landmarks.bodyStyle.color),
                size: floatBinding(\.landmarks.bodyStyle.size),
                range: 0.7...8
            )
            StyleRow(
                title: "Hands",
                enabled: $model.settings.landmarks.trackHands,
                color: rgbaBinding(\.landmarks.handsStyle.color),
                size: floatBinding(\.landmarks.handsStyle.size),
                range: 0.7...8
            )
            StyleRow(
                title: "Eyes",
                enabled: $model.settings.landmarks.trackEyesAndIrises,
                color: rgbaBinding(\.landmarks.eyesStyle.color),
                size: floatBinding(\.landmarks.eyesStyle.size),
                range: 0.7...8
            )

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
            ), range: 1...15, precision: 0)
            SliderRow(title: "Detail", value: floatBinding(\.landmarks.subsetRatio))
            SliderRow(title: "Weave", value: floatBinding(\.landmarks.yarnWeaveAmount))
        }
        .disabled(!model.settings.landmarks.enabled)
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

    // MARK: - Bindings

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
