import CoreGraphics
import Foundation
import SketchCamCore

/// The minimum the ink engine needs for the in-progress stroke: the latest
/// point plus the stroke's parameters. The engine damps toward `point` and only
/// ever uses the latest sample, so this is O(1) per mouse move — no growing
/// array, and (crucially) it never touches the `@Published` settings struct.
struct InkLiveStrokeSample: Equatable {
    var id: UUID
    var point: CGPoint
    var brushMode: InkBrushMode
    var inkKind: InkKind
    var width: Float
    var flow: Float
    var brushInk: Float
    var color: RGBAColor
}

/// Thread-safe hand-off of the live stroke from the drawing UI (main thread) to
/// the ink engine (processing queue). Replaces routing the live path through
/// `ProcessingSettings`, which re-rendered the whole UI on every mouse move.
final class InkLiveStroke {
    private let lock = NSLock()
    private var sample: InkLiveStrokeSample?
    private var endedID: UUID?

    /// Called per mouse move while drawing.
    func update(_ s: InkLiveStrokeSample) {
        lock.lock(); sample = s; lock.unlock()
    }

    /// Called once when the stroke finishes; the engine bakes that id.
    func end() {
        lock.lock()
        endedID = sample?.id
        sample = nil
        lock.unlock()
    }

    /// Discard any in-progress stroke WITHOUT baking (clear / undo / redo).
    func cancel() {
        lock.lock()
        sample = nil
        endedID = nil
        lock.unlock()
    }

    /// Engine reads the active sample and consumes any just-ended id (delivered
    /// exactly once).
    func consume() -> (active: InkLiveStrokeSample?, ended: UUID?) {
        lock.lock(); defer { lock.unlock() }
        let e = endedID
        endedID = nil
        return (sample, e)
    }
}
