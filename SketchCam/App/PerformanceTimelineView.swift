import Combine
import SketchCamCore
import SwiftUI

/// Compact, always-document-backed performance timeline. Raster ink is never
/// touched here: transport previews vectors, camera and automation only.
struct PerformanceTimelineView: View {
    @Binding var project: SketchProjectManifest
    @Binding var selectedGestureIDs: Set<UUID>
    let onChanged: () -> Void
    let onPreview: (TimeInterval) -> Void

    @State private var expanded = true
    @State private var playing = false
    @State private var looping = false
    @State private var lastTick = Date()
    private let clock = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { expanded.toggle() } label: { Image(systemName: expanded ? "chevron.down" : "chevron.up") }
                Button { project.timeline.playhead = 0; preview(); onChanged() } label: { Image(systemName: "backward.end.fill") }
                Button { playing.toggle(); lastTick = Date() } label: { Image(systemName: playing ? "pause.fill" : "play.fill") }
                Toggle(isOn: $project.timeline.masterRecordEnabled) { Image(systemName: "record.circle") }
                    .toggleStyle(.button).tint(.red).help("Master Record. Off paints only into the persistent raster artifact.")
                Toggle(isOn: $looping) { Image(systemName: "repeat") }.toggleStyle(.button)
                Text(time(project.timeline.playhead)).monospacedDigit().frame(width: 62, alignment: .leading)
                Slider(value: playhead, in: 0...duration)
                Text(time(duration)).foregroundStyle(.secondary).monospacedDigit()
                Button("Camera key") { addCameraKeyframe() }
                    .disabled(project.cameraTracks.first?.armed != true)
                Button { project.cameraTracks[0].armed.toggle(); onChanged() } label: {
                    Image(systemName: project.cameraTracks.first?.armed == true ? "record.circle.fill" : "record.circle")
                }.help("Arm the camera track")
                Menu("Track") {
                    ForEach(SketchParameterRegistry.descriptors) { descriptor in
                        Button(descriptor.name) { addAutomationTrack(descriptor) }
                    }
                }
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 9).frame(height: 34)

            if expanded {
                ScrollView([.vertical, .horizontal]) {
                    VStack(spacing: 2) {
                        trackRow(title: "Camera", armed: project.cameraTracks.first?.armed == true) {
                            ForEach(project.cameraTracks.first?.keyframes ?? []) { key in
                                diamond(at: key.time).onTapGesture { project.timeline.playhead = key.time; preview() }
                            }
                        }
                        trackRow(title: "Gestures", armed: project.timeline.masterRecordEnabled) {
                            ForEach($project.gestures) { $gesture in
                                clip(gesture: $gesture)
                            }
                        }
                        trackRow(title: "Material", armed: project.timeline.masterRecordEnabled) {
                            ForEach(project.materialEvents) { event in diamond(at: event.time).help(event.command.rawValue.capitalized) }
                        }
                        ForEach(project.automationTracks) { track in
                            trackRow(title: track.name, armed: track.armed) {
                                ForEach(track.keyframes) { key in diamond(at: key.time) }
                            }
                            .contextMenu {
                                Button("Add keyframe here") { addAutomationKeyframe(track.id) }
                                Button("Arm") { updateTrack(track.id) { $0.armed.toggle() } }
                                Button("Mute") { updateTrack(track.id) { $0.muted.toggle() } }
                                Button("Solo") { updateTrack(track.id) { $0.solo.toggle() } }
                                Button("Delete", role: .destructive) { project.automationTracks.removeAll { $0.id == track.id }; onChanged() }
                            }
                        }
                    }
                    .frame(width: max(700, CGFloat(duration) * 100 + 130), alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        Rectangle().fill(Color.accentColor).frame(width: 1)
                            .offset(x: 125 + x(project.timeline.playhead)).allowsHitTesting(false)
                    }
                }
                .frame(height: 112)
            }
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) { Divider() }
        .onReceive(clock) { now in tick(now) }
    }

    private var duration: Double { max(0.1, project.timeline.duration) }
    private var playhead: Binding<Double> { Binding(get: { project.timeline.playhead }, set: { project.timeline.playhead = $0; preview(); onChanged() }) }
    private func x(_ time: Double) -> CGFloat { CGFloat(time / duration) * max(570, CGFloat(duration) * 100) }

    private func trackRow<Content: View>(title: String, armed: Bool, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 0) {
            HStack { Circle().fill(armed ? .red : .secondary).frame(width: 6); Text(title).lineLimit(1); Spacer() }
                .padding(.horizontal, 7).frame(width: 125, height: 30).background(Color.primary.opacity(0.035))
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.025))
                ForEach(0...Int(ceil(duration)), id: \.self) { second in
                    Rectangle().fill(Color.primary.opacity(second % 5 == 0 ? 0.16 : 0.07)).frame(width: 1).offset(x: x(Double(second)))
                }
                content()
            }.frame(width: max(570, CGFloat(duration) * 100), height: 30)
        }
    }

    private func clip(gesture: Binding<GestureClip>) -> some View {
        let value = gesture.wrappedValue
        return RoundedRectangle(cornerRadius: 4)
            .fill(selectedGestureIDs.contains(value.id) ? Color.accentColor : color(value.kind))
            .overlay(alignment: .leading) { Text(value.name).font(.caption2).lineLimit(1).padding(.horizontal, 4) }
            .frame(width: max(8, x(value.startTime + value.duration) - x(value.startTime)), height: 22)
            .offset(x: x(value.startTime))
            .gesture(DragGesture().onChanged { drag in
                let seconds = Double(drag.translation.width / max(570, CGFloat(duration) * 100)) * duration
                gesture.wrappedValue.startTime = max(0, value.startTime + seconds)
            }.onEnded { _ in onChanged() })
            .onTapGesture { selectedGestureIDs = [value.id]; project.timeline.playhead = value.startTime }
            .contextMenu {
                Button(value.muted ? "Unmute" : "Mute") { gesture.wrappedValue.muted.toggle(); onChanged() }
                Button("Duplicate") { duplicate(value) }
                Button("Preserve speed after scale") { preserveSpeed(value.id) }
                Button("Delete", role: .destructive) { project.gestures.removeAll { $0.id == value.id }; onChanged() }
            }
    }

    private func diamond(at time: Double) -> some View {
        Rectangle().fill(Color.orange).frame(width: 8, height: 8).rotationEffect(.degrees(45)).offset(x: x(time) - 4)
    }

    private func tick(_ now: Date) {
        defer { lastTick = now }
        guard playing else { return }
        var next = project.timeline.playhead + min(0.1, now.timeIntervalSince(lastTick))
        if looping, next >= project.timeline.loopEnd { next = project.timeline.loopStart }
        if next >= duration { next = duration; playing = false }
        project.timeline.playhead = next
        preview()
    }

    private func preview() {
        if let track = project.cameraTracks.first, !track.muted,
           let camera = TimelineEvaluator.camera(on: track, at: project.timeline.playhead) { project.camera = camera }
        onPreview(project.timeline.playhead)
    }

    private func addCameraKeyframe() {
        if project.cameraTracks.isEmpty { project.cameraTracks = [CameraTrack()] }
        project.cameraTracks[0].keyframes.removeAll { abs($0.time - project.timeline.playhead) < 1.0 / 120.0 }
        project.cameraTracks[0].keyframes.append(CameraKeyframe(time: project.timeline.playhead, camera: project.camera))
        project.cameraTracks[0].keyframes.sort { $0.time < $1.time }; onChanged()
    }

    private func addAutomationTrack(_ descriptor: ParameterDescriptor) {
        let address = ParameterAddress(ownerID: project.id, component: descriptor.component, parameter: descriptor.parameter)
        guard !project.automationTracks.contains(where: { $0.address == address }) else { return }
        project.automationTracks.append(AutomationTrack(name: descriptor.name, address: address,
            keyframes: [AutomationKeyframe(time: project.timeline.playhead, value: descriptor.defaultValue)]))
        onChanged()
    }

    private func addAutomationKeyframe(_ id: UUID) {
        guard let index = project.automationTracks.firstIndex(where: { $0.id == id }) else { return }
        let value = TimelineEvaluator.value(on: project.automationTracks[index], at: project.timeline.playhead)
            ?? SketchParameterRegistry.descriptor(component: project.automationTracks[index].address.component,
                                                  parameter: project.automationTracks[index].address.parameter)?.defaultValue
            ?? .scalar(0)
        project.automationTracks[index].keyframes.append(AutomationKeyframe(time: project.timeline.playhead, value: value))
        project.automationTracks[index].keyframes.sort { $0.time < $1.time }; onChanged()
    }

    private func updateTrack(_ id: UUID, _ body: (inout AutomationTrack) -> Void) {
        guard let index = project.automationTracks.firstIndex(where: { $0.id == id }) else { return }
        body(&project.automationTracks[index]); onChanged()
    }

    private func duplicate(_ source: GestureClip) {
        var copy = source; copy.id = UUID(); copy.name += " copy"; copy.startTime += max(0.1, copy.duration)
        project.gestures.append(copy); selectedGestureIDs = [copy.id]
        project.timeline.duration = max(project.timeline.duration, copy.startTime + copy.duration); onChanged()
    }

    private func preserveSpeed(_ id: UUID) {
        guard let index = project.gestures.firstIndex(where: { $0.id == id }) else { return }
        let points = project.gestures[index].curve.sampled()
        let length = zip(points, points.dropFirst()).reduce(CGFloat.zero) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        let oldPoints = project.gestures[index].samples.map(\.position)
        let oldLength = zip(oldPoints, oldPoints.dropFirst()).reduce(CGFloat.zero) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
        if oldLength > 0 { project.gestures[index].duration *= Double(length / oldLength) }
        onChanged()
    }

    private func time(_ value: Double) -> String { String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60) }
    private func color(_ kind: MaterialGestureKind) -> Color {
        switch kind { case .pen: return .blue; case .wash: return .cyan; case .rewet: return .mint; case .fix: return .orange }
    }
}
