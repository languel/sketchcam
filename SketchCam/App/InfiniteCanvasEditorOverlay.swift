import AppKit
import SketchCamCore
import SwiftUI

private struct CanvasPointerEvent {
    enum Phase { case began, changed, ended }
    var phase: Phase
    var location: CGPoint
    var startLocation: CGPoint
    var timestamp: TimeInterval
    var modifiers: NSEvent.ModifierFlags
    var secondary: Bool
    var clickCount: Int
}

private struct InfiniteCanvasEventSurface: NSViewRepresentable {
    var onPointer: (CanvasPointerEvent) -> Void
    var onPan: (CGSize) -> Void
    var onZoom: (CGFloat, CGPoint) -> Void
    var onRotate: (CGFloat) -> Void
    var onDelete: () -> Void
    var onEscape: () -> Void
    var onEnter: () -> Void

    func makeNSView(context: Context) -> EventView {
        NSEvent.isMouseCoalescingEnabled = false
        let view = EventView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: EventView, context: Context) { update(nsView) }

    private func update(_ view: EventView) {
        view.onPointer = onPointer
        view.onPan = onPan
        view.onZoom = onZoom
        view.onRotate = onRotate
        view.onDelete = onDelete
        view.onEscape = onEscape
        view.onEnter = onEnter
    }

    final class EventView: NSView {
        var onPointer: ((CanvasPointerEvent) -> Void)?
        var onPan: ((CGSize) -> Void)?
        var onZoom: ((CGFloat, CGPoint) -> Void)?
        var onRotate: ((CGFloat) -> Void)?
        var onDelete: (() -> Void)?
        var onEscape: (() -> Void)?
        var onEnter: (() -> Void)?
        private var start: CGPoint?
        private var previous: CGPoint?
        private var secondary = false
        private var spaceHeld = false
        private var panning = false

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) { begin(event, secondary: event.modifierFlags.contains(.control)) }
        override func rightMouseDown(with event: NSEvent) { begin(event, secondary: true) }
        override func otherMouseDown(with event: NSEvent) { begin(event, secondary: false, forcePan: true) }
        override func mouseDragged(with event: NSEvent) { update(event) }
        override func rightMouseDragged(with event: NSEvent) { update(event) }
        override func otherMouseDragged(with event: NSEvent) { update(event) }
        override func mouseUp(with event: NSEvent) { finish(event) }
        override func rightMouseUp(with event: NSEvent) { finish(event) }
        override func otherMouseUp(with event: NSEvent) { finish(event) }

        override func keyDown(with event: NSEvent) {
            if event.keyCode == 49 { spaceHeld = true; return }
            if event.keyCode == 51 || event.keyCode == 117 { onDelete?(); return }
            if event.keyCode == 53 { onEscape?(); return }
            if event.keyCode == 36 || event.keyCode == 76 { onEnter?(); return }
            super.keyDown(with: event)
        }

        override func keyUp(with event: NSEvent) {
            if event.keyCode == 49 { spaceHeld = false; return }
            super.keyUp(with: event)
        }

        override func flagsChanged(with event: NSEvent) {
            if event.keyCode == 49 { spaceHeld = event.modifierFlags.contains(.function) }
            super.flagsChanged(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            window?.makeFirstResponder(self)
            let point = convert(event.locationInWindow, from: nil)
            if event.modifierFlags.contains(.command) {
                onZoom?(exp(-event.scrollingDeltaY * 0.012), point)
            } else {
                onPan?(CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
            }
        }

        override func magnify(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onZoom?(max(0.05, 1 + event.magnification), convert(event.locationInWindow, from: nil))
        }

        override func rotate(with event: NSEvent) {
            window?.makeFirstResponder(self)
            onRotate?(-CGFloat(event.rotation) * .pi / 180)
        }

        private func begin(_ event: NSEvent, secondary: Bool, forcePan: Bool = false) {
            window?.makeFirstResponder(self)
            let point = convert(event.locationInWindow, from: nil)
            start = point
            previous = point
            self.secondary = secondary
            panning = forcePan || spaceHeld
            guard !panning else { return }
            onPointer?(value(event, phase: .began, location: point))
        }

        private func update(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if panning || spaceHeld {
                let old = previous ?? point
                onPan?(CGSize(width: point.x - old.x, height: point.y - old.y))
                previous = point
                panning = true
            } else {
                onPointer?(value(event, phase: .changed, location: point))
            }
        }

        private func finish(_ event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            if !panning { onPointer?(value(event, phase: .ended, location: point)) }
            start = nil
            previous = nil
            panning = false
            secondary = false
        }

        private func value(_ event: NSEvent, phase: CanvasPointerEvent.Phase, location: CGPoint) -> CanvasPointerEvent {
            CanvasPointerEvent(phase: phase, location: location, startLocation: start ?? location,
                               timestamp: event.timestamp, modifiers: event.modifierFlags,
                               secondary: secondary, clickCount: event.clickCount)
        }
    }
}

/// Direct-manipulation world-space editor layered over the live preview. The
/// simulation remains an artifact; recorded gestures are the editable
/// performance representation.
struct InfiniteCanvasEditorOverlay: View {
    @Binding var project: SketchProjectManifest
    @Binding var legacyPaths: [InkEditorPath]
    @Binding var tool: InkTool
    @Binding var selectedGestureIDs: Set<UUID>
    @Binding var selectedAnchorID: UUID?
    let outputSize: CGSize
    let brushMode: InkBrushMode
    let inkKind: InkKind
    let inkColor: RGBAColor
    let width: Float
    let washWidth: Float
    let flow: Float
    let bleed: Float
    let dry: Float
    let brushInk: Float
    let fitRecipe: CurveFitRecipe
    let onLive: (InkLiveStrokeSample) -> Void
    let onLiveEnd: () -> Void
    let onProjectChanged: () -> Void

    @State private var activeID: UUID?
    @State private var activeSamples: [GestureSample] = []
    @State private var downTimestamp: TimeInterval = 0
    @State private var editingPoints = false
    @State private var originalGestures: [GestureClip] = []
    @State private var dragWorldStart: CGPoint?
    @State private var marqueeStart: CGPoint?
    @State private var marqueeEnd: CGPoint?
    @State private var selectedTangent: (anchorID: UUID, outgoing: Bool)?

    var body: some View {
        GeometryReader { geometry in
            let rect = fittedRect(container: geometry.size, content: outputSize)
            ZStack {
                Canvas { context, _ in
                    drawScene(context: &context, rect: rect)
                }
                InfiniteCanvasEventSurface(
                    onPointer: { handle($0, rect: rect) },
                    onPan: { pan($0, rect: rect) },
                    onZoom: { zoom($0, anchor: $1, rect: rect) },
                    onRotate: { project.camera.rotation += $0; onProjectChanged() },
                    onDelete: deleteSelection,
                    onEscape: { editingPoints = false; selectedAnchorID = nil },
                    onEnter: { if !selectedGestureIDs.isEmpty { editingPoints = true } }
                )
            }
            .contentShape(Rectangle())
        }
    }

    private func drawScene(context: inout GraphicsContext, rect: CGRect) {
        for gesture in project.gestures where !gesture.muted {
            let selected = selectedGestureIDs.contains(gesture.id)
            let outline = ExpressiveStrokeBuilder.outline(samples: gesture.samples, curve: gesture.curve, profile: gesture.strokeProfile)
            if outline.count > 2 {
                var shape = Path()
                shape.move(to: viewPoint(outline[0], rect: rect))
                for point in outline.dropFirst() { shape.addLine(to: viewPoint(point, rect: rect)) }
                shape.closeSubpath()
                context.fill(shape, with: .color(color(gesture.color).opacity(selected ? 0.38 : 0.18)))
            }
            if selected {
                var center = Path()
                let sampled = gesture.curve.sampled()
                if let first = sampled.first {
                    center.move(to: viewPoint(first, rect: rect))
                    for point in sampled.dropFirst() { center.addLine(to: viewPoint(point, rect: rect)) }
                    context.stroke(center, with: .color(.accentColor), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }
                let bounds = gesture.curve.bounds
                if !bounds.isNull {
                    let a = viewPoint(bounds.origin, rect: rect)
                    let b = viewPoint(CGPoint(x: bounds.maxX, y: bounds.maxY), rect: rect)
                    context.stroke(Path(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))),
                                   with: .color(.accentColor.opacity(0.7)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                if editingPoints {
                    drawAnchors(gesture.curve, context: &context, rect: rect)
                }
            }
        }
        if let marqueeStart, let marqueeEnd {
            let a = viewPoint(marqueeStart, rect: rect), b = viewPoint(marqueeEnd, rect: rect)
            let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            context.fill(Path(box), with: .color(.accentColor.opacity(0.08)))
            context.stroke(Path(box), with: .color(.accentColor.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    private func drawAnchors(_ curve: EditableCurve, context: inout GraphicsContext, rect: CGRect) {
        for anchor in curve.anchors {
            let p = viewPoint(anchor.position, rect: rect)
            for tangent in [anchor.tangentIn, anchor.tangentOut] where tangent != .zero {
                let q = viewPoint(CGPoint(x: anchor.position.x + tangent.x, y: anchor.position.y + tangent.y), rect: rect)
                var line = Path(); line.move(to: p); line.addLine(to: q)
                context.stroke(line, with: .color(.accentColor.opacity(0.6)), lineWidth: 1)
                context.fill(Path(ellipseIn: CGRect(x: q.x - 3, y: q.y - 3, width: 6, height: 6)), with: .color(.accentColor))
            }
            let radius: CGFloat = anchor.id == selectedAnchorID ? 5 : 4
            context.fill(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)),
                         with: .color(anchor.id == selectedAnchorID ? .accentColor : .white))
            context.stroke(Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2)), with: .color(.accentColor), lineWidth: 1)
        }
    }

    private func handle(_ event: CanvasPointerEvent, rect: CGRect) {
        guard rect.contains(event.location) else {
            if event.phase == .ended { finishDrawing(event) }
            return
        }
        let world = worldPoint(event.location, rect: rect)
        switch tool {
        case .draw: handleDrawing(event, world: world, rect: rect)
        case .select: handleSelection(event, world: world, rect: rect)
        case .points: handleSelection(event, world: world, rect: rect)
        }
    }

    private func handleDrawing(_ event: CanvasPointerEvent, world: CGPoint, rect: CGRect) {
        switch event.phase {
        case .began:
            activeID = UUID(); activeSamples = []; downTimestamp = event.timestamp
            appendDrawingSample(event, world: world, rect: rect)
        case .changed: appendDrawingSample(event, world: world, rect: rect)
        case .ended:
            appendDrawingSample(event, world: world, rect: rect)
            finishDrawing(event)
        }
    }

    private func appendDrawingSample(_ event: CanvasPointerEvent, world: CGPoint, rect: CGRect) {
        guard let id = activeID else { return }
        if activeSamples.last.map({ hypot($0.position.x - world.x, $0.position.y - world.y) < project.camera.viewHeight * 0.001 }) == true { return }
        let pressure = Float(max(0.05, min(1, 1 - CGFloat(activeSamples.count) * 0.0002)))
        activeSamples.append(GestureSample(position: world, time: max(0, event.timestamp - downTimestamp), pressure: pressure,
                                           modifiers: UInt32(event.modifiers.rawValue)))
        let uv = project.camera.viewportUV(fromWorldPoint: world, aspect: aspect)
        let option = event.modifiers.contains(.option)
        let fix = option && event.modifiers.contains(.shift)
        let rewet = option && !fix
        let wash = event.secondary || event.modifiers.contains(.control) || rewet || fix || event.modifiers.contains(.command)
        onLive(InkLiveStrokeSample(
            id: id,
            point: uv,
            brushMode: wash ? .brush : brushMode,
            inkKind: event.modifiers.contains(.command) ? .white : inkKind,
            width: wash ? washWidth : width,
            flow: flow,
            brushInk: (rewet || fix) ? 0 : brushInk,
            color: inkColor,
            smoothBoost: event.modifiers.contains(.shift) && !fix,
            destructive: wash && !rewet && !fix,
            wetOnly: rewet,
            fixOnly: fix,
            charge: 0
        ))
    }

    private func finishDrawing(_ event: CanvasPointerEvent) {
        defer { activeID = nil; activeSamples = []; onLiveEnd() }
        guard project.timeline.masterRecordEnabled, let id = activeID, activeSamples.count > 1 else { return }
        let option = event.modifiers.contains(.option)
        let kind: MaterialGestureKind = option && event.modifiers.contains(.shift) ? .fix : (option ? .rewet : (event.secondary || event.modifiers.contains(.control) ? .wash : .pen))
        let curve = CurveFitter.fit(samples: activeSamples, recipe: fitRecipe, tolerance: project.camera.viewHeight * 0.002)
        let duration = activeSamples.last?.time ?? 0
        let clip = GestureClip(
            id: id,
            name: kind.rawValue.capitalized,
            startTime: project.timeline.playhead,
            duration: duration,
            samples: activeSamples,
            curve: curve,
            strokeProfile: StrokeProfile(size: kind == .pen ? width : washWidth),
            kind: kind,
            color: inkColor,
            flow: flow,
            bleed: bleed,
            dry: dry,
            brushInk: brushInk
        )
        project.gestures.append(clip)
        project.sceneObjects.append(SceneObject(id: id, name: clip.name, payload: .gesture(id)))
        if kind == .pen || kind == .wash {
            legacyPaths.append(InkEditorPath(id: id,
                                             points: activeSamples.map { project.camera.viewportUV(fromWorldPoint: $0.position, aspect: aspect) },
                                             brushMode: kind == .pen ? .pen : .brush,
                                             inkKind: inkKind,
                                             width: kind == .pen ? width : washWidth,
                                             flow: flow, bleed: bleed, dry: dry, brushInk: brushInk, color: inkColor))
        }
        selectedGestureIDs = [id]
        project.timeline.duration = max(project.timeline.duration, project.timeline.playhead + duration)
        onProjectChanged()
    }

    private func handleSelection(_ event: CanvasPointerEvent, world: CGPoint, rect: CGRect) {
        switch event.phase {
        case .began:
            originalGestures = project.gestures
            dragWorldStart = world
            if editingPoints, let tangent = nearestTangent(to: world, rect: rect) {
                selectedGestureIDs = [tangent.gestureID]
                selectedAnchorID = tangent.anchorID
                selectedTangent = (tangent.anchorID, tangent.outgoing)
                return
            }
            if editingPoints, let hit = nearestAnchor(to: world, rect: rect) {
                selectedGestureIDs = [hit.gestureID]
                selectedAnchorID = hit.anchorID
                selectedTangent = nil
                return
            }
            if editingPoints, let hit = nearestGesture(to: world, rect: rect), selectedGestureIDs.contains(hit.id) {
                insertAnchor(in: hit.id, near: world)
                return
            }
            if let hit = nearestGesture(to: world, rect: rect) {
                if event.modifiers.contains(.shift) { selectedGestureIDs.insert(hit.id) }
                else { selectedGestureIDs = [hit.id] }
                if event.clickCount >= 2 { editingPoints = true }
                if event.modifiers.contains(.option) { duplicateSelection() }
            } else {
                if !event.modifiers.contains(.shift) { selectedGestureIDs = [] }
                marqueeStart = world; marqueeEnd = world
            }
        case .changed:
            if marqueeStart != nil {
                marqueeEnd = world
                updateMarqueeSelection()
            } else if let tangent = selectedTangent, editingPoints {
                moveTangent(tangent, to: world, symmetric: !event.modifiers.contains(.option))
            } else if let selectedAnchorID, editingPoints {
                moveAnchor(id: selectedAnchorID, to: world)
            } else if let start = dragWorldStart {
                let raw = CGPoint(x: world.x - start.x, y: world.y - start.y)
                let delta: CGPoint
                if event.modifiers.contains(.shift) {
                    delta = abs(raw.x) > abs(raw.y) ? CGPoint(x: raw.x, y: 0) : CGPoint(x: 0, y: raw.y)
                } else { delta = raw }
                translateSelection(delta)
            }
        case .ended:
            marqueeStart = nil; marqueeEnd = nil; originalGestures = []; dragWorldStart = nil; selectedTangent = nil
            onProjectChanged()
        }
    }

    private func pan(_ delta: CGSize, rect: CGRect) {
        let size = project.camera.viewSize(aspect: aspect)
        let local = CGPoint(x: -delta.width / max(1, rect.width) * size.width,
                            y: -delta.height / max(1, rect.height) * size.height)
        let c = cos(project.camera.rotation), s = sin(project.camera.rotation)
        project.camera.center.x += local.x * c - local.y * s
        project.camera.center.y += local.x * s + local.y * c
        onProjectChanged()
    }

    private func zoom(_ factor: CGFloat, anchor: CGPoint, rect: CGRect) {
        guard factor.isFinite, factor > 0 else { return }
        let before = worldPoint(anchor, rect: rect)
        project.camera.viewHeight = min(1_000_000, max(0.000_01, project.camera.viewHeight / factor))
        let after = worldPoint(anchor, rect: rect)
        project.camera.center.x += before.x - after.x
        project.camera.center.y += before.y - after.y
        onProjectChanged()
    }

    private func deleteSelection() {
        if editingPoints, let anchorID = selectedAnchorID,
           let gestureIndex = project.gestures.firstIndex(where: { selectedGestureIDs.contains($0.id) }),
           project.gestures[gestureIndex].curve.anchors.count > 2 {
            project.gestures[gestureIndex].curve.anchors.removeAll { $0.id == anchorID }
            project.gestures[gestureIndex].curve.hasCustomGeometry = true
            selectedAnchorID = nil
        } else {
            project.gestures.removeAll { selectedGestureIDs.contains($0.id) }
            project.sceneObjects.removeAll { selectedGestureIDs.contains($0.id) }
            selectedGestureIDs = []
        }
        onProjectChanged()
    }

    private func duplicateSelection() {
        let copies = project.gestures.filter { selectedGestureIDs.contains($0.id) }.map { source -> GestureClip in
            var copy = source
            copy.id = UUID(); copy.name += " copy"
            copy.samples = copy.samples.map { var value = $0; value.position.x += project.camera.viewHeight * 0.02; value.position.y += project.camera.viewHeight * 0.02; return value }
            copy.curve.anchors = copy.curve.anchors.map { var value = $0; value.id = UUID(); value.position.x += project.camera.viewHeight * 0.02; value.position.y += project.camera.viewHeight * 0.02; return value }
            return copy
        }
        project.gestures.append(contentsOf: copies)
        project.sceneObjects.append(contentsOf: copies.map { SceneObject(id: $0.id, name: $0.name, payload: .gesture($0.id)) })
        selectedGestureIDs = Set(copies.map(\.id))
    }

    private func translateSelection(_ delta: CGPoint) {
        project.gestures = originalGestures.map { source in
            guard selectedGestureIDs.contains(source.id) else { return source }
            var value = source
            value.samples = value.samples.map { var sample = $0; sample.position.x += delta.x; sample.position.y += delta.y; return sample }
            value.curve.anchors = value.curve.anchors.map { var anchor = $0; anchor.position.x += delta.x; anchor.position.y += delta.y; return anchor }
            return value
        }
    }

    private func moveAnchor(id: UUID, to world: CGPoint) {
        guard let gestureIndex = project.gestures.firstIndex(where: { selectedGestureIDs.contains($0.id) }),
              let anchorIndex = project.gestures[gestureIndex].curve.anchors.firstIndex(where: { $0.id == id }) else { return }
        project.gestures[gestureIndex].curve.anchors[anchorIndex].position = world
        project.gestures[gestureIndex].curve.hasCustomGeometry = true
    }

    private func moveTangent(_ selection: (anchorID: UUID, outgoing: Bool), to world: CGPoint, symmetric: Bool) {
        guard let gestureIndex = project.gestures.firstIndex(where: { selectedGestureIDs.contains($0.id) }),
              let anchorIndex = project.gestures[gestureIndex].curve.anchors.firstIndex(where: { $0.id == selection.anchorID }) else { return }
        let anchor = project.gestures[gestureIndex].curve.anchors[anchorIndex]
        let offset = CGPoint(x: world.x - anchor.position.x, y: world.y - anchor.position.y)
        if selection.outgoing {
            project.gestures[gestureIndex].curve.anchors[anchorIndex].tangentOut = offset
            if symmetric { project.gestures[gestureIndex].curve.anchors[anchorIndex].tangentIn = CGPoint(x: -offset.x, y: -offset.y) }
        } else {
            project.gestures[gestureIndex].curve.anchors[anchorIndex].tangentIn = offset
            if symmetric { project.gestures[gestureIndex].curve.anchors[anchorIndex].tangentOut = CGPoint(x: -offset.x, y: -offset.y) }
        }
        project.gestures[gestureIndex].curve.anchors[anchorIndex].kind = symmetric ? .symmetric : .smooth
        project.gestures[gestureIndex].curve.hasCustomGeometry = true
    }

    private func insertAnchor(in gestureID: UUID, near point: CGPoint) {
        guard let gestureIndex = project.gestures.firstIndex(where: { $0.id == gestureID }) else { return }
        let anchors = project.gestures[gestureIndex].curve.anchors
        guard anchors.count > 1 else { return }
        var best = (index: 0, distance: CGFloat.greatestFiniteMagnitude, point: point)
        for index in 0..<(anchors.count - 1) {
            let a = anchors[index].position, b = anchors[index + 1].position
            let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
            let t = length > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
            let q = CGPoint(x: a.x + t * dx, y: a.y + t * dy)
            let d = hypot(point.x - q.x, point.y - q.y)
            if d < best.distance { best = (index, d, q) }
        }
        let id = UUID()
        project.gestures[gestureIndex].curve.anchors.insert(CurveAnchor(id: id, position: best.point), at: best.index + 1)
        project.gestures[gestureIndex].curve.hasCustomGeometry = true
        selectedAnchorID = id
    }

    private func updateMarqueeSelection() {
        guard let a = marqueeStart, let b = marqueeEnd else { return }
        let box = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
        selectedGestureIDs = Set(project.gestures.filter { box.intersects($0.curve.bounds) }.map(\.id))
    }

    private func nearestGesture(to point: CGPoint, rect: CGRect) -> GestureClip? {
        let threshold = project.camera.viewHeight * 9 / max(1, rect.height)
        return project.gestures.map { ($0, distance(point, to: $0.curve.sampled())) }
            .filter { $0.1 <= threshold }.min { $0.1 < $1.1 }?.0
    }

    private func nearestAnchor(to point: CGPoint, rect: CGRect) -> (gestureID: UUID, anchorID: UUID)? {
        let threshold = project.camera.viewHeight * 10 / max(1, rect.height)
        var best: (UUID, UUID, CGFloat)?
        for gesture in project.gestures where selectedGestureIDs.contains(gesture.id) {
            for anchor in gesture.curve.anchors {
                let value = hypot(anchor.position.x - point.x, anchor.position.y - point.y)
                if value <= threshold, best == nil || value < best!.2 { best = (gesture.id, anchor.id, value) }
            }
        }
        return best.map { ($0.0, $0.1) }
    }

    private func nearestTangent(to point: CGPoint, rect: CGRect) -> (gestureID: UUID, anchorID: UUID, outgoing: Bool)? {
        let threshold = project.camera.viewHeight * 10 / max(1, rect.height)
        var best: (UUID, UUID, Bool, CGFloat)?
        for gesture in project.gestures where selectedGestureIDs.contains(gesture.id) {
            for anchor in gesture.curve.anchors {
                for (outgoing, tangent) in [(false, anchor.tangentIn), (true, anchor.tangentOut)] where tangent != .zero {
                    let q = CGPoint(x: anchor.position.x + tangent.x, y: anchor.position.y + tangent.y)
                    let value = hypot(q.x - point.x, q.y - point.y)
                    if value <= threshold, best == nil || value < best!.3 { best = (gesture.id, anchor.id, outgoing, value) }
                }
            }
        }
        return best.map { ($0.0, $0.1, $0.2) }
    }

    private func distance(_ point: CGPoint, to points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return .greatestFiniteMagnitude }
        return zip(points, points.dropFirst()).map { distanceToSegment(point, $0, $1) }.min() ?? .greatestFiniteMagnitude
    }

    private func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    private var aspect: CGFloat { max(0.000_001, outputSize.width / max(1, outputSize.height)) }
    private func worldPoint(_ point: CGPoint, rect: CGRect) -> CGPoint {
        let uv = CGPoint(x: (point.x - rect.minX) / max(1, rect.width), y: (point.y - rect.minY) / max(1, rect.height))
        return project.camera.worldPoint(fromViewportUV: uv, aspect: aspect)
    }
    private func viewPoint(_ point: CGPoint, rect: CGRect) -> CGPoint {
        let uv = project.camera.viewportUV(fromWorldPoint: point, aspect: aspect)
        return CGPoint(x: rect.minX + uv.x * rect.width, y: rect.minY + uv.y * rect.height)
    }
    private func fittedRect(container: CGSize, content: CGSize) -> CGRect {
        guard content.width > 0, content.height > 0 else { return CGRect(origin: .zero, size: container) }
        let scale = min(container.width / content.width, container.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
    private func color(_ rgba: RGBAColor) -> Color { Color(.sRGB, red: Double(rgba.red), green: Double(rgba.green), blue: Double(rgba.blue), opacity: Double(rgba.alpha)) }
}
