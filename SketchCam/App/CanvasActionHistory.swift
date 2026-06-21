import Foundation
import SketchCamCore

/// Thread-safe because the UI mutates history on the main actor while the
/// processing queue reads a stable path snapshot every frame.
final class CanvasActionHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger = CanvasActionLedger()

    func replayPaths() -> [InkEditorPath] {
        lock.withLock { ledger.replayPaths }
    }

    func canUndo() -> Bool { lock.withLock { ledger.canUndo } }
    func canRedo() -> Bool { lock.withLock { ledger.canRedo } }

    func commitImmediate(_ path: InkEditorPath) {
        lock.withLock { ledger.commitImmediate(path) }
    }

    /// Reconcile the editable model without exposing immediate actions. New
    /// editable strokes are appended at execution time; edits update their
    /// existing action in place; deleted paths remove their render action.
    func replaceEditablePaths(_ paths: [InkEditorPath]) {
        lock.withLock { ledger.replaceEditablePaths(paths) }
    }

    @discardableResult
    func undo() -> CanvasStrokeAction? {
        lock.withLock { ledger.undo() }
    }

    @discardableResult
    func redo() -> CanvasStrokeAction? {
        lock.withLock { ledger.redo() }
    }

    func clear() {
        lock.withLock { ledger.clear() }
    }
}
