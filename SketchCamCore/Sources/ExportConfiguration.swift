import Foundation

public enum ExportOutputKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case still, movie, imageSequence, gif
    public var id: String { rawValue }
}

public enum ExportImageFormat: String, Codable, Sendable, CaseIterable, Identifiable {
    case png, tiff, jpeg, heif
    public var id: String { rawValue }
    public var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
}

public enum ExportMovieCodec: String, Codable, Sendable, CaseIterable, Identifiable {
    case h264, hevc, proRes422, proRes422HQ, proRes4444
    public var id: String { rawValue }
    public var supportsAlpha: Bool { self == .proRes4444 }
}

public enum ExportContainer: String, Codable, Sendable, CaseIterable, Identifiable {
    case mov, mp4
    public var id: String { rawValue }
}

public enum ExportRenderMode: String, Codable, Sendable, CaseIterable, Identifiable {
    case live, nrtReplay, nrtContinue
    public var id: String { rawValue }
}

public enum ExportFraming: String, Codable, Sendable, CaseIterable, Identifiable {
    case fit, fill, stretch
    public var id: String { rawValue }
}

public enum ExportColorSpace: String, Codable, Sendable, CaseIterable, Identifiable {
    case sRGB, displayP3
    public var id: String { rawValue }
}

public enum ExportReplayTiming: String, Codable, Sendable, CaseIterable, Identifiable {
    case original, removeIdleGaps, fixedGap
    public var id: String { rawValue }
}

public enum CaptureTrigger: String, Codable, Sendable, CaseIterable, Identifiable {
    case cadence, interval, manual
    case mouseDown, mouseUp, click, dragBegin, dragEnd
    case drawBegin, drawEnd, drawBoth, washBegin, washEnd, washBoth
    case anyCanvasAction, streamCrossing
    public var id: String { rawValue }
}

public enum CaptureComparator: String, Codable, Sendable, CaseIterable, Identifiable {
    case below, above, inside, outside
    public var id: String { rawValue }
}

public enum ExportMetric: String, Codable, Sendable, CaseIterable, Identifiable {
    case meanLuma, thresholdCoverage, alphaCoverage, frameChange, motionMagnitude
    public var id: String { rawValue }
}

public enum CaptureGateKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case mouseDown, mouseDragging, drawActive, washActive
    case inkSolverActive, inkPixelsChanging, streamMetric
    public var id: String { rawValue }
}

public struct CaptureGate: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var enabled: Bool
    public var kind: CaptureGateKind
    public var layerID: UUID?
    public var metric: ExportMetric
    public var comparison: CaptureComparator
    public var lowerBound: Double
    public var upperBound: Double

    public init(id: UUID = UUID(), enabled: Bool = true, kind: CaptureGateKind,
                layerID: UUID? = nil, metric: ExportMetric = .frameChange,
                comparison: CaptureComparator = .above, lowerBound: Double = 0.01,
                upperBound: Double = 1) {
        self.id = id
        self.enabled = enabled
        self.kind = kind
        self.layerID = layerID
        self.metric = metric
        self.comparison = comparison
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }
}

public struct ExportConfiguration: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var outputKind: ExportOutputKind
    public var imageFormat: ExportImageFormat
    public var movieCodec: ExportMovieCodec
    public var container: ExportContainer
    public var renderMode: ExportRenderMode
    public var width: Int
    public var height: Int
    public var framing: ExportFraming
    public var colorSpace: ExportColorSpace
    public var quality: Double
    public var includeAlpha: Bool
    public var captureFPS: Double
    public var playbackFPS: Double
    public var simulationFPS: Double
    public var trigger: CaptureTrigger
    public var gates: [CaptureGate]
    public var minimumEventInterval: Double
    public var sourceAdvanceFrames: Int
    public var sourceAdvanceSeconds: Double
    public var loopSource: Bool
    public var maximumFrames: Int
    public var maximumDuration: Double
    public var minimumFreeDiskGB: Double
    public var writeMetadata: Bool
    public var writePoster: Bool
    public var replayTiming: ExportReplayTiming
    public var fixedReplayGap: Double
    public var replaySpeed: Double
    public var takeName: String

    public init(outputKind: ExportOutputKind = .still, imageFormat: ExportImageFormat = .png,
                movieCodec: ExportMovieCodec = .h264, container: ExportContainer = .mov,
                renderMode: ExportRenderMode = .live, width: Int = 1920, height: Int = 1080,
                framing: ExportFraming = .fit, colorSpace: ExportColorSpace = .sRGB,
                quality: Double = 0.9, includeAlpha: Bool = false,
                captureFPS: Double = 30, playbackFPS: Double = 30, simulationFPS: Double = 60,
                trigger: CaptureTrigger = .cadence, gates: [CaptureGate] = [],
                minimumEventInterval: Double = 0, sourceAdvanceFrames: Int = 0,
                sourceAdvanceSeconds: Double = 0, loopSource: Bool = false,
                maximumFrames: Int = 0, maximumDuration: Double = 0,
                minimumFreeDiskGB: Double = 1, writeMetadata: Bool = false,
                writePoster: Bool = false, replayTiming: ExportReplayTiming = .original,
                fixedReplayGap: Double = 0.25, replaySpeed: Double = 1, takeName: String = "take-001") {
        self.version = Self.currentVersion
        self.outputKind = outputKind
        self.imageFormat = imageFormat
        self.movieCodec = movieCodec
        self.container = container
        self.renderMode = renderMode
        self.width = width
        self.height = height
        self.framing = framing
        self.colorSpace = colorSpace
        self.quality = quality
        self.includeAlpha = includeAlpha
        self.captureFPS = captureFPS
        self.playbackFPS = playbackFPS
        self.simulationFPS = simulationFPS
        self.trigger = trigger
        self.gates = gates
        self.minimumEventInterval = minimumEventInterval
        self.sourceAdvanceFrames = sourceAdvanceFrames
        self.sourceAdvanceSeconds = sourceAdvanceSeconds
        self.loopSource = loopSource
        self.maximumFrames = maximumFrames
        self.maximumDuration = maximumDuration
        self.minimumFreeDiskGB = minimumFreeDiskGB
        self.writeMetadata = writeMetadata
        self.writePoster = writePoster
        self.replayTiming = replayTiming
        self.fixedReplayGap = fixedReplayGap
        self.replaySpeed = replaySpeed
        self.takeName = takeName
    }

    public mutating func clamp() {
        width = max(1, width); height = max(1, height)
        captureFPS = min(360, max(0.001, captureFPS))
        playbackFPS = min(360, max(0.001, playbackFPS))
        simulationFPS = min(360, max(1, simulationFPS))
        quality = min(1, max(0, quality))
        replaySpeed = min(100, max(0.01, replaySpeed))
        minimumEventInterval = max(0, minimumEventInterval)
        maximumFrames = max(0, maximumFrames)
        maximumDuration = max(0, maximumDuration)
        if !movieCodec.supportsAlpha { includeAlpha = false }
        if container == .mp4 && movieCodec != .h264 && movieCodec != .hevc { container = .mov }
    }
}

public struct ExportPreset: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var configuration: ExportConfiguration

    public init(id: UUID = UUID(), name: String, configuration: ExportConfiguration) {
        self.id = id; self.name = name; self.configuration = configuration
    }
}

public struct ExportFrameMetadata: Codable, Sendable, Equatable {
    public var frameIndex: Int
    public var renderTime: Double
    public var wallTime: Double
    public var trigger: CaptureTrigger
    public var duplicated: Bool
    public var dropped: Bool
    public var sourceTime: Double?
    public var actionID: UUID?

    public init(frameIndex: Int, renderTime: Double, wallTime: Double,
                trigger: CaptureTrigger, duplicated: Bool, dropped: Bool,
                sourceTime: Double? = nil, actionID: UUID? = nil) {
        self.frameIndex = frameIndex
        self.renderTime = renderTime
        self.wallTime = wallTime
        self.trigger = trigger
        self.duplicated = duplicated
        self.dropped = dropped
        self.sourceTime = sourceTime
        self.actionID = actionID
    }
}

public struct ExportSessionMetadata: Codable, Sendable, Equatable {
    public var configuration: ExportConfiguration
    public var frames: [ExportFrameMetadata]

    public init(configuration: ExportConfiguration, frames: [ExportFrameMetadata]) {
        self.configuration = configuration; self.frames = frames
    }
}

public struct InkActivitySnapshot: Codable, Sendable, Equatable {
    public var solverActive: Bool
    public var physicalChange: Double

    public init(solverActive: Bool = false, physicalChange: Double = 0) {
        self.solverActive = solverActive
        self.physicalChange = physicalChange
    }
}

public enum ExportTiming {
    public static func presentationTime(frameIndex: Int, fps: Double) -> Double {
        Double(max(0, frameIndex)) / min(360, max(0.001, fps))
    }

    public static func condition(_ value: Double, comparison: CaptureComparator,
                                 lower: Double, upper: Double) -> Bool {
        switch comparison {
        case .below: value < lower
        case .above: value > lower
        case .inside: value >= lower && value <= upper
        case .outside: value < lower || value > upper
        }
    }
}

public enum PerformanceEventKind: String, Codable, Sendable {
    case pen, wash, fix, unfix, wetCanvas, dryCanvas, clear, undo, redo
}

public struct PerformanceEvent: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var kind: PerformanceEventKind
    public var startedAt: Double
    public var endedAt: Double
    public var actionID: UUID?
    public var path: InkEditorPath?
    public var timingEstimated: Bool

    public init(id: UUID = UUID(), kind: PerformanceEventKind, startedAt: Double,
                endedAt: Double, actionID: UUID? = nil, path: InkEditorPath? = nil,
                timingEstimated: Bool = false) {
        self.id = id; self.kind = kind; self.startedAt = startedAt; self.endedAt = endedAt
        self.actionID = actionID; self.path = path; self.timingEstimated = timingEstimated
    }
}
