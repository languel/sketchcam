import SketchCamCore
import SketchCamShared
import SwiftUI

struct ContentView: View {
    @StateObject private var model = SketchCamViewModel()

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
            Color.black
            if let previewImage = model.previewImage {
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

                Picker("Camera", selection: Binding(
                    get: { model.selectedDeviceID ?? "" },
                    set: { model.selectCamera($0.isEmpty ? nil : $0) }
                )) {
                    ForEach(model.cameraDevices) { device in
                        Text(device.name).tag(device.id)
                    }
                }

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
                SectionHeader("Effect")
                SliderRow(title: "Threshold", value: thresholdBinding)
                SliderRow(title: "Outline", value: edgeBinding)
                Toggle("Invert", isOn: $model.settings.invert)
                Toggle("Mirror", isOn: $model.settings.mirror)
                Toggle("Test pattern", isOn: $model.settings.testPatternMode)

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(value, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: 0...1)
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

