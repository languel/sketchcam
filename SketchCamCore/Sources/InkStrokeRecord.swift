import CoreGraphics
import Foundation

public struct InkStrokeModifierFlags: Equatable, Sendable, Codable {
    public var shift: Bool
    public var option: Bool
    public var command: Bool
    public var control: Bool

    public init(shift: Bool = false, option: Bool = false, command: Bool = false, control: Bool = false) {
        self.shift = shift
        self.option = option
        self.command = command
        self.control = control
    }
}

public struct InkStrokeSample: Equatable, Sendable, Codable {
    /// Normalized canvas-space point.
    public var point: CGPoint
    /// Seconds relative to the stroke's first sample.
    public var time: TimeInterval
    public var pressure: Float?
    public var modifiers: InkStrokeModifierFlags?
    /// Gesture-derived expressive charge, currently used by held wash strokes.
    public var charge: Float?

    public init(
        point: CGPoint,
        time: TimeInterval,
        pressure: Float? = nil,
        modifiers: InkStrokeModifierFlags? = nil,
        charge: Float? = nil
    ) {
        self.point = point
        self.time = time
        self.pressure = pressure
        self.modifiers = modifiers
        self.charge = charge
    }
}

public enum InkStrokeCaptureMode: String, Equatable, Sendable, Codable, CaseIterable, Identifiable {
    case pen
    case wash
    case wetOnly

    public var id: String { rawValue }
}

public struct InkStrokeCapture: Equatable, Sendable, Codable, Identifiable {
    public var id: UUID
    public var seed: UInt64
    public var rawSamples: [InkStrokeSample]
    public var canonicalSamples: [InkStrokeSample]
    public var duration: TimeInterval
    public var mode: InkStrokeCaptureMode

    public init(
        id: UUID = UUID(),
        seed: UInt64,
        rawSamples: [InkStrokeSample],
        canonicalSamples: [InkStrokeSample],
        duration: TimeInterval? = nil,
        mode: InkStrokeCaptureMode
    ) {
        self.id = id
        self.seed = seed
        self.rawSamples = rawSamples
        self.canonicalSamples = canonicalSamples
        self.duration = duration ?? canonicalSamples.last?.time ?? rawSamples.last?.time ?? 0
        self.mode = mode
    }
}

public enum InkRenderIntent: String, Equatable, Sendable, Codable, CaseIterable, Identifiable {
    case pen
    case wash
    case wetOnly

    public var id: String { rawValue }
}

public struct InkRenderRecipe: Equatable, Sendable, Codable {
    public var intent: InkRenderIntent
    public var inkKind: InkKind
    public var color: RGBAColor
    public var width: Float
    public var flow: Float
    public var bleed: Float
    public var dry: Float
    public var colorSeparation: Float
    public var brushInk: Float
    public var smoothing: Float
    public var algorithm: String

    public init(
        intent: InkRenderIntent,
        inkKind: InkKind = .black,
        color: RGBAColor = .ink,
        width: Float,
        flow: Float,
        bleed: Float,
        dry: Float,
        colorSeparation: Float,
        brushInk: Float,
        smoothing: Float,
        algorithm: String = "metal-ink-v1"
    ) {
        self.intent = intent
        self.inkKind = inkKind
        self.color = color
        self.width = width
        self.flow = flow
        self.bleed = bleed
        self.dry = dry
        self.colorSeparation = colorSeparation
        self.brushInk = brushInk
        self.smoothing = smoothing
        self.algorithm = algorithm
    }
}

public struct InkStrokeRecord: Equatable, Sendable, Codable, Identifiable {
    public var capture: InkStrokeCapture
    public var activeRender: InkRenderRecipe
    public var frameID: UUID?
    public var isVisible: Bool
    public var isEditable: Bool

    public var id: UUID { capture.id }

    public init(
        capture: InkStrokeCapture,
        activeRender: InkRenderRecipe,
        frameID: UUID? = nil,
        isVisible: Bool = true,
        isEditable: Bool
    ) {
        self.capture = capture
        self.activeRender = activeRender
        self.frameID = frameID
        self.isVisible = isVisible
        self.isEditable = isEditable
    }
}

public extension InkStrokeRecord {
    var renderPath: InkEditorPath {
        let samples = capture.canonicalSamples
        let points = samples.map(\.point)
        let times = samples.map(\.time)
        return InkEditorPath(
            id: id,
            points: points,
            sampleTimes: times.count == points.count ? times : nil,
            strokeSeed: capture.seed,
            brushMode: activeRender.intent == .pen ? .pen : .brush,
            inkKind: activeRender.inkKind,
            width: activeRender.width,
            flow: activeRender.flow,
            bleed: activeRender.bleed,
            dry: activeRender.dry,
            colorSeparation: activeRender.colorSeparation,
            brushInk: activeRender.brushInk,
            color: activeRender.color
        )
    }

    static func legacy(path: InkEditorPath, isEditable: Bool, fallbackSmoothing: Float = 0) -> InkStrokeRecord {
        let sampleTimes = normalizedSampleTimes(for: path)
        let samples = zip(path.points, sampleTimes).map {
            InkStrokeSample(point: $0.0, time: $0.1)
        }
        let brushMode = path.brushMode ?? .pen
        let mode: InkStrokeCaptureMode = brushMode == .pen ? .pen : .wash
        let intent: InkRenderIntent = brushMode == .pen ? .pen : .wash
        let seed = path.strokeSeed ?? stableSeed(for: path.id)
        let recipe = InkRenderRecipe(
            intent: intent,
            inkKind: path.inkKind ?? .black,
            color: path.color ?? .ink,
            width: path.width ?? 0.5,
            flow: path.flow ?? 0.9,
            bleed: path.bleed ?? 0.8,
            dry: path.dry ?? 0.25,
            colorSeparation: path.colorSeparation ?? 0.5,
            brushInk: path.brushInk ?? 0,
            smoothing: fallbackSmoothing
        )
        return InkStrokeRecord(
            capture: InkStrokeCapture(
                id: path.id,
                seed: seed,
                rawSamples: samples,
                canonicalSamples: samples,
                mode: mode
            ),
            activeRender: recipe,
            isEditable: isEditable
        )
    }

    func updatingRenderPath(_ path: InkEditorPath) -> InkStrokeRecord {
        let sampleTimes = InkStrokeRecord.normalizedSampleTimes(for: path)
        let canonical = zip(path.points, sampleTimes).map {
            InkStrokeSample(point: $0.0, time: $0.1)
        }
        var updated = self
        updated.capture = InkStrokeCapture(
            id: path.id,
            seed: path.strokeSeed ?? capture.seed,
            rawSamples: capture.rawSamples.isEmpty ? canonical : capture.rawSamples,
            canonicalSamples: canonical,
            mode: capture.mode
        )
        updated.activeRender = InkRenderRecipe(
            intent: (path.brushMode ?? .pen) == .pen ? .pen : activeRender.intent == .wetOnly ? .wetOnly : .wash,
            inkKind: path.inkKind ?? activeRender.inkKind,
            color: path.color ?? activeRender.color,
            width: path.width ?? activeRender.width,
            flow: path.flow ?? activeRender.flow,
            bleed: path.bleed ?? activeRender.bleed,
            dry: path.dry ?? activeRender.dry,
            colorSeparation: path.colorSeparation ?? activeRender.colorSeparation,
            brushInk: path.brushInk ?? activeRender.brushInk,
            smoothing: activeRender.smoothing,
            algorithm: activeRender.algorithm
        )
        return updated
    }

    static func normalizedSampleTimes(for path: InkEditorPath) -> [TimeInterval] {
        if let sampleTimes = path.sampleTimes, sampleTimes.count == path.points.count {
            return sampleTimes
        }
        guard path.points.count > 1 else { return path.points.map { _ in 0 } }
        return path.points.indices.map { TimeInterval($0) / 60 }
    }

    static func stableSeed(for id: UUID) -> UInt64 {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        return bytes.reduce(UInt64(0xcbf29ce484222325)) { hash, byte in
            (hash ^ UInt64(byte)) &* 0x100000001b3
        }
    }
}

public extension LandmarkSettings {
    func resolvedInkStrokeRecords(fallbackSmoothing: Float? = nil) -> [InkStrokeRecord] {
        if let inkStrokeRecords {
            return inkStrokeRecords
        }
        return inkPaths.map {
            InkStrokeRecord.legacy(path: $0, isEditable: true, fallbackSmoothing: fallbackSmoothing ?? inkSmoothing)
        }
    }
}
