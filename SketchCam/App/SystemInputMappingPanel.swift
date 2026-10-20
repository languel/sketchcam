import AppKit
import Foundation
import SwiftUI

struct SystemInputMappingPanel: View {
    @ObservedObject private var pointer: SystemPointerController
    private let toggleArm: () -> Void

    init(model: SketchCamViewModel) {
        _pointer = ObservedObject(wrappedValue: model.systemPointer)
        toggleArm = { model.toggleMotionControl() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MotionArmControls(pointer: pointer, toggleArm: toggleArm)

                Picker("Destination", selection: Binding(
                    get: { pointer.mapping.destination ?? .computer },
                    set: { pointer.usePreset($0) }
                )) {
                    ForEach(MotionControlDestination.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Canvas paints into the active Ink frame without Accessibility access. Computer sends system mouse and keyboard events. Switching destination disarms control; editing rules keeps it armed.")

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
                    .help("Ordered active actions and passive joint controls. Editing finishes the current stroke and keeps motion control armed.")
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
                            Button("Add tool sequence") {
                                pointer.mapping.customGestureMaps?.append(.tool())
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
            if map.kind != .tool {
                Picker(map.kind == .action ? "Painting hand" : "While hand", selection: $map.hand) {
                    ForEach(MediaPipeHandSide.allCases) { Text($0.title).tag($0) }
                }
                Picker("Gesture", selection: $map.gesture) {
                    ForEach(MotionGestureGate.allCases) { Text($0.title).tag($0) }
                }
                Picker("Finger count", selection: $map.fingerCount) {
                    Text("Any").tag(Optional<Int>.none)
                    ForEach(0...5, id: \.self) { count in
                        Text("\(count)").tag(Optional(count))
                    }
                }
                Picker("Other hand count", selection: $map.otherFingerCount) {
                    Text("Any").tag(Optional<Int>.none)
                    ForEach(0...5, id: \.self) { count in
                        Text("\(count)").tag(Optional(count))
                    }
                }
                HStack(spacing: 3) {
                    digitPicker("Thumb", state: $map.thumbState)
                    digitPicker("Index", state: $map.indexState)
                    digitPicker("Middle", state: $map.middleState)
                    digitPicker("Ring", state: $map.ringState)
                    digitPicker("Little", state: $map.littleState)
                }
                .help("Choose Any gesture for a sign. Finger count and each digit can be required on either hand.")
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
            } else if map.kind == .parameter {
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
            } else {
                Picker("App tool", selection: $map.toolID) {
                    Text("Choose a tool").tag("")
                    ForEach(ShortcutRegistry.shared.toolCatalog, id: \.id) { tool in
                        Text("\(tool.category) · \(tool.title)").tag(tool.id)
                    }
                }
                ForEach($map.sequence) { $step in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Picker("When", selection: $step.kind) {
                                ForEach(MotionSequenceStep.Kind.allCases) { Text($0.title).tag($0) }
                            }
                            Button(role: .destructive) {
                                map.sequence.removeAll { $0.id == step.id }
                            } label: { Image(systemName: "minus.circle") }
                        }
                        if step.kind == .gesture {
                            Picker("Hand", selection: $step.hand) {
                                ForEach(MediaPipeHandSide.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("Pose", selection: $step.gesture) {
                                ForEach(MotionGestureGate.allCases.filter { $0 != .any }) { Text($0.title).tag($0) }
                            }
                        } else if step.kind == .handPose {
                            Picker("Hand", selection: $step.hand) {
                                ForEach(MediaPipeHandSide.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("Extended fingers", selection: $step.fingerCount) {
                                Text("Any sign").tag(Optional<Int>.none)
                                ForEach(0...5, id: \.self) { count in
                                    Text("\(count)").tag(Optional(count))
                                }
                            }
                            Picker("Other hand", selection: $step.otherFingerCount) {
                                Text("Any").tag(Optional<Int>.none)
                                ForEach(0...5, id: \.self) { count in
                                    Text("\(count)").tag(Optional(count))
                                }
                            }
                            HStack(spacing: 3) {
                                digitPicker("Thumb", state: $step.thumbState)
                                digitPicker("Index", state: $step.indexState)
                                digitPicker("Middle", state: $step.middleState)
                                digitPicker("Ring", state: $step.ringState)
                                digitPicker("Little", state: $step.littleState)
                            }
                        } else if step.kind == .fistSqueeze {
                            Picker("Hand", selection: $step.hand) {
                                ForEach(MediaPipeHandSide.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("Squeezes", selection: Binding(
                                get: { step.squeezeCount ?? 2 },
                                set: { step.squeezeCount = $0 })) {
                                    ForEach(1...5, id: \.self) { count in Text("\(count)").tag(count) }
                                }
                            valueSlider("Within", value: Binding(
                                get: { step.squeezeWindow ?? 0.8 },
                                set: { step.squeezeWindow = $0 }), range: 0.2...2, defaultValue: 0.8)
                            Text("Each squeeze is a fist close after the hand opens again.")
                                .font(.caption2).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                trackedPointPicker("Point A", selection: $step.pointA)
                                if step.kind == .angle {
                                    trackedPointPicker("Vertex", selection: $step.pointVertex)
                                }
                                trackedPointPicker("Point B", selection: $step.pointB)
                            }
                            if step.kind == .angle {
                                valueSlider("Angle min", value: $step.minimumAngle, range: 0...180, defaultValue: 0)
                                valueSlider("Angle max", value: $step.maximumAngle, range: 0...180, defaultValue: 45)
                            } else {
                                valueSlider("Near", value: $step.maximumDistance, range: 0.01...0.25, defaultValue: 0.045)
                            }
                        }
                        if step.kind != .fistSqueeze {
                            valueSlider("Hold", value: $step.dwell, range: 0.04...1, defaultValue: 0.18)
                        }
                        valueSlider("Next within", value: $step.maximumGap, range: 0.2...3, defaultValue: 1.2)
                    }
                    .padding(5)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.04)))
                }
                Button("Add step") { map.sequence.append(MotionSequenceStep()) }
                    .controlSize(.small)
                Text("Steps run in order; the last condition must release before the sequence can fire again.")
                    .font(.caption2).foregroundStyle(.secondary)
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

    private func trackedPointPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(MotionSequenceStep.pointChoices, id: \.label) { point in
                Text(point.title).tag(point.label)
            }
        }
    }

    private func digitPicker(_ title: String, state: Binding<MotionDigitState?>) -> some View {
        Picker(title, selection: state) {
            Text("Any").tag(Optional<MotionDigitState>.none)
            ForEach(MotionDigitState.allCases) { Text($0.title).tag(Optional($0)) }
        }
        .labelsHidden()
        .controlSize(.small)
        .help("\(title): Any, Extended, or Folded")
    }

    private func valueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, defaultValue: Double) -> some View {
        HStack {
            Text(title).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range)
            Text(value.wrappedValue.formatted(.number.precision(.fractionLength(2))))
                .monospacedDigit().frame(width: 38)
        }
    }
}

struct MotionArmControls: View {
    @ObservedObject var pointer: SystemPointerController
    let toggleArm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MOTION CONTROL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(pointer.live.status).font(.caption2)
                        .foregroundStyle(pointer.isArmed ? Color.accentColor : Color.secondary)
                }
                Spacer()
                Button(pointer.isArmed ? "Disarm" : "Arm", action: toggleArm)
                    .buttonStyle(.borderedProminent)
                    .tint(pointer.isArmed ? .red : .accentColor)
                    .help("Arm / Disarm Motion Control. Default shortcut: Control–Option–A (customize in Keys). Escape disarms.")
            }
            Toggle("Two palms to arm / disarm", isOn: $pointer.palmArmGestureEnabled)
                .font(.caption)
                .help("Hold both open palms for 0.9 seconds. Close either hand with both hands visible before repeating. Reserves this pose while enabled, and listens while disarmed. Requires a live camera feed.")
        }
    }
}

struct GesturePresentationPanel: View {
    @ObservedObject private var pointer: SystemPointerController
    private let toggleArm: () -> Void

    init(model: SketchCamViewModel) {
        _pointer = ObservedObject(wrappedValue: model.systemPointer)
        toggleArm = { model.toggleMotionControl() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                MotionArmControls(pointer: pointer, toggleArm: toggleArm)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Show gesture cues on canvas", isOn: $pointer.cueSettings.enabled)
                    Toggle("Show text labels", isOn: $pointer.cueSettings.showsLabels)
                        .disabled(!pointer.cueSettings.enabled)
                    Picker("Effect", selection: $pointer.cueSettings.effect) {
                        ForEach(GestureCueEffect.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Color", selection: $pointer.cueSettings.color) {
                        ForEach(GestureCueColor.allCases) { Text($0.title).tag($0) }
                    }
                    cueSlider("Size", value: $pointer.cueSettings.size, range: 12...80, suffix: "pt")
                    cueSlider("Lifetime", value: $pointer.cueSettings.duration, range: 0.25...2.5, suffix: "s")
                    Button("Preview cue") { pointer.previewGestureCue() }
                        .controlSize(.small)
                        .disabled(!pointer.cueSettings.enabled)
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))

                VStack(alignment: .leading, spacing: 7) {
                    Text("RECOGNIZED MAPS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text("Cues appear when an action map engages or a gesture sequence completes. Passive parameter maps are listed for reference but do not fire a cue.")
                        .font(.caption2).foregroundStyle(.secondary)
                    if displayMaps.isEmpty {
                        Text("No active gesture maps yet. Define maps in Input Map.")
                            .font(.caption).foregroundStyle(.secondary).padding(.vertical, 4)
                    } else {
                        ForEach(displayMaps, id: \.id) { item in
                            HStack(spacing: 7) {
                                Toggle("", isOn: cueBinding(item.id))
                                    .labelsHidden()
                                    .disabled(!item.canFire)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.caption)
                                    Text(item.detail).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                if !item.canFire { Text("Passive").font(.caption2).foregroundStyle(.tertiary) }
                            }
                        }
                    }
                }
                .padding(9)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private struct DisplayMap: Identifiable {
        var id: String
        var name: String
        var detail: String
        var canFire: Bool
    }

    private var displayMaps: [DisplayMap] {
        let sessionMaps = pointer.palmArmGestureEnabled
            ? [DisplayMap(id: "motion.arm.toggle", name: "Arm / Disarm",
                          detail: "Both open palms · hold 0.9 s", canFire: true)] : []
        if let maps = pointer.mapping.customGestureMaps {
            return sessionMaps + maps.map { map in
                let detail: String
                switch map.kind {
                case .action: detail = "\(map.hand.title) · \(map.gesture.title) · \(map.mode.title) \(map.intent.title)"
                case .parameter: detail = "\(map.hand.title) · \(map.gesture.title) · \(map.target.title)"
                case .tool: detail = "Sequence · \(map.toolID.isEmpty ? "No tool selected" : map.toolID)"
                }
                return DisplayMap(id: map.id.uuidString, name: map.name, detail: detail,
                                  canFire: map.enabled && map.kind != .parameter)
            }
        }
        return sessionMaps + (pointer.mapping.gestureRules ?? []).compactMap { rule in
            guard rule.action != .none else { return nil }
            return DisplayMap(id: "legacy.\(rule.gesture.rawValue)", name: rule.gesture.title,
                              detail: rule.action.title, canFire: true)
        }
    }

    private func cueBinding(_ id: String) -> Binding<Bool> {
        Binding(get: { !pointer.cueSettings.hiddenMapIDs.contains(id) }, set: { show in
            if show { pointer.cueSettings.hiddenMapIDs.remove(id) }
            else { pointer.cueSettings.hiddenMapIDs.insert(id) }
        })
    }

    private func cueSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, suffix: String) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 58, alignment: .leading)
            Slider(value: value, in: range).controlSize(.small)
            Text("\(value.wrappedValue.formatted(.number.precision(.fractionLength(1)))) \(suffix)")
                .font(.caption2.monospacedDigit()).frame(width: 48, alignment: .trailing)
        }
    }
}

struct GestureCueOverlay: View {
    @ObservedObject var pointer: SystemPointerController
    let outputRect: CGRect
    let mirrored: Bool

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if pointer.cueSettings.enabled {
                    ForEach(pointer.gestureCues.filter { !pointer.cueSettings.hiddenMapIDs.contains($0.mapID) }) { cue in
                        GestureCueMark(cue: cue, settings: pointer.cueSettings)
                            .position(x: outputRect.minX + (mirrored ? 1 - cue.point.x : cue.point.x) * outputRect.width,
                                      y: outputRect.maxY - cue.point.y * outputRect.height)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .allowsHitTesting(false)
    }
}

private struct GestureCueMark: View {
    let cue: GestureCue
    let settings: GestureCueSettings

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: false)) { _ in
            let age = max(0, ProcessInfo.processInfo.systemUptime - cue.bornAt)
            let progress = min(1, age / max(0.2, settings.duration))
            let color = cueColor(settings.color)
            ZStack {
                effect(color: color, progress: progress)
                Circle().fill(color).frame(width: 6, height: 6)
                    .overlay(Circle().stroke(.white.opacity(0.9), lineWidth: 1))
            }
            .frame(width: settings.size * 1.8, height: settings.size * 1.8)
            .overlay(alignment: .top) {
                if settings.showsLabels {
                    Text(cue.label)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(color.opacity(0.92)))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        .opacity(1 - progress * 0.35)
                        .fixedSize()
                        .offset(y: -16)
                }
            }
            .opacity(1 - progress)
        }
        .fixedSize()
    }

    @ViewBuilder private func effect(color: Color, progress: Double) -> some View {
        switch settings.effect {
        case .click:
            Circle().stroke(color, lineWidth: 2.5)
                .frame(width: settings.size * (0.3 + progress * 0.8), height: settings.size * (0.3 + progress * 0.8))
        case .ripple:
            ZStack {
                Circle().stroke(color, lineWidth: 2.2)
                    .frame(width: settings.size * (0.2 + progress * 1.35), height: settings.size * (0.2 + progress * 1.35))
                if progress > 0.25 {
                    Circle().stroke(color.opacity(0.7), lineWidth: 1.5)
                        .frame(width: settings.size * (0.2 + (progress - 0.25) * 1.65), height: settings.size * (0.2 + (progress - 0.25) * 1.65))
                }
            }
        case .burst:
            ZStack {
                ForEach(0..<8, id: \.self) { index in
                    Capsule().fill(color)
                        .frame(width: 2, height: settings.size * (0.15 + progress * 0.35))
                        .offset(y: settings.size * (0.18 + progress * 0.5))
                        .rotationEffect(.degrees(Double(index) * 45))
                }
            }
        }
    }

    private func cueColor(_ choice: GestureCueColor) -> Color {
        switch choice {
        case .cyan: .cyan
        case .amber: .orange
        case .magenta: .pink
        case .green: .green
        case .white: .white
        }
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
