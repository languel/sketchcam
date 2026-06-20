import CoreGraphics
import Foundation
import SketchCamCore

/// One cursor sample for the in-progress stroke: the latest point plus the
/// stroke's parameters. The channel accumulates the points across moves so the
/// engine can inject ink along ALL of them (dense), not just the latest.
struct InkLiveStrokeSample: Equatable {
    var id: UUID
    var point: CGPoint
    var brushMode: InkBrushMode
    var inkKind: InkKind
    var width: Float
    var flow: Float
    var brushInk: Float
    var color: RGBAColor
    /// Shift held → extra path smoothing this stroke.
    var smoothBoost: Bool
    /// Immediate wash → the brush re-mobilizes & pushes dried ink (destructive).
    var destructive: Bool
    /// Water-only spray: deposits wetness but no velocity, pigment, or lift.
    var wetOnly: Bool
    /// Fix-only brush: transfers local mobile/dried pigment into the permanent
    /// locked layer without velocity or new pigment.
    var fixOnly: Bool
    /// 0…1 "charge" from holding before dragging — multiplies destructive force.
    var charge: Float
}

/// Thread-safe hand-off of the live stroke from the drawing UI (main thread) to
/// the ink engine (processing queue), off the `@Published` settings path.
/// Accumulates every cursor point between engine frames so fast drags stay
/// dense — the engine reads ~30x/sec but the mouse moves ~60–120x/sec.
final class InkLiveStroke {
    private let lock = NSLock()
    private var latest: InkLiveStrokeSample?
    private var activeID: UUID?
    private var pending: [CGPoint] = []
    private var endedID: UUID?

    /// Called per mouse move while drawing.
    func update(_ s: InkLiveStrokeSample) {
        lock.lock()
        if activeID != s.id {
            activeID = s.id
            pending.removeAll(keepingCapacity: true)
        }
        latest = s
        pending.append(s.point)
        lock.unlock()
    }

    /// Called once when the stroke finishes; the engine bakes that id.
    func end() {
        lock.lock()
        endedID = activeID
        activeID = nil
        latest = nil
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    /// Discard any in-progress stroke WITHOUT baking (clear / undo / redo).
    func cancel() {
        lock.lock()
        activeID = nil
        latest = nil
        pending.removeAll(keepingCapacity: true)
        endedID = nil
        lock.unlock()
    }

    /// Engine reads the active sample (params), all points captured this frame
    /// (cleared), and any just-ended id (delivered once).
    func consume() -> (sample: InkLiveStrokeSample?, points: [CGPoint], ended: UUID?) {
        lock.lock(); defer { lock.unlock() }
        let e = endedID
        endedID = nil
        guard let latest else { return (nil, [], e) }
        let pts = pending
        pending.removeAll(keepingCapacity: true)
        return (latest, pts, e)
    }
}
