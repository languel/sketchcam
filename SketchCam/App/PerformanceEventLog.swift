import Foundation
import SketchCamCore

/// Append-only process history. Undo history may rewrite the canvas state;
/// this log records that the undo/redo itself happened for future NRT replay.
final class PerformanceEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [PerformanceEvent] = []
    private let epoch = ProcessInfo.processInfo.systemUptime

    func append(kind: PerformanceEventKind, path: InkEditorPath? = nil, actionID: UUID? = nil,
                material: PerformanceMaterialSnapshot? = nil) {
        let now = ProcessInfo.processInfo.systemUptime - epoch
        let duration = path?.sampleTimes?.last ?? 0
        let event = PerformanceEvent(
            kind: kind,
            startedAt: max(0, now - duration),
            endedAt: now,
            actionID: actionID ?? path?.id,
            path: path,
            timingEstimated: path?.sampleTimes == nil, material: material
        )
        lock.withLock { events.append(event) }
    }

    func snapshot() -> [PerformanceEvent] { lock.withLock { events } }
    func clear() { lock.withLock { events.removeAll(keepingCapacity: true) } }

    func migrateIfEmpty(_ paths: [InkEditorPath]) {
        lock.withLock {
            guard events.isEmpty, !paths.isEmpty else { return }
            var cursor = 0.0
            for path in paths {
                let duration = max(0.05, path.sampleTimes?.last ?? 0.25)
                events.append(PerformanceEvent(
                    kind: (path.brushMode ?? .pen) == .pen ? .pen : .wash,
                    startedAt: cursor, endedAt: cursor + duration,
                    actionID: path.id, path: path, timingEstimated: path.sampleTimes == nil
                ))
                cursor += duration + 0.1
            }
        }
    }
}
