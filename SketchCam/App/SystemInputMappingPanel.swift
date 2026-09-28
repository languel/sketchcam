import AppKit
import Foundation
import SwiftUI

struct SystemInputMappingPanel: View {
    @ObservedObject private var pointer: SystemPointerController
    private let prepareCanvas: () -> Bool

    init(model: SketchCamViewModel) {
        _pointer = ObservedObject(wrappedValue: model.systemPointer)
        prepareCanvas = { model.prepareMotionCanvas() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MOTION CONTROL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(pointer.live.status)
                            .font(.caption2).foregroundStyle(pointer.isArmed ? Color.accentColor : Color.secondary)
                    }
                    Spacer()
                    Button(pointer.isArmed ? "Disarm" : "Arm") {
                        if pointer.isArmed {
                            pointer.disarm()
                        } else {
                            if pointer.mapping.destination == .canvas && !prepareCanvas() {
                                pointer.showCanvasUnavailable()
                            } else {
                                _ = pointer.arm()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(pointer.isArmed ? .red : .accentColor)
                }

                Picker("Destination", selection: Binding(
                    get: { pointer.mapping.destination ?? .computer },
                    set: { pointer.usePreset($0) }
                )) {
                    ForEach(MotionControlDestination.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Canvas paints into the active Ink frame without Accessibility access. Computer sends system mouse and keyboard events. Switching or editing rules disarms control.")

                if !pointer.isTrusted && pointer.mapping.destination != .canvas {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "hand.raised.fill")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Accessibility permission required")
                                .font(.caption.weight(.semibold))
                            Text("Approve the installed /Applications/SketchCam.app once. Normal rebuilds now keep the same signed app identity.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            HStack {
                                Button("Request access") { pointer.requestAccessibility() }
                                Button("Open Settings") { pointer.openAccessibilitySettings() }
                                Button("Refresh") { pointer.refreshTrust() }
                            }
                            .controlSize(.small)
                        }
                    }
                    .padding(7)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.08)))
                }

                section("POINTER FEATURE") {
                    MediaPipeHomunculusMap(selection: $pointer.mapping.pointer)
                        .frame(minHeight: 275)
                    HStack {
                        Text(pointer.mapping.pointer.title).font(.caption)
                        Spacer()
                        if pointer.live.featureAvailable {
                            Label("live", systemImage: "circle.fill")
                                .font(.caption2).foregroundStyle(.green)
                        }
                    }
                }

                section("BEHAVIOR") {
                    if pointer.mapping.destination != .canvas {
                    Picker("Drive", selection: $pointer.mapping.driveMode) {
                        ForEach(SystemPointerDriveMode.allCases) { mode in
                            Text(mode == .whilePinching && pointer.mapping.gestureRules != nil ? "While gesturing" : mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    }
                    if pointer.mapping.gestureRules == nil {
                    Toggle("Pinch controls primary button", isOn: $pointer.mapping.clickWithPinch)
                        .help("Pinch closes the button; release opens it. A quick pinch clicks, while holding the pinch drags.")
                    }
                    valueSlider("Smoothing", value: $pointer.mapping.smoothing, range: 0...0.9, defaultValue: 0.55)
                    valueSlider("Camera width", value: $pointer.mapping.horizontalCoverage, range: 0.2...1, defaultValue: 0.75)
                    valueSlider("Camera height", value: $pointer.mapping.verticalCoverage, range: 0.2...1, defaultValue: 0.75)
                    valueSlider("Pinch", value: $pointer.mapping.pinchThreshold, range: 0.15...0.65, defaultValue: 0.35)
                }

                if pointer.mapping.destination == .canvas {
                section("CUSTOM MAP STACK") {
                    Toggle("Use custom maps", isOn: Binding(
                        get: { pointer.mapping.customGestureMaps != nil },
                        set: { pointer.mapping.customGestureMaps = $0 ? MotionGestureMap.examples : nil }
                    ))
                    .help("Ordered active actions and passive joint controls. Editing disarms motion control.")
                    if let maps = pointer.mapping.customGestureMaps {
                        Text("First matching active rule paints. Passive rules read either hand and can modify that stroke; later parameter rules win.")
                            .font(.caption2).foregroundStyle(.secondary)
                        ForEach(Array(maps.enumerated()), id: \.element.id) { index, rule in
                            MotionGestureMapEditor(map: mapBinding(rule.id),
                                moveUp: { moveMap(index, by: -1) },
                                moveDown: { moveMap(index, by: 1) },
                                remove: { pointer.mapping.customGestureMaps?.removeAll { $0.id == rule.id } },
                                canMoveUp: index > 0, canMoveDown: index < maps.count - 1)
                        }
                        HStack {
                            Button("Add action") {
                                pointer.mapping.customGestureMaps?.append(.action(.right, .pinch, .pen, .draw))
                            }
                            Button("Add parameter") {
                                pointer.mapping.customGestureMaps?.append(.parameter())
                            }
                        }
                        .controlSize(.small)
                    }
                }
                }

                section("GESTURE → ACTION") {
                    if pointer.mapping.destination == .canvas && pointer.mapping.customGestureMaps != nil {
                        Text("Legacy gesture preset is inactive while the custom stack is on.")
                            .font(.caption2).foregroundStyle(.secondary)
                    } else {
                    if let rules = pointer.mapping.gestureRules {
                        ForEach(rules) { rule in
                            Picker(rule.gesture.title, selection: actionBinding(rule.gesture)) {
                                ForEach(MotionAction.choices(for: pointer.mapping.destination ?? .computer)) {
                                    Text($0.title).tag($0)
                                }
                            }
                            if rule.action == .key {
                                Picker("Key", selection: shortcutBinding(rule.gesture)) {
                                    ForEach(MotionShortcut.allCases) { Text($0.title).tag($0) }
                                }
                            }
                        }
                        valueSlider("Hold to engage", value: Binding(
                            get: { pointer.mapping.gestureDwell ?? 0.12 },
                            set: { pointer.mapping.gestureDwell = $0 }
                        ), range: 0.04...0.6, defaultValue: 0.12)
                        .help("Seconds a gesture must remain recognized before firing. Keys and right-click fire once per gesture; draw, erase, drag, and scroll continue while held.")
                    } else {
                        Button("Use gesture rules") { pointer.usePreset(pointer.mapping.destination ?? .computer) }
                    }
                    Button("Reset gesture preset") { pointer.usePreset(pointer.mapping.destination ?? .computer) }
                        .help("Canvas: pinch draws, fist dissolves ink. Computer: pinch clicks/drags, fist right-clicks. Open palm has no action until assigned.")
                    }
                    Text("Escape disarms. Lost tracking releases held actions.")
                        .font(.caption2).foregroundStyle(.secondary)
                }

                section("LIVE") {
                    HStack {
                        liveValue("Pointer", pointer.live.normalizedPoint.map { String(format: "%.3f, %.3f", $0.x, $0.y) } ?? "—")
                        liveValue("Pinch", pointer.live.pinchValue.map { String(format: "%.3f", $0) } ?? "—")
                        liveValue("Pinching", pointer.live.pinching ? "yes" : "no")
                    }
                    Text(pointer.mapping.destination == .canvas
                         ? (pointer.mapping.customGestureMaps == nil
                            ? "Gestures draw into the selected Ink frame, or the first enabled Ink frame. Fist dissolves ink; it does not delete layers."
                            : "The first matching active map paints in the visible Ink frame. Passive maps can control brush parameters without taking over the stroke.")
                         : pointer.mapping.driveMode == .always
                         ? "Always continuously maps the selected landmark to the main display and can override physical mouse movement."
                         : "The physical mouse is left alone until a gesture engages. The selected landmark then positions the pointer; its assigned action controls clicking or other input.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pointer.refreshTrust()
        }
    }

    private func actionBinding(_ gesture: HandGesture) -> Binding<MotionAction> {
        Binding(get: { pointer.mapping.gestureRules?.first { $0.gesture == gesture }?.action ?? .none },
                set: { action in
                    guard let i = pointer.mapping.gestureRules?.firstIndex(where: { $0.gesture == gesture }) else { return }
                    pointer.mapping.gestureRules?[i].action = action
                })
    }

    private func mapBinding(_ id: UUID) -> Binding<MotionGestureMap> {
        Binding(get: {
            pointer.mapping.customGestureMaps?.first(where: { $0.id == id })
                ?? .action(.right, .pinch, .pen, .draw)
        }, set: { value in
            guard let index = pointer.mapping.customGestureMaps?.firstIndex(where: { $0.id == id }) else { return }
            pointer.mapping.customGestureMaps?[index] = value
        })
    }

    private func moveMap(_ index: Int, by offset: Int) {
        guard var maps = pointer.mapping.customGestureMaps,
              maps.indices.contains(index), maps.indices.contains(index + offset) else { return }
        maps.swapAt(index, index + offset)
        pointer.mapping.customGestureMaps = maps
    }

    private func shortcutBinding(_ gesture: HandGesture) -> Binding<MotionShortcut> {
        Binding(get: { pointer.mapping.gestureRules?.first { $0.gesture == gesture }?.shortcut ?? .space },
                set: { shortcut in
                    guard let i = pointer.mapping.gestureRules?.firstIndex(where: { $0.gesture == gesture }) else { return }
                    pointer.mapping.gestureRules?[i].shortcut = shortcut
                })
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.04)))
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 88, alignment: .leading)
                .onTapGesture(count: 2) { value.wrappedValue = defaultValue }
                .help("Double-click to reset")
            Slider(value: value, in: range).controlSize(.small)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .font(.caption2.monospacedDigit()).frame(width: 34, alignment: .trailing)
        }
    }

    private func liveValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.caption.monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MotionGestureMapEditor: View {
    @Binding var map: MotionGestureMap
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void
    let canMoveUp: Bool
    let canMoveDown: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("", isOn: $map.enabled).labelsHidden()
                TextField("Map name", text: $map.name).textFieldStyle(.roundedBorder)
                Button(action: moveUp) { Image(systemName: "arrow.up") }.disabled(!canMoveUp)
                Button(action: moveDown) { Image(systemName: "arrow.down") }.disabled(!canMoveDown)
                Button(role: .destructive, action: remove) { Image(systemName: "trash") }
            }
            .controlSize(.small)
            Picker("Type", selection: $map.kind) {
                ForEach(MotionMapKind.allCases) { Text($0.title).tag($0) }
            }
            Picker(map.kind == .action ? "Painting hand" : "While hand", selection: $map.hand) {
                ForEach(MediaPipeHandSide.allCases) { Text($0.title).tag($0) }
            }
            Picker("Gesture", selection: $map.gesture) {
                ForEach(MotionGestureGate.allCases) { Text($0.title).tag($0) }
            }
            if map.kind == .action {
                HStack {
                    Picker("Tool", selection: $map.mode) {
                        ForEach(MotionPaintMode.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Action", selection: $map.intent) {
                        ForEach(MotionPaintIntent.allCases) { Text($0.title).tag($0) }
                    }
                }
            } else {
                Picker("Measure", selection: $map.metric) {
                    ForEach(MotionJointMetric.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: map.metric) { _, metric in
                    map.inputLow = metric == .angle ? 0 : 0.2
                    map.inputHigh = metric == .angle ? 180 : 1.2
                }
                HStack {
                    featurePicker("Point A", feature: $map.first)
                    if map.metric == .angle { featurePicker("Vertex", feature: $map.vertex) }
                    featurePicker("Point B", feature: $map.last)
                }
                Picker("Controls", selection: $map.target) {
                    ForEach(MotionParameterTarget.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Text("Input").frame(width: 44, alignment: .leading)
                    TextField("Low", value: $map.inputLow, format: .number.precision(.fractionLength(2)))
                    Text("→")
                    TextField("High", value: $map.inputHigh, format: .number.precision(.fractionLength(2)))
                }
                HStack {
                    Text("Output").frame(width: 44, alignment: .leading)
                    TextField("Low", value: $map.outputLow, format: .number.precision(.fractionLength(2)))
                    Text("→")
                    TextField("High", value: $map.outputHigh, format: .number.precision(.fractionLength(2)))
                }
                .help("Values are clamped to the target parameter's range. Reverse the output values to invert control.")
            }
        }
        .font(.caption)
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.055)))
    }

    private func featurePicker(_ title: String, feature: Binding<MediaPipeHandFeature>) -> some View {
        Picker(title, selection: feature) {
            ForEach(MediaPipeHandFeature.allCases) { Text($0.title).tag($0) }
        }
        .labelsHidden()
        .help(title)
    }
}

private struct MediaPipeHomunculusMap: View {
    @Binding var selection: MediaPipeHandFeature

    private static let edges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),
        (0, 5), (5, 6), (6, 7), (7, 8),
        (5, 9), (9, 10), (10, 11), (11, 12),
        (9, 13), (13, 14), (14, 15), (15, 16),
        (13, 17), (0, 17), (17, 18), (18, 19), (19, 20)
    ]
    private static let handPoints: [CGPoint] = [
        CGPoint(x: 0.50, y: 0.90),
        CGPoint(x: 0.38, y: 0.75), CGPoint(x: 0.27, y: 0.66), CGPoint(x: 0.18, y: 0.56), CGPoint(x: 0.08, y: 0.46),
        CGPoint(x: 0.39, y: 0.60), CGPoint(x: 0.35, y: 0.43), CGPoint(x: 0.33, y: 0.27), CGPoint(x: 0.31, y: 0.10),
        CGPoint(x: 0.53, y: 0.56), CGPoint(x: 0.53, y: 0.37), CGPoint(x: 0.53, y: 0.19), CGPoint(x: 0.53, y: 0.03),
        CGPoint(x: 0.66, y: 0.61), CGPoint(x: 0.69, y: 0.43), CGPoint(x: 0.71, y: 0.27), CGPoint(x: 0.72, y: 0.12),
        CGPoint(x: 0.78, y: 0.70), CGPoint(x: 0.84, y: 0.55), CGPoint(x: 0.88, y: 0.42), CGPoint(x: 0.91, y: 0.29)
    ]

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                Canvas { context, _ in
                    drawBody(context: &context, size: size)
                    for side in MediaPipeHandSide.allCases {
                        for edge in Self.edges {
                            var path = Path()
                            path.move(to: point(side: side, index: edge.0, size: size))
                            path.addLine(to: point(side: side, index: edge.1, size: size))
                            context.stroke(path, with: .color(.secondary.opacity(0.48)), lineWidth: 1.4)
                        }
                    }
                }
                ForEach(MediaPipeHandFeature.allCases) { feature in
                    let selected = feature == selection
                    let pinchPoint = feature.landmark == .thumbTip || feature.landmark == .indexTip
                    Button {
                        selection = feature
                    } label: {
                        Circle()
                            .fill(selected ? Color.accentColor : (pinchPoint ? Color.orange.opacity(0.85) : Color.secondary.opacity(0.62)))
                            .overlay(Circle().stroke(Color(nsColor: .windowBackgroundColor), lineWidth: selected ? 2 : 1))
                            .frame(width: selected ? 14 : 10, height: selected ? 14 : 10)
                    }
                    .buttonStyle(.plain)
                    .position(point(side: feature.side, index: feature.landmark.rawValue, size: size))
                    .help(feature.title + (pinchPoint ? " · pinch landmark" : ""))
                    .accessibilityLabel(feature.title)
                }
                Text("LEFT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .position(x: size.width * 0.22, y: 12)
                Text("RIGHT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    .position(x: size.width * 0.78, y: 12)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.22)))
        }
    }

    private func point(side: MediaPipeHandSide, index: Int, size: CGSize) -> CGPoint {
        let source = Self.handPoints[index]
        let localX = side == .left ? 1 - source.x : source.x
        let centerX = side == .left ? size.width * 0.22 : size.width * 0.78
        return CGPoint(
            x: centerX + (localX - 0.5) * size.width * 0.32,
            y: 32 + source.y * size.height * 0.58
        )
    }

    private func drawBody(context: inout GraphicsContext, size: CGSize) {
        let color = Color.secondary.opacity(0.23)
        let center = size.width * 0.5
        let top = size.height * 0.62
        context.stroke(Path(ellipseIn: CGRect(x: center - 13, y: top, width: 26, height: 30)), with: .color(color), lineWidth: 2)
        var body = Path()
        body.move(to: CGPoint(x: center, y: top + 30))
        body.addLine(to: CGPoint(x: center, y: size.height * 0.84))
        body.move(to: CGPoint(x: center, y: top + 48))
        body.addLine(to: CGPoint(x: center - 38, y: size.height * 0.76))
        body.move(to: CGPoint(x: center, y: top + 48))
        body.addLine(to: CGPoint(x: center + 38, y: size.height * 0.76))
        body.move(to: CGPoint(x: center, y: size.height * 0.84))
        body.addLine(to: CGPoint(x: center - 26, y: size.height - 10))
        body.move(to: CGPoint(x: center, y: size.height * 0.84))
        body.addLine(to: CGPoint(x: center + 26, y: size.height - 10))
        context.stroke(body, with: .color(color), style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
    }
}
