import Foundation
import SketchCamCore

/// Thread-safe because the UI mutates history on the main actor while the
/// processing queue reads a stable path snapshot every frame.
final class CanvasActionHistory: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger = CanvasActionLedger()
    private var revision: UInt64 = 0

    func replayPaths() -> [InkEditorPath] {
        lock.withLock { ledger.replayPaths }
    }

    func replayPaths(frameID: UUID?, includeUntagged: Bool = false) -> [InkEditorPath] {
        lock.withLock { ledger.replayPaths(frameID: frameID, includeUntagged: includeUntagged) }
    }

    /// A coherent snapshot for path-signal consumers. The revision changes with
    /// every ledger mutation so cached drawing producers know when to rerender.
    func pathSnapshot() -> (paths: [InkEditorPath], revision: UInt64) {
        lock.withLock { (ledger.replayPaths, revision) }
    }

    func records() -> [InkStrokeRecord] {
        lock.withLock { ledger.records }
    }

    func canUndo() -> Bool { lock.withLock { ledger.canUndo } }
    func canRedo() -> Bool { lock.withLock { ledger.canRedo } }

    func replaceAll(_ records: [InkStrokeRecord]) {
        lock.withLock {
            ledger.replaceAll(records)
            revision &+= 1
        }
    }

    func commit(_ record: InkStrokeRecord) {
        lock.withLock {
            ledger.commit(record)
            revision &+= 1
        }
    }

    func commitImmediate(_ path: InkEditorPath) {
        lock.withLock {
            ledger.commitImmediate(path)
            revision &+= 1
        }
    }

    func commitImmediate(_ record: InkStrokeRecord) {
        lock.withLock {
            ledger.commitImmediate(record)
            revision &+= 1
        }
    }

    /// Reconcile the editable model without exposing immediate actions. New
    /// editable strokes are appended at execution time; edits update their
    /// existing action in place; deleted paths remove their render action.
    func replaceEditableRecords(_ records: [InkStrokeRecord]) {
        lock.withLock {
            ledger.replaceEditableRecords(records)
            revision &+= 1
        }
    }

    func replaceEditablePaths(_ paths: [InkEditorPath]) {
        lock.withLock {
            ledger.replaceEditablePaths(paths)
            revision &+= 1
        }
    }

    @discardableResult
    func undo() -> CanvasStrokeAction? {
        lock.withLock {
            let action = ledger.undo()
            if action != nil { revision &+= 1 }
            return action
        }
    }

    @discardableResult
    func redo() -> CanvasStrokeAction? {
        lock.withLock {
            let action = ledger.redo()
            if action != nil { revision &+= 1 }
            return action
        }
    }

    func clear() {
        lock.withLock {
            ledger.clear()
            revision &+= 1
        }
    }

    func clear(frameID: UUID?, includeUntagged: Bool = false) {
        lock.withLock {
            ledger.clear(frameID: frameID, includeUntagged: includeUntagged)
            revision &+= 1
        }
    }
}
