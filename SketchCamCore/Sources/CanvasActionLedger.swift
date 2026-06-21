import Foundation

/// A completed mutation of the ink artifact. Immediate actions remain private
/// to the ledger; editable actions also have a matching `InkEditorPath` in the
/// UI model.
public struct CanvasStrokeAction: Equatable, Sendable, Identifiable {
    public let id: UUID
    public var path: InkEditorPath
    public var isEditable: Bool

    public init(path: InkEditorPath, isEditable: Bool) {
        id = path.id
        self.path = path
        self.isEditable = isEditable
    }
}

/// Ordered, deterministic source of truth for rebuilding the canvas. This is
/// deliberately independent of UI undo managers and Metal state.
public struct CanvasActionLedger: Equatable, Sendable {
    public private(set) var actions: [CanvasStrokeAction] = []
    public private(set) var redoActions: [CanvasStrokeAction] = []

    public init() {}

    public var replayPaths: [InkEditorPath] { actions.map(\.path) }
    public var canUndo: Bool { !actions.isEmpty }
    public var canRedo: Bool { !redoActions.isEmpty }

    public mutating func commitImmediate(_ path: InkEditorPath) {
        actions.append(CanvasStrokeAction(path: path, isEditable: false))
        redoActions.removeAll()
    }

    public mutating func replaceEditablePaths(_ paths: [InkEditorPath]) {
        let byID = Dictionary(uniqueKeysWithValues: paths.map { ($0.id, $0) })
        actions.removeAll { $0.isEditable && byID[$0.id] == nil }
        for index in actions.indices where actions[index].isEditable {
            if let path = byID[actions[index].id] { actions[index].path = path }
        }
        let existing = Set(actions.lazy.filter(\.isEditable).map(\.id))
        for path in paths where !existing.contains(path.id) {
            actions.append(CanvasStrokeAction(path: path, isEditable: true))
        }
        redoActions.removeAll()
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
