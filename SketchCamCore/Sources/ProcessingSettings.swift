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
    /// "Ink only": the threshold layer's white paper becomes transparent —
    /// black ink on alpha — so the drawing composites over any background
    /// (and survives into an Alpha-background export).
    public var thresholdInkOnly: Bool
    public var outlineEnabled: Bool
    /// Outline stroke dilation radius in pixels (at processing resolution).
    public var outlineThickness: Float
    public var outlineColor: RGBAColor
    /// When false, the video layer is not drawn — outline strokes and the
    /// landmark doodle render directly against the background, giving a
    /// clean compositing source.
    public var inputLayerEnabled: Bool
    public var backgroundMode: BackgroundMode
    public var backgroundColor: RGBAColor
    public var segmentation: SegmentationSettings
    /// When false, no preview readback happens at all; publishing continues.
    public var previewEnabled: Bool
    public var processingQuality: ProcessingQuality
    public var landmarks: LandmarkSettings

    public init(
        threshold: Float = 0.52,
        edgeStrength: Float = 0.25,
        invert: Bool = false,
        mirror: Bool = true,
        testPatternMode: Bool = false,
        previewMode: PreviewMode = .processed,
        effectsEnabled: Bool = true,
        thresholdEnabled: Bool = true,
        thresholdInkOnly: Bool = false,
        outlineEnabled: Bool = true,
        outlineThickness: Float = 1,
        outlineColor: RGBAColor = .black,
        inputLayerEnabled: Bool = true,
        backgroundMode: BackgroundMode = .live,
        backgroundColor: RGBAColor = .chromaGreen,
        segmentation: SegmentationSettings = SegmentationSettings(),
        previewEnabled: Bool = true,
        processingQuality: ProcessingQuality = .full,
        landmarks: LandmarkSettings = LandmarkSettings()
    ) {
        self.threshold = threshold
        self.edgeStrength = edgeStrength
        self.invert = invert
        self.mirror = mirror
        self.testPatternMode = testPatternMode
        self.previewMode = previewMode
        self.effectsEnabled = effectsEnabled
        self.thresholdEnabled = thresholdEnabled
        self.thresholdInkOnly = thresholdInkOnly
        self.outlineEnabled = outlineEnabled
        self.outlineThickness = outlineThickness
        self.outlineColor = outlineColor
        self.inputLayerEnabled = inputLayerEnabled
        self.backgroundMode = backgroundMode
        self.backgroundColor = backgroundColor
        self.segmentation = segmentation
        self.previewEnabled = previewEnabled
        self.processingQuality = processingQuality
        self.landmarks = landmarks
    }
}

public enum LandmarkSourceMode: String, CaseIterable, Identifiable, Sendable {
    case camera
    case synthetic

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .camera: return "Camera"
        case .synthetic: return "Synthetic"
        }
    }
}

public enum LandmarkVisualizationMode: String, CaseIterable, Identifiable, Sendable {
    case raw
    case yarn
    case rawAndYarn
    /// MediaPipe-style structural rendering: face outline, eye shapes,
    /// articulated fingers, and a body skeleton, drawn from the per-group
    /// edge lists supplied by the tracker.
    case skeleton

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .raw: return "Dots"
        case .yarn: return "Yarn"
        case .rawAndYarn: return "Both"
        case .skeleton: return "Stick"
        }
    }
}

/// Generic visual style for a significant element: one color (with opacity)
/// and one size whose meaning is contextual — stroke width for lines/yarn,
/// dot scale for points. One UI control (StyleRow) edits any of these.
public struct ElementStyle: Equatable, Sendable {
    public var color: RGBAColor
    public var size: Float

    public init(color: RGBAColor, size: Float = 2.2) {
        self.color = color
        self.size = size
    }
}

/// Landmark overlay settings. Detection runs off the frame hot path at
/// `detectionsPerSecond`; the overlay layer is re-rendered only when a
/// detection lands and is GPU-composited into every published frame.
public struct LandmarkSettings: Equatable, Sendable {
    public var enabled: Bool
    public var sourceMode: LandmarkSourceMode
    public var visualizationMode: LandmarkVisualizationMode
    public var trackFace: Bool
    public var trackBody: Bool
    public var trackHands: Bool
    public var trackEyesAndIrises: Bool
    public var detectionsPerSecond: Double
    /// Longest input dimension handed to the detector.
    public var detectionMaxDimension: Int
    /// Draw each landmark's stable identifier next to it (debugging aid —
    /// hand labels use MediaPipe indices, e.g. "L4" = left thumb tip).
    public var showIDs: Bool
    /// Label point size; labels inherit each region's style color when
    /// `labelsMatchColor` is set, white otherwise.
    public var labelSize: Float
    public var labelsMatchColor: Bool
    /// Trace the person-segmentation matte into a fixed ring of contour
    /// points (stable IDs s0..s63, s0 = top of head) around the silhouette.
    public var trackContour: Bool
    public var seed: Int
    public var subsetRatio: Float
    public var yarnWeaveAmount: Float
    /// Per-region color + size (stroke width / dot scale).
    public var faceStyle: ElementStyle
    public var bodyStyle: ElementStyle
    public var handsStyle: ElementStyle
    public var eyesStyle: ElementStyle
    public var contourStyle: ElementStyle

    public init(
        enabled: Bool = false,
        sourceMode: LandmarkSourceMode = .camera,
        visualizationMode: LandmarkVisualizationMode = .yarn,
        trackFace: Bool = true,
        trackBody: Bool = true,
        trackHands: Bool = true,
        trackEyesAndIrises: Bool = false,
        detectionsPerSecond: Double = 10,
        detectionMaxDimension: Int = 384,
        showIDs: Bool = false,
        labelSize: Float = 11,
        labelsMatchColor: Bool = true,
        trackContour: Bool = false,
        seed: Int = 7,
        subsetRatio: Float = 0.65,
        yarnWeaveAmount: Float = 0.7,
        faceStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.95, green: 0.33, blue: 0.48, alpha: 0.85)),
        bodyStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.23, green: 0.78, blue: 0.64, alpha: 0.85)),
        handsStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.98, green: 0.78, blue: 0.28, alpha: 0.85)),
        eyesStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.42, green: 0.68, blue: 1.0, alpha: 0.85)),
        contourStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.92, green: 0.92, blue: 0.95, alpha: 0.85))
    ) {
        self.enabled = enabled
        self.sourceMode = sourceMode
        self.visualizationMode = visualizationMode
        self.trackFace = trackFace
        self.trackBody = trackBody
        self.trackHands = trackHands
        self.trackEyesAndIrises = trackEyesAndIrises
        self.detectionsPerSecond = detectionsPerSecond
        self.detectionMaxDimension = detectionMaxDimension
        self.showIDs = showIDs
        self.labelSize = labelSize
        self.labelsMatchColor = labelsMatchColor
        self.trackContour = trackContour
        self.seed = seed
        self.subsetRatio = subsetRatio
        self.yarnWeaveAmount = yarnWeaveAmount
        self.faceStyle = faceStyle
        self.bodyStyle = bodyStyle
        self.handsStyle = handsStyle
        self.eyesStyle = eyesStyle
        self.contourStyle = contourStyle
    }
}

/// Plain-value color (no AppKit dependency in Core).
public struct RGBAColor: Equatable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float

    public init(red: Float, green: Float, blue: Float, alpha: Float = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let chromaGreen = RGBAColor(red: 0, green: 0.85, blue: 0.25)
}

/// What sits behind the composited layers. `solid`/`transparent` exist so the
/// doodle/effects can be exported with a keyable background (or a real alpha
/// channel) into TouchDesigner and similar tools.
public enum BackgroundMode: String, CaseIterable, Identifiable, Sendable {
    case live
    case solid
    case transparent

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .live: return "Live"
        case .solid: return "Solid"
        case .transparent: return "Alpha"
        }
    }
}

public enum SegmentationQuality: String, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case accurate

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .accurate: return "Accurate"
        }
    }
}

/// Person keying via Vision person segmentation: the foreground stack (video
/// layer + outline) is masked to the detected person and composited over the
/// background. MediaPipe selfie segmentation has no official macOS runtime;
/// Vision runs on the ANE and is the native equivalent.
/// How the person matte is used.
public enum SegmentationMode: String, CaseIterable, Identifiable, Sendable {
    /// The matte masks the consecutive layers (video/threshold/outline):
    /// they render only inside the person, background elsewhere.
    case cutout
    /// The matte itself is drawn as a flat colored silhouette (outline
    /// strokes still composite on top, masked to the person).
    case silhouette

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cutout: return "Cutout"
        case .silhouette: return "Silhouette"
        }
    }
}

public struct SegmentationSettings: Equatable, Sendable {
    public var enabled: Bool
    public var quality: SegmentationQuality
    public var mode: SegmentationMode
    /// Flip the matte: the background region keeps the layers and the
    /// person is keyed out instead.
    public var inverted: Bool
    public var silhouetteColor: RGBAColor

    public init(
        enabled: Bool = false,
        quality: SegmentationQuality = .fast,
        mode: SegmentationMode = .cutout,
        inverted: Bool = false,
        silhouetteColor: RGBAColor = .black
    ) {
        self.enabled = enabled
        self.quality = quality
        self.mode = mode
        self.inverted = inverted
        self.silhouetteColor = silhouetteColor
    }
}
