import Foundation
import os

enum PipelineStage: String, CaseIterable {
    case snapshot   // settings/format snapshot acquisition
    case overlay    // landmark overlay layer (cached; cost only on re-render)
    case process    // Core Image chain + composite + render to pixel buffer
    case preview    // preview CGImage creation
    case publish    // sink enqueue
    case detect     // landmark detection (off hot path, detection queue)
    case total      // camera callback → published

    var displayName: String {
        switch self {
        case .snapshot: return "Snapshot"
        case .overlay: return "Overlay"
        case .process: return "Process"
        case .preview: return "Preview"
        case .publish: return "Publish"
        case .detect: return "Detect"
        case .total: return "Frame total"
        }
    }
}

/// Per-stage wall-clock timing with os_signpost intervals (visible in
/// Instruments under subsystem io.github.languel.sketchcam) and an
/// exponentially-weighted rolling average for the in-app debug grid.
final class PipelineTimings {
    private static let signposter = OSSignposter(
        subsystem: "io.github.languel.sketchcam",
        category: "pipeline"
    )

    private let lock = NSLock()
    private var averageSeconds: [PipelineStage: Double] = [:]
    private let smoothing = 0.15

    func measure<T>(_ stage: PipelineStage, _ body: () throws -> T) rethrows -> T {
        let signpostID = Self.signposter.makeSignpostID()
        let state = Self.signposter.beginInterval("stage", id: signpostID, "\(stage.rawValue)")
        let start = CFAbsoluteTimeGetCurrent()
        defer {
            record(stage, seconds: CFAbsoluteTimeGetCurrent() - start)
            Self.signposter.endInterval("stage", state)
        }
        return try body()
    }

    func record(_ stage: PipelineStage, seconds: Double) {
        lock.lock()
        defer { lock.unlock() }
        if let previous = averageSeconds[stage] {
            averageSeconds[stage] = previous + (seconds - previous) * smoothing
        } else {
            averageSeconds[stage] = seconds
        }
    }

    /// Rolling-average milliseconds per stage, in display order.
    func snapshotMillis() -> [(stage: PipelineStage, millis: Double)] {
        lock.lock()
        defer { lock.unlock() }
        return PipelineStage.allCases.compactMap { stage in
            averageSeconds[stage].map { (stage, $0 * 1_000) }
        }
    }
}
