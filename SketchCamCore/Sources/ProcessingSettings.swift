import Foundation

public enum PreviewMode: String, CaseIterable, Identifiable, Sendable {
    case processed
    case original
    case split

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .processed: return "Processed"
        case .original: return "Original"
        case .split: return "Split"
        }
    }
}

/// Resolution the effect chain runs at, independent of the published output
/// format: the chain renders at this height and a single upscale happens at
/// the end. Filter cost scales with area, so 540p is ~4x cheaper than 1080p.
public enum ProcessingQuality: String, CaseIterable, Identifiable, Sendable {
    case full
    case balanced
    case fast

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .full: return "Full"
        case .balanced: return "720p"
        case .fast: return "540p"
        }
    }

    /// Maximum processing height; nil = process at output resolution.
    public var maxHeight: Int? {
        switch self {
        case .full: return nil
        case .balanced: return 720
        case .fast: return 540
        }
    }
}

public struct ProcessingSettings: Equatable, Sendable {
    public var threshold: Float
    public var edgeStrength: Float
    public var invert: Bool
    public var mirror: Bool
    public var testPatternMode: Bool
    public var previewMode: PreviewMode

    // Stage bypasses — each must be genuinely zero-cost when off.
    /// Master effect bypass: when false the camera frame is aspect-filled to
    /// the output format and published untouched (no filters, no kernels).
    public var effectsEnabled: Bool
    public var thresholdEnabled: Bool
    public var outlineEnabled: Bool
    /// When false, no preview readback happens at all; publishing continues.
    public var previewEnabled: Bool
    public var processingQuality: ProcessingQuality

    public init(
        threshold: Float = 0.52,
        edgeStrength: Float = 0.25,
        invert: Bool = false,
        mirror: Bool = true,
        testPatternMode: Bool = false,
        previewMode: PreviewMode = .processed,
        effectsEnabled: Bool = true,
        thresholdEnabled: Bool = true,
        outlineEnabled: Bool = true,
        previewEnabled: Bool = true,
        processingQuality: ProcessingQuality = .full
    ) {
        self.threshold = threshold
        self.edgeStrength = edgeStrength
        self.invert = invert
        self.mirror = mirror
        self.testPatternMode = testPatternMode
        self.previewMode = previewMode
        self.effectsEnabled = effectsEnabled
        self.thresholdEnabled = thresholdEnabled
        self.outlineEnabled = outlineEnabled
        self.previewEnabled = previewEnabled
        self.processingQuality = processingQuality
    }
}
