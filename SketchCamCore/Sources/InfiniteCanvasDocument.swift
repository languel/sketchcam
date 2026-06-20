import CoreGraphics
import Foundation

// MARK: - World and camera

/// An unbounded, isotropic scene plane. One world unit is the height of the
/// initial camera frame; the width follows the frame's aspect ratio.
public struct CanvasCamera: Codable, Equatable, Sendable {
    public var center: CGPoint
    public var viewHeight: CGFloat
    public var rotation: CGFloat
    public var guardFraction: CGFloat

    public init(
        center: CGPoint = .zero,
        viewHeight: CGFloat = 1,
        rotation: CGFloat = 0,
        guardFraction: CGFloat = 0.05
    ) {
        self.center = center
        self.viewHeight = max(0.000_001, viewHeight)
        self.rotation = rotation
        self.guardFraction = max(0, guardFraction)
    }

    public func viewSize(aspect: CGFloat) -> CGSize {
        CGSize(width: viewHeight * max(0.000_001, aspect), height: viewHeight)
    }

    /// Axis-aligned world bounds of the rotated camera frame.
    public func worldBounds(aspect: CGFloat, includeGuard: Bool = false) -> CGRect {
        let size = viewSize(aspect: aspect)
        let c = abs(cos(rotation))
        let s = abs(sin(rotation))
        var width = size.width * c + size.height * s
        var height = size.width * s + size.height * c
        if includeGuard {
            width += size.width * guardFraction * 2
            height += size.height * guardFraction * 2
        }
        return CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
    }

    public func worldPoint(fromViewportUV uv: CGPoint, aspect: CGFloat) -> CGPoint {
        let size = viewSize(aspect: aspect)
        let local = CGPoint(x: (uv.x - 0.5) * size.width, y: (uv.y - 0.5) * size.height)
        let c = cos(rotation), s = sin(rotation)
        return CGPoint(x: center.x + local.x * c - local.y * s,
                       y: center.y + local.x * s + local.y * c)
    }

    public func viewportUV(fromWorldPoint point: CGPoint, aspect: CGFloat) -> CGPoint {
        let size = viewSize(aspect: aspect)
        let dx = point.x - center.x, dy = point.y - center.y
        let c = cos(rotation), s = sin(rotation)
        let local = CGPoint(x: dx * c + dy * s, y: -dx * s + dy * c)
        return CGPoint(x: local.x / size.width + 0.5, y: local.y / size.height + 0.5)
    }

    /// The camera frame enlarged by its guard band. The returned camera is the
    /// bounded simulation domain; its own guard is zero because the expansion
    /// has already been applied.
    public func simulationDomain() -> CanvasCamera {
        CanvasCamera(center: center,
                     viewHeight: viewHeight * (1 + 2 * guardFraction),
                     rotation: rotation,
                     guardFraction: 0)
    }

    /// True when every corner of `camera` is still inside this camera's frame.
    /// Testing in viewport space makes this work for rotated cameras as well as
    /// ordinary axis-aligned pans and zooms.
    public func containsViewport(_ camera: CanvasCamera, aspect: CGFloat, tolerance: CGFloat = 0.000_001) -> Bool {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                       CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)]
        return corners.allSatisfy { corner in
            let world = camera.worldPoint(fromViewportUV: corner, aspect: aspect)
            let uv = viewportUV(fromWorldPoint: world, aspect: aspect)
            return uv.x >= -tolerance && uv.x <= 1 + tolerance &&
                   uv.y >= -tolerance && uv.y <= 1 + tolerance
        }
    }
}

public enum SceneCoordinateSpace: String, Codable, CaseIterable, Sendable {
    case world
    case viewport
}

public struct SceneTransform: Codable, Equatable, Sendable {
    public var position: CGPoint
    public var scale: CGSize
    public var rotation: CGFloat

    public init(position: CGPoint = .zero, scale: CGSize = CGSize(width: 1, height: 1), rotation: CGFloat = 0) {
        self.position = position
        self.scale = scale
        self.rotation = rotation
    }
}

// MARK: - Timed editable gestures

public struct GestureSample: Codable, Equatable, Sendable {
    public var position: CGPoint
    /// Seconds relative to the gesture clip's start.
    public var time: TimeInterval
    public var pressure: Float
    public var tilt: CGPoint
    public var modifiers: UInt32

    public init(position: CGPoint, time: TimeInterval, pressure: Float = 1, tilt: CGPoint = .zero, modifiers: UInt32 = 0) {
        self.position = position
        self.time = max(0, time)
        self.pressure = pressure
        self.tilt = tilt
        self.modifiers = modifiers
    }
}

public enum CurveAnchorKind: String, Codable, CaseIterable, Sendable {
    case corner
    case smooth
    case symmetric
}

/// Tangents are offsets from `position`, which makes transforms and SVG
/// conversion straightforward.
public struct CurveAnchor: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var position: CGPoint
    public var tangentIn: CGPoint
    public var tangentOut: CGPoint
    public var kind: CurveAnchorKind

    public init(id: UUID = UUID(), position: CGPoint, tangentIn: CGPoint = .zero, tangentOut: CGPoint = .zero, kind: CurveAnchorKind = .corner) {
        self.id = id
        self.position = position
        self.tangentIn = tangentIn
        self.tangentOut = tangentOut
        self.kind = kind
    }
}

public enum CurveFitRecipe: String, Codable, CaseIterable, Sendable {
    case polyline
    case catmullRom
    case hobby
    case bezier

    public init(_ legacy: CurveFit) {
        switch legacy {
        case .polyline: self = .polyline
        case .catmull: self = .catmullRom
        case .hobby: self = .hobby
        case .bezier: self = .bezier
        }
    }
}

public struct EditableCurve: Codable, Equatable, Sendable {
    public var anchors: [CurveAnchor]
    public var closed: Bool
    public var fitRecipe: CurveFitRecipe
    public var hasCustomGeometry: Bool

    public init(anchors: [CurveAnchor], closed: Bool = false, fitRecipe: CurveFitRecipe = .hobby, hasCustomGeometry: Bool = false) {
        self.anchors = anchors
        self.closed = closed
        self.fitRecipe = fitRecipe
        self.hasCustomGeometry = hasCustomGeometry
    }
}

public struct StrokeProfile: Codable, Equatable, Sendable {
    public var size: Float
    public var thinning: Float
    public var smoothing: Float
    public var streamline: Float
    public var startTaper: Float
    public var endTaper: Float

    public init(size: Float = 1, thinning: Float = 0.5, smoothing: Float = 0.5, streamline: Float = 0.5, startTaper: Float = 0, endTaper: Float = 0) {
        self.size = size
        self.thinning = thinning
        self.smoothing = smoothing
        self.streamline = streamline
        self.startTaper = startTaper
        self.endTaper = endTaper
    }
}

public enum MaterialGestureKind: String, Codable, CaseIterable, Sendable {
    case pen
    case wash
    case rewet
    case fix
}

public struct GestureClip: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var startTime: TimeInterval
    public var duration: TimeInterval
    public var samples: [GestureSample]
    public var curve: EditableCurve
    public var strokeProfile: StrokeProfile
    /// Camera height when the brush was recorded. Brush sliders are expressed
    /// relative to the viewport, so this preserves their physical world width
    /// when the camera later zooms. Older projects use the initial height 1.
    public var recordedViewHeight: CGFloat?
    public var kind: MaterialGestureKind
    public var color: RGBAColor
    public var flow: Float
    public var bleed: Float
    public var dry: Float
    public var brushInk: Float
    public var timingEstimated: Bool
    public var muted: Bool

    public init(
        id: UUID = UUID(), name: String = "Gesture", startTime: TimeInterval = 0,
        duration: TimeInterval, samples: [GestureSample], curve: EditableCurve,
        strokeProfile: StrokeProfile = StrokeProfile(), recordedViewHeight: CGFloat? = nil,
        kind: MaterialGestureKind = .pen,
        color: RGBAColor = .ink, flow: Float = 1, bleed: Float = 0.8,
        dry: Float = 0.25, brushInk: Float = 0, timingEstimated: Bool = false,
        muted: Bool = false
    ) {
        self.id = id
        self.name = name
        self.startTime = max(0, startTime)
        self.duration = max(0, duration)
        self.samples = samples
        self.curve = curve
        self.strokeProfile = strokeProfile
        self.recordedViewHeight = recordedViewHeight
        self.kind = kind
        self.color = color
        self.flow = flow
        self.bleed = bleed
        self.dry = dry
        self.brushInk = brushInk
        self.timingEstimated = timingEstimated
        self.muted = muted
    }

    /// Brush size expected by the viewport-normalized ink engine for this
    /// gesture at the supplied camera zoom.
    public func viewportBrushSize(camera: CanvasCamera) -> Float {
        strokeProfile.size * Float((recordedViewHeight ?? 1) / max(0.000_001, camera.viewHeight))
    }
}

// MARK: - Camera and automation timeline

public enum TimelineInterpolation: String, Codable, CaseIterable, Sendable {
    case hold
    case linear
    case smooth
    case cubic
}

public enum AutomationValue: Codable, Equatable, Sendable {
    case scalar(Double)
    case point(CGPoint)
    case color(RGBAColor)
    case boolean(Bool)
    case text(String)
}

public struct ParameterAddress: Codable, Equatable, Hashable, Sendable {
    public var ownerID: UUID
    public var component: String
    public var parameter: String

    public init(ownerID: UUID, component: String, parameter: String) {
        self.ownerID = ownerID
        self.component = component
        self.parameter = parameter
    }
}

public struct AutomationKeyframe: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var time: TimeInterval
    public var value: AutomationValue
    public var interpolation: TimelineInterpolation

    public init(id: UUID = UUID(), time: TimeInterval, value: AutomationValue, interpolation: TimelineInterpolation = .smooth) {
        self.id = id
        self.time = max(0, time)
        self.value = value
        self.interpolation = interpolation
    }
}

public struct AutomationTrack: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var address: ParameterAddress
    public var keyframes: [AutomationKeyframe]
    public var armed: Bool
    public var muted: Bool
    public var solo: Bool

    public init(id: UUID = UUID(), name: String, address: ParameterAddress, keyframes: [AutomationKeyframe] = [], armed: Bool = false, muted: Bool = false, solo: Bool = false) {
        self.id = id
        self.name = name
        self.address = address
        self.keyframes = keyframes
        self.armed = armed
        self.muted = muted
        self.solo = solo
    }
}

public struct CameraKeyframe: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var time: TimeInterval
    public var camera: CanvasCamera
    public var interpolation: TimelineInterpolation

    public init(id: UUID = UUID(), time: TimeInterval, camera: CanvasCamera, interpolation: TimelineInterpolation = .smooth) {
        self.id = id
        self.time = max(0, time)
        self.camera = camera
        self.interpolation = interpolation
    }
}

public struct CameraTrack: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var keyframes: [CameraKeyframe]
    public var armed: Bool
    public var muted: Bool

    public init(id: UUID = UUID(), name: String = "Camera", keyframes: [CameraKeyframe] = [], armed: Bool = false, muted: Bool = false) {
        self.id = id
        self.name = name
        self.keyframes = keyframes
        self.armed = armed
        self.muted = muted
    }
}

// MARK: - Scene and artifact manifest

public enum SceneObjectPayload: Codable, Equatable, Sendable {
    case gesture(UUID)
    case layer(UUID)
    case vector(EditableCurve)
    case referenceAsset(String)
}

public struct SceneObject: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var coordinateSpace: SceneCoordinateSpace
    public var transform: SceneTransform
    public var payload: SceneObjectPayload

    public init(id: UUID = UUID(), name: String, coordinateSpace: SceneCoordinateSpace = .world, transform: SceneTransform = SceneTransform(), payload: SceneObjectPayload) {
        self.id = id
        self.name = name
        self.coordinateSpace = coordinateSpace
        self.transform = transform
        self.payload = payload
    }
}

public struct ArtifactTileReference: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var level: Int
    public var x: Int
    public var y: Int
    public var relativePath: String
    public var pixelSize: Int

    public var id: String { "\(level):\(x):\(y)" }

    public init(level: Int, x: Int, y: Int, relativePath: String, pixelSize: Int = 512) {
        self.level = level
        self.x = x
        self.y = y
        self.relativePath = relativePath
        self.pixelSize = pixelSize
    }
}

public enum FrameMaterialCommand: String, Codable, Sendable { case fix, unfix, wet, dry }

public struct FrameMaterialEvent: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var time: TimeInterval
    public var command: FrameMaterialCommand
    public var worldRegion: CGRect
    public init(id: UUID = UUID(), time: TimeInterval, command: FrameMaterialCommand, worldRegion: CGRect) {
        self.id = id; self.time = time; self.command = command; self.worldRegion = worldRegion
    }
}

public struct TimelineState: Codable, Equatable, Sendable {
    public var playhead: TimeInterval
    public var duration: TimeInterval
    public var loopStart: TimeInterval
    public var loopEnd: TimeInterval
    public var masterRecordEnabled: Bool
    public var framesPerSecond: Double

    public init(playhead: TimeInterval = 0, duration: TimeInterval = 10, loopStart: TimeInterval = 0, loopEnd: TimeInterval = 10, masterRecordEnabled: Bool = false, framesPerSecond: Double = 30) {
        self.playhead = playhead
        self.duration = duration
        self.loopStart = loopStart
        self.loopEnd = loopEnd
        self.masterRecordEnabled = masterRecordEnabled
        self.framesPerSecond = framesPerSecond
    }
}

public struct SketchProjectManifest: Codable, Equatable, Sendable {
    public static let currentVersion = 2

    public var version: Int
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var modifiedAt: Date
    public var camera: CanvasCamera
    public var sceneObjects: [SceneObject]
    public var gestures: [GestureClip]
    public var cameraTracks: [CameraTrack]
    public var automationTracks: [AutomationTrack]
    public var artifactTiles: [ArtifactTileReference]
    public var materialEvents: [FrameMaterialEvent]
    public var timeline: TimelineState

    public init(
        version: Int = currentVersion, id: UUID = UUID(), title: String = "Untitled",
        createdAt: Date = Date(), modifiedAt: Date = Date(), camera: CanvasCamera = CanvasCamera(),
        sceneObjects: [SceneObject] = [], gestures: [GestureClip] = [],
        cameraTracks: [CameraTrack] = [CameraTrack()], automationTracks: [AutomationTrack] = [],
        artifactTiles: [ArtifactTileReference] = [], materialEvents: [FrameMaterialEvent] = [], timeline: TimelineState = TimelineState()
    ) {
        self.version = version
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.camera = camera
        self.sceneObjects = sceneObjects
        self.gestures = gestures
        self.cameraTracks = cameraTracks
        self.automationTracks = automationTracks
        self.artifactTiles = artifactTiles
        self.materialEvents = materialEvents
        self.timeline = timeline
    }

    private enum CodingKeys: String, CodingKey { case version, id, title, createdAt, modifiedAt, camera, sceneObjects, gestures, cameraTracks, automationTracks, artifactTiles, materialEvents, timeline }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled"
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        modifiedAt = try c.decodeIfPresent(Date.self, forKey: .modifiedAt) ?? createdAt
        camera = try c.decodeIfPresent(CanvasCamera.self, forKey: .camera) ?? CanvasCamera()
        sceneObjects = try c.decodeIfPresent([SceneObject].self, forKey: .sceneObjects) ?? []
        gestures = try c.decodeIfPresent([GestureClip].self, forKey: .gestures) ?? []
        cameraTracks = try c.decodeIfPresent([CameraTrack].self, forKey: .cameraTracks) ?? [CameraTrack()]
        automationTracks = try c.decodeIfPresent([AutomationTrack].self, forKey: .automationTracks) ?? []
        artifactTiles = try c.decodeIfPresent([ArtifactTileReference].self, forKey: .artifactTiles) ?? []
        materialEvents = try c.decodeIfPresent([FrameMaterialEvent].self, forKey: .materialEvents) ?? []
        timeline = try c.decodeIfPresent(TimelineState.self, forKey: .timeline) ?? TimelineState()
    }
}

// MARK: - Legacy migration

public extension GestureClip {
    /// Migrates frame-normalized legacy paths into isotropic world space.
    /// Timing did not exist in the old model, so the duration is estimated from
    /// arc length at half a viewport-height per second.
    init(legacy path: InkEditorPath, aspect: CGFloat, startTime: TimeInterval = 0, fit: CurveFit = .hobby) {
        let worldPoints = path.points.map {
            CGPoint(x: ($0.x - 0.5) * aspect, y: $0.y - 0.5)
        }
        let length = zip(worldPoints, worldPoints.dropFirst()).reduce(CGFloat.zero) { partial, pair in
            partial + hypot(pair.1.x - pair.0.x, pair.1.y - pair.0.y)
        }
        let duration = max(0.1, TimeInterval(length / 0.5))
        var travelled: CGFloat = 0
        var samples: [GestureSample] = []
        for (index, point) in worldPoints.enumerated() {
            if index > 0 {
                travelled += hypot(point.x - worldPoints[index - 1].x, point.y - worldPoints[index - 1].y)
            }
            let time = length > 0 ? duration * TimeInterval(travelled / length) : 0
            samples.append(GestureSample(position: point, time: time))
        }
        let anchors = worldPoints.map { CurveAnchor(position: $0) }
        let mode = path.brushMode ?? .pen
        self.init(
            id: path.id,
            name: mode == .brush ? "Wash" : "Pen",
            startTime: startTime,
            duration: duration,
            samples: samples,
            curve: EditableCurve(anchors: anchors, fitRecipe: CurveFitRecipe(fit)),
            strokeProfile: StrokeProfile(size: path.width ?? 0.5),
            recordedViewHeight: 1,
            kind: mode == .brush ? .wash : .pen,
            color: path.color ?? .ink,
            flow: path.flow ?? 1,
            bleed: path.bleed ?? 0.8,
            dry: path.dry ?? 0.25,
            brushInk: path.brushInk ?? 0,
            timingEstimated: true
        )
    }
}
