import Foundation

/// A completed mutation of the ink artifact. Immediate actions remain private
/// to the ledger; editable actions also have a matching `InkEditorPath` in the
/// UI model.
public struct CanvasStrokeAction: Equatable, Sendable, Identifiable {
    public var record: InkStrokeRecord

    public var id: UUID { record.id }
    public var path: InkEditorPath { record.renderPath }
    public var isEditable: Bool { record.isEditable }

    public init(path: InkEditorPath, isEditable: Bool) {
        self.record = InkStrokeRecord.legacy(path: path, isEditable: isEditable)
    }

    public init(record: InkStrokeRecord) {
        self.record = record
    }
}

/// Ordered, deterministic source of truth for rebuilding the canvas. This is
/// deliberately independent of UI undo managers and Metal state.
public struct CanvasActionLedger: Equatable, Sendable {
    public private(set) var actions: [CanvasStrokeAction] = []
    public private(set) var redoActions: [CanvasStrokeAction] = []

    public init() {}

    public var records: [InkStrokeRecord] { actions.map(\.record) }
    public var replayPaths: [InkEditorPath] { actions.map(\.record).filter(\.isVisible).map(\.renderPath) }
    public var canUndo: Bool { !actions.isEmpty }
    public var canRedo: Bool { !redoActions.isEmpty }

    public mutating func replaceAll(_ records: [InkStrokeRecord]) {
        actions = records.map(CanvasStrokeAction.init(record:))
        redoActions.removeAll()
    }

    public mutating func commit(_ record: InkStrokeRecord) {
        actions.append(CanvasStrokeAction(record: record))
        redoActions.removeAll()
    }

    public mutating func commitImmediate(_ path: InkEditorPath) {
        commit(InkStrokeRecord.legacy(path: path, isEditable: false))
    }

    public mutating func commitImmediate(_ record: InkStrokeRecord) {
        var immediate = record
        immediate.isEditable = false
        commit(immediate)
    }

    public mutating func replaceEditableRecords(_ records: [InkStrokeRecord]) {
        let editableRecords = records.map { record in
            var copy = record
            copy.isEditable = true
            return copy
        }
        let byID = Dictionary(uniqueKeysWithValues: editableRecords.map { ($0.id, $0) })
        actions.removeAll { $0.isEditable && byID[$0.id] == nil }
        for index in actions.indices where actions[index].isEditable {
            if let record = byID[actions[index].id] { actions[index].record = record }
        }
        let existing = Set(actions.lazy.filter(\.isEditable).map(\.id))
        for record in editableRecords where !existing.contains(record.id) {
            actions.append(CanvasStrokeAction(record: record))
        }
        redoActions.removeAll()
    }

    public mutating func replaceEditablePaths(_ paths: [InkEditorPath]) {
        let existing = Dictionary(uniqueKeysWithValues: actions.map { ($0.id, $0.record) })
        let records = paths.map { path in
            if let record = existing[path.id] {
                return record.updatingRenderPath(path)
            }
            return InkStrokeRecord.legacy(path: path, isEditable: true)
        }
        replaceEditableRecords(records)
    }

    @discardableResult
    public mutating func undo() -> CanvasStrokeAction? {
        guard let action = actions.popLast() else { return nil }
        redoActions.append(action)
        return action
    }

    @discardableResult
    public mutating func redo() -> CanvasStrokeAction? {
        guard let action = redoActions.popLast() else { return nil }
        actions.append(action)
        return action
    }

    public mutating func clear() {
        actions.removeAll()
        redoActions.removeAll()
    }
}
