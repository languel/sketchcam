import SketchCamCore
import SketchCamShared
import SwiftUI

struct ContentView: View {
    @StateObject private var model = SketchCamViewModel()
    @State private var movieURLField = ""

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

    private var controlsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionHeader("SketchCam")

                Picker("Source", selection: $model.frameSource) {
                    ForEach(SketchCamViewModel.FrameSource.allCases) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                if model.frameSource == .camera {
                    Picker("Camera", selection: Binding(
                        get: { model.selectedDeviceID ?? "" },
                        set: { model.selectCamera($0.isEmpty ? nil : $0) }
                    )) {
                        ForEach(model.cameraDevices) { device in
                            Text(device.name).tag(device.id)
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
                        TextField("https://… (stream or media URL)", text: $movieURLField)
                            .textFieldStyle(.roundedBorder)
                        Button("Load") { model.openMovieURL(movieURLField) }
                            .disabled(movieURLField.isEmpty)
                    }
                    SliderRow(title: "Speed (0 = pause)", value: $model.movieRate, range: 0...2)
                }
                Toggle("Freeze input", isOn: $model.inputFrozen)

                Picker("Output", selection: $model.outputFormat) {
                    ForEach(SketchCamFormats.all) { format in
                        Text(format.displayName).tag(format)
                    }
                }

                Picker("Preview", selection: $model.settings.previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Divider()
                SectionHeader("Layers")
                Toggle("Live input layer", isOn: $model.settings.inputLayerEnabled)
                    .onChange(of: model.settings.inputLayerEnabled) { _, enabled in
                        // With the input layer off, a "Live" background would
                        // still show the raw video — switch to a real canvas.
                        if !enabled, model.settings.backgroundMode == .live {
                            model.settings.backgroundMode = .solid
                        }
                    }
                Picker("Background", selection: $model.settings.backgroundMode) {
                    ForEach(BackgroundMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                ColorPicker("Background color", selection: backgroundColorBinding, supportsOpacity: true)
                    .disabled(model.settings.backgroundMode != .solid)
                Toggle("Person key (Vision)", isOn: $model.settings.segmentation.enabled)
                    .onChange(of: model.settings.segmentation.enabled) { _, enabled in
                        // Keying against a live background is a visual no-op;
                        // default to replacing the background when enabled.
                        if enabled, model.settings.backgroundMode == .live {
                            model.settings.backgroundMode = .solid
                        }
                    }
                if model.settings.segmentation.enabled {
                    Picker("Key quality", selection: $model.settings.segmentation.quality) {
                        ForEach(SegmentationQuality.allCases) { quality in
                            Text(quality.title).tag(quality)
                        }
                    }
                    .pickerStyle(.segmented)
                    Picker("Key mode", selection: $model.settings.segmentation.mode) {
                        ForEach(SegmentationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Invert key", isOn: $model.settings.segmentation.inverted)
                    if model.settings.segmentation.mode == .silhouette {
                        ColorPicker("Silhouette color", selection: silhouetteColorBinding, supportsOpacity: true)
                    }
                }

                Divider()
                SectionHeader("Effect")
                Toggle("Effects (master)", isOn: $model.settings.effectsEnabled)
                Group {
                    Toggle("Threshold layer", isOn: $model.settings.thresholdEnabled)
                    SliderRow(title: "Threshold", value: thresholdBinding)
                    Toggle("Ink only (transparent paper)", isOn: $model.settings.thresholdInkOnly)
                    Toggle("Outline layer", isOn: $model.settings.outlineEnabled)
                    SliderRow(title: "Outline", value: edgeBinding)
                    SliderRow(title: "Thickness", value: outlineThicknessBinding, range: 0...24)
                    ColorPicker("Stroke color", selection: outlineColorBinding, supportsOpacity: true)
                    Toggle("Invert", isOn: $model.settings.invert)
                }
                .disabled(!model.settings.effectsEnabled)
                Toggle("Mirror", isOn: $model.settings.mirror)
                Toggle("Test pattern", isOn: $model.settings.testPatternMode)

                Divider()
                SectionHeader("Performance")
                Picker("Input", selection: $model.inputResolution) {
                    ForEach(CameraInputResolution.allCases) { resolution in
                        Text(resolution.title).tag(resolution)
                    }
                }
                Picker("Processing", selection: $model.settings.processingQuality) {
                    ForEach(ProcessingQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Preview", isOn: $model.settings.previewEnabled)

                Divider()
                SectionHeader("Landmarks")
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
                    HStack {
                        Toggle("Face", isOn: $model.settings.landmarks.trackFace)
                        Toggle("Body", isOn: $model.settings.landmarks.trackBody)
                        Toggle("Hands", isOn: $model.settings.landmarks.trackHands)
                        Toggle("Eyes", isOn: $model.settings.landmarks.trackEyesAndIrises)
                    }
                    .toggleStyle(.checkbox)
                    Toggle("Show IDs", isOn: $model.settings.landmarks.showIDs)
                    SliderRow(title: "Rate (Hz)", value: detectionRateBinding, range: 1...15)
                    SliderRow(title: "Detail", value: subsetBinding)
                    SliderRow(title: "Stroke", value: strokeBinding, range: 0.7...6)
                }
                .disabled(!model.settings.landmarks.enabled)

                Divider()
                SectionHeader("Camera Extension")
                HStack {
                    Button {
                        model.activateExtension()
                    } label: {
                        Label("Activate", systemImage: "checkmark.circle")
                    }
                    Button {
                        model.deactivateExtension()
                    } label: {
                        Label("Deactivate", systemImage: "xmark.circle")
                    }
                }
                Text(model.activationManager.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                SectionHeader("Debug")
                DebugGrid(stats: model.stats, permission: model.cameraPermissionState.rawValue, threshold: model.settings.threshold)
                if let error = model.errorText {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .frame(width: 340)
    }

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.threshold) },
            set: { model.settings.threshold = Float($0) }
        )
    }

    private var outlineThicknessBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.outlineThickness) },
            set: { model.settings.outlineThickness = Float($0) }
        )
    }

    private var outlineColorBinding: Binding<Color> {
        rgbaBinding(\.outlineColor)
    }

    private var silhouetteColorBinding: Binding<Color> {
        rgbaBinding(\.segmentation.silhouetteColor)
    }

    private var backgroundColorBinding: Binding<Color> {
        rgbaBinding(\.backgroundColor)
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

    private var detectionRateBinding: Binding<Double> {
        Binding(
            get: { model.settings.landmarks.detectionsPerSecond },
            set: { model.settings.landmarks.detectionsPerSecond = $0.rounded() }
        )
    }

    private var subsetBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.landmarks.subsetRatio) },
            set: { model.settings.landmarks.subsetRatio = Float($0) }
        )
    }

    private var strokeBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.landmarks.yarnStrokeWidth) },
            set: { model.settings.landmarks.yarnStrokeWidth = Float($0) }
        )
    }

    private var edgeBinding: Binding<Double> {
        Binding(
            get: { Double(model.settings.edgeStrength) },
            set: { model.settings.edgeStrength = Float($0) }
        )
    }
}

private struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.headline)
    }
}

private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...1

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
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
