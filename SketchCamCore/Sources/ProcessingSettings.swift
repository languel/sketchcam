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

/// How a path's sampled points become a drawn curve. A rich area to grow
/// alongside future brush-stroke styles.
public enum CurveFit: String, CaseIterable, Identifiable, Sendable, Codable {
    case polyline
    case catmull
    case hobby
    case bezier

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .polyline: return "Polyline"
        case .catmull: return "Spline"
        case .hobby: return "Hobby"
        case .bezier: return "Bezier"
        }
    }
}

/// Shared, user-editable color set for the Drawing algorithms. Starts as a
/// single solid color; algorithms cycle through the colors (e.g. per feature)
/// when more are added.
public struct DrawingPalette: Equatable, Sendable, Codable {
    public var colors: [RGBAColor]

    public init(colors: [RGBAColor]) {
        self.colors = colors.isEmpty ? [.ink] : colors
    }

    /// First color, guaranteed present (the solid-color default).
    public var primary: RGBAColor { colors.first ?? .ink }

    public static let `default` = DrawingPalette(colors: [.ink])
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
    /// Preview/display refresh cap in fps. 0 = full-tilt (every published
    /// frame). The preview pane doubles as the main display (presentation
    /// mode), so this is a real output rate, not a throttle-to-save-cost.
    public var previewFPS: Double
    /// Display the preview via a zero-readback Metal layer (AVSampleBufferDisplayLayer)
    /// instead of a per-frame CGImage readback. The "full-tilt" display path.
    public var useMetalPreview: Bool
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
        previewFPS: Double = 0,
        useMetalPreview: Bool = false,
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
        self.previewFPS = previewFPS
        self.useMetalPreview = useMetalPreview
        self.processingQuality = processingQuality
        self.landmarks = landmarks
    }
}

public enum LandmarkSourceMode: String, CaseIterable, Identifiable, Sendable, Codable {
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

/// Generic visual style for a significant element: one color (with opacity)
/// and one size whose meaning is contextual — stroke width for lines/yarn,
/// dot scale for points. One UI control (StyleRow) edits any of these.
public struct ElementStyle: Equatable, Sendable, Codable {
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
public struct LandmarkSettings: Equatable, Sendable, Codable {
    public var enabled: Bool
    public var sourceMode: LandmarkSourceMode
    /// Raw-data renderers (Marks tab) — any combination can be on.
    public var showDots: Bool
    public var showStick: Bool
    /// Art algorithms (Drawing tab) — each toggles independently and they
    /// layer on top of each other (back-to-front in this order).
    public var yarnEnabled: Bool
    public var wrapEnabled: Bool
    public var lineWalkEnabled: Bool
    /// Per-renderer size multipliers on top of each region's style.size.
    public var dotScale: Float
    public var stickScale: Float
    // Face subparts — each independently toggleable.
    public var trackJaw: Bool
    public var trackNose: Bool
    public var trackMouth: Bool
    public var trackLeftBrow: Bool
    public var trackRightBrow: Bool
    public var trackLeftEye: Bool
    public var trackRightEye: Bool
    // Body subparts — each independently toggleable.
    public var trackHead: Bool
    public var trackTorso: Bool
    public var trackLeftArm: Bool
    public var trackRightArm: Bool
    public var trackLeftLeg: Bool
    public var trackRightLeg: Bool
    public var trackHands: Bool
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
    /// Trace the person-segmentation matte into a ring of contour points
    /// (stable IDs s0.., s0 = top of head) following the silhouette boundary.
    public var trackContour: Bool
    /// Contour granularity: 0 = coarse (few points, loose) → 1 = fine (many
    /// points, hugs the silhouette including concavities).
    public var contourDetail: Float
    /// Seg-free person outline: convex hull of the landmarks (no segmentation
    /// cost). Independent of `trackContour`; both can be on.
    public var trackBodyHull: Bool
    /// Predict landmark motion between detections and re-render the overlay
    /// every frame, so the drawing tracks at frame rate (not the slower
    /// detection cadence) and lags the body less. Off = render at detection
    /// cadence (the old stepping behavior).
    public var predictiveTracking: Bool
    /// Seeds the PRNG behind the drawing algorithms; a fixed seed keeps the
    /// generated shape stable while the subject moves. One seed per algorithm
    /// (each tab is fully independent).
    public var yarnSeed: Int
    public var wrapSeed: Int
    public var lineWalkSeed: Int
    // Yarn parameters (per-region weave).
    public var subsetRatio: Float
    public var yarnWeaveAmount: Float
    public var yarnWidth: Float
    /// Path noise (analogue of LineWalk's wildness): `linear` = perpendicular
    /// zigzag; `circular` = coils/loops; `winding` = loops per segment (>1 =
    /// local tangles).
    public var yarnLinear: Float
    public var yarnCircular: Float
    public var yarnWinding: Float
    /// Ribbon width variation (calligraphic taper/swell) + optional glow halo.
    public var yarnWidthVariation: Float
    public var yarnHalo: Bool
    // Wrap parameters (yarn-wire that winds through the body interior). Mirrors
    // LineWalk's path-variation controls, plus the coil/winding loops.
    /// Interior anchor count: sparse (bent-wire) → dense (woven mat).
    public var wrapDensity: Float
    /// LineWalk-style geometric wildness (the XY pad): along the path tangent
    /// (bunching) and orthogonal to it (waviness / zigzag).
    public var wrapWildnessAlong: Float
    public var wrapWildnessOrtho: Float
    /// Wildness frequency: local (high-frequency) → global (low-frequency).
    public var wrapScale: Float
    /// Coil/loop noise: `circular` = loop amplitude, `winding` = loops/segment.
    public var wrapCircular: Float
    public var wrapWinding: Float
    public var wrapWidth: Float
    public var wrapCurveFit: CurveFit
    /// Ribbon width variation + optional glow halo.
    public var wrapWidthVariation: Float
    public var wrapHalo: Bool
    // LineWalk parameters.
    /// Point sampling: minimal (few points) → dense (every point, subdivided).
    public var lineWalkDensity: Float
    /// Number of paths the data is fit with: 1 = one continuous line
    /// (unicursal) → 0 = many disjoint paths / fragmented segments.
    public var lineWalkContinuity: Float
    /// Geometric wildness, decomposed (the XY pad): displacement along the path
    /// tangent (bunching) and orthogonal to it (waviness / zigzag).
    public var lineWalkWildnessAlong: Float
    public var lineWalkWildnessOrtho: Float
    /// Wildness frequency: local (high-frequency, per sub-stroke) → global
    /// (low-frequency, whole-line drift).
    public var lineWalkScale: Float
    public var lineWalkWidth: Float
    /// Width variation along the curve (calligraphic taper / swell amount).
    public var lineWalkWidthVariation: Float
    public var lineWalkCurveFit: CurveFit
    /// Optional glow halo behind the ribbon.
    public var lineWalkHalo: Bool
    /// Render LineWalk strokes on the GPU (Metal) instead of the CPU CGContext
    /// path. Experimental opt-in for the Metal overhaul A/B.
    public var useMetalDrawing: Bool
    /// Legacy bead stroke (per-segment quads + round discs). Off = smooth filled
    /// ribbons (clean under transparency).
    public var beadStroke: Bool
    /// Per-algorithm color set. When the matching `*MatchesLandmarkColors` flag
    /// is set, that algorithm instead tints by each region's landmark color.
    public var yarnPalette: DrawingPalette
    public var yarnMatchesLandmarkColors: Bool
    public var wrapPalette: DrawingPalette
    public var wrapMatchesLandmarkColors: Bool
    public var lineWalkPalette: DrawingPalette
    public var lineWalkMatchesLandmarkColors: Bool
    /// Per-region color + size (stroke width / dot scale).
    public var jawStyle: ElementStyle
    public var noseStyle: ElementStyle
    public var mouthStyle: ElementStyle
    public var leftBrowStyle: ElementStyle
    public var rightBrowStyle: ElementStyle
    public var leftEyeStyle: ElementStyle
    public var rightEyeStyle: ElementStyle
    public var headStyle: ElementStyle
    public var torsoStyle: ElementStyle
    public var leftArmStyle: ElementStyle
    public var rightArmStyle: ElementStyle
    public var leftLegStyle: ElementStyle
    public var rightLegStyle: ElementStyle
    public var handsStyle: ElementStyle
    public var contourStyle: ElementStyle
    public var bodyHullStyle: ElementStyle

    public init(
        enabled: Bool = false,
        sourceMode: LandmarkSourceMode = .camera,
        showDots: Bool = false,
        showStick: Bool = false,
        yarnEnabled: Bool = true,
        wrapEnabled: Bool = false,
        lineWalkEnabled: Bool = false,
        dotScale: Float = 1,
        stickScale: Float = 1,
        trackJaw: Bool = true,
        trackNose: Bool = true,
        trackMouth: Bool = true,
        trackLeftBrow: Bool = true,
        trackRightBrow: Bool = true,
        trackLeftEye: Bool = true,
        trackRightEye: Bool = true,
        trackHead: Bool = false,
        trackTorso: Bool = true,
        trackLeftArm: Bool = true,
        trackRightArm: Bool = true,
        trackLeftLeg: Bool = true,
        trackRightLeg: Bool = true,
        trackHands: Bool = true,
        detectionsPerSecond: Double = 10,
        detectionMaxDimension: Int = 384,
        showIDs: Bool = false,
        labelSize: Float = 11,
        labelsMatchColor: Bool = true,
        trackContour: Bool = false,
        contourDetail: Float = 0.4,
        trackBodyHull: Bool = false,
        predictiveTracking: Bool = true,
        yarnSeed: Int = 7,
        wrapSeed: Int = 7,
        lineWalkSeed: Int = 7,
        subsetRatio: Float = 0.65,
        yarnWeaveAmount: Float = 0.7,
        yarnWidth: Float = 2.2,
        yarnLinear: Float = 0,
        yarnCircular: Float = 0,
        yarnWinding: Float = 1,
        yarnWidthVariation: Float = 0.35,
        yarnHalo: Bool = false,
        wrapDensity: Float = 0.6,
        wrapWildnessAlong: Float = 0.15,
        wrapWildnessOrtho: Float = 0.25,
        wrapScale: Float = 0.5,
        wrapCircular: Float = 0,
        wrapWinding: Float = 1,
        wrapWidth: Float = 2.2,
        wrapCurveFit: CurveFit = .hobby,
        wrapWidthVariation: Float = 0.35,
        wrapHalo: Bool = false,
        lineWalkDensity: Float = 0.5,
        lineWalkContinuity: Float = 1,
        lineWalkWildnessAlong: Float = 0.2,
        lineWalkWildnessOrtho: Float = 0.3,
        lineWalkScale: Float = 0.5,
        lineWalkWidth: Float = 2,
        lineWalkWidthVariation: Float = 0.3,
        lineWalkCurveFit: CurveFit = .hobby,
        lineWalkHalo: Bool = false,
        useMetalDrawing: Bool = false,
        beadStroke: Bool = false,
        yarnPalette: DrawingPalette = .default,
        yarnMatchesLandmarkColors: Bool = false,
        wrapPalette: DrawingPalette = .default,
        wrapMatchesLandmarkColors: Bool = false,
        lineWalkPalette: DrawingPalette = .default,
        lineWalkMatchesLandmarkColors: Bool = false,
        jawStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.95, green: 0.33, blue: 0.48, alpha: 0.85)),
        noseStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.90, green: 0.45, blue: 0.55, alpha: 0.85)),
        mouthStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.92, green: 0.30, blue: 0.42, alpha: 0.85)),
        leftBrowStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.80, green: 0.40, blue: 0.70, alpha: 0.85)),
        rightBrowStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.70, green: 0.45, blue: 0.82, alpha: 0.85)),
        leftEyeStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.42, green: 0.68, blue: 1.0, alpha: 0.85)),
        rightEyeStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.50, green: 0.60, blue: 0.95, alpha: 0.85)),
        headStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.23, green: 0.78, blue: 0.64, alpha: 0.85)),
        torsoStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.20, green: 0.70, blue: 0.72, alpha: 0.85)),
        leftArmStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.30, green: 0.76, blue: 0.55, alpha: 0.85)),
        rightArmStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.40, green: 0.80, blue: 0.50, alpha: 0.85)),
        leftLegStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.22, green: 0.64, blue: 0.78, alpha: 0.85)),
        rightLegStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.30, green: 0.58, blue: 0.82, alpha: 0.85)),
        handsStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.98, green: 0.78, blue: 0.28, alpha: 0.85)),
        contourStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.92, green: 0.92, blue: 0.95, alpha: 0.85)),
        bodyHullStyle: ElementStyle = ElementStyle(color: RGBAColor(red: 0.55, green: 0.9, blue: 0.95, alpha: 0.85))
    ) {
        self.enabled = enabled
        self.sourceMode = sourceMode
        self.showDots = showDots
        self.showStick = showStick
        self.yarnEnabled = yarnEnabled
        self.wrapEnabled = wrapEnabled
        self.lineWalkEnabled = lineWalkEnabled
        self.dotScale = dotScale
        self.stickScale = stickScale
        self.trackJaw = trackJaw
        self.trackNose = trackNose
        self.trackMouth = trackMouth
        self.trackLeftBrow = trackLeftBrow
        self.trackRightBrow = trackRightBrow
        self.trackLeftEye = trackLeftEye
        self.trackRightEye = trackRightEye
        self.trackHead = trackHead
        self.trackTorso = trackTorso
        self.trackLeftArm = trackLeftArm
        self.trackRightArm = trackRightArm
        self.trackLeftLeg = trackLeftLeg
        self.trackRightLeg = trackRightLeg
        self.trackHands = trackHands
        self.detectionsPerSecond = detectionsPerSecond
        self.detectionMaxDimension = detectionMaxDimension
        self.showIDs = showIDs
        self.labelSize = labelSize
        self.labelsMatchColor = labelsMatchColor
        self.trackContour = trackContour
        self.contourDetail = contourDetail
        self.trackBodyHull = trackBodyHull
        self.predictiveTracking = predictiveTracking
        self.yarnSeed = yarnSeed
        self.wrapSeed = wrapSeed
        self.lineWalkSeed = lineWalkSeed
        self.subsetRatio = subsetRatio
        self.yarnWeaveAmount = yarnWeaveAmount
        self.yarnWidth = yarnWidth
        self.yarnLinear = yarnLinear
        self.yarnCircular = yarnCircular
        self.yarnWinding = yarnWinding
        self.yarnWidthVariation = yarnWidthVariation
        self.yarnHalo = yarnHalo
        self.wrapDensity = wrapDensity
        self.wrapWildnessAlong = wrapWildnessAlong
        self.wrapWildnessOrtho = wrapWildnessOrtho
        self.wrapScale = wrapScale
        self.wrapCircular = wrapCircular
        self.wrapWinding = wrapWinding
        self.wrapWidth = wrapWidth
        self.wrapCurveFit = wrapCurveFit
        self.wrapWidthVariation = wrapWidthVariation
        self.wrapHalo = wrapHalo
        self.lineWalkDensity = lineWalkDensity
        self.lineWalkContinuity = lineWalkContinuity
        self.lineWalkWildnessAlong = lineWalkWildnessAlong
        self.lineWalkWildnessOrtho = lineWalkWildnessOrtho
        self.lineWalkScale = lineWalkScale
        self.lineWalkWidth = lineWalkWidth
        self.lineWalkWidthVariation = lineWalkWidthVariation
        self.lineWalkCurveFit = lineWalkCurveFit
        self.lineWalkHalo = lineWalkHalo
        self.useMetalDrawing = useMetalDrawing
        self.beadStroke = beadStroke
        self.yarnPalette = yarnPalette
        self.yarnMatchesLandmarkColors = yarnMatchesLandmarkColors
        self.wrapPalette = wrapPalette
        self.wrapMatchesLandmarkColors = wrapMatchesLandmarkColors
        self.lineWalkPalette = lineWalkPalette
        self.lineWalkMatchesLandmarkColors = lineWalkMatchesLandmarkColors
        self.jawStyle = jawStyle
        self.noseStyle = noseStyle
        self.mouthStyle = mouthStyle
        self.leftBrowStyle = leftBrowStyle
        self.rightBrowStyle = rightBrowStyle
        self.leftEyeStyle = leftEyeStyle
        self.rightEyeStyle = rightEyeStyle
        self.headStyle = headStyle
        self.torsoStyle = torsoStyle
        self.leftArmStyle = leftArmStyle
        self.rightArmStyle = rightArmStyle
        self.leftLegStyle = leftLegStyle
        self.rightLegStyle = rightLegStyle
        self.handsStyle = handsStyle
        self.contourStyle = contourStyle
        self.bodyHullStyle = bodyHullStyle
    }
}

/// Plain-value color (no AppKit dependency in Core).
public struct RGBAColor: Equatable, Sendable, Codable {
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
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let chromaGreen = RGBAColor(red: 0, green: 0.85, blue: 0.25)
    /// Default drawing ink — a near-black warm charcoal.
    public static let ink = RGBAColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 0.95)
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
