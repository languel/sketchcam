import CoreGraphics
import Foundation

enum LandmarkRegion: String, CaseIterable {
    case face
    case body
    case hands
    case eyes
    case contour

    var displayName: String {
        switch self {
        case .face: return "Face"
        case .body: return "Body"
        case .hands: return "Hands"
        case .eyes: return "Eyes"
        case .contour: return "Contour"
        }
    }
}

struct LandmarkPoint {
    var point: CGPoint
    var confidence: Float
    /// Stable identifier for debugging/annotation (e.g. "L4" = MediaPipe
    /// left-hand thumb tip, "Lelb" = left elbow, "c5" = face contour 5).
    var label: String?

    init(point: CGPoint, confidence: Float, label: String? = nil) {
        self.point = point
        self.confidence = confidence
        self.label = label
    }
}

struct LandmarkGroup {
    var region: LandmarkRegion
    var points: [LandmarkPoint]
    /// Structural connections (indices into `points`) for skeleton-style
    /// rendering: face outline, eye shapes, finger chains, body skeleton.
    var edges: [(Int, Int)]

    init(region: LandmarkRegion, points: [LandmarkPoint], edges: [(Int, Int)] = []) {
        self.region = region
        self.points = points
        self.edges = edges
    }
}

/// One detection result: the groups plus a monotonically increasing id the
/// overlay compositor uses to know when its cached layer is stale.
struct LandmarkDetection {
    var groups: [LandmarkGroup]
    var detectionID: UInt64
    /// Pixel size of the frame the normalized coordinates refer to.
    var sourceSize: CGSize
}

import SketchCamCore

extension LandmarkSettings {
    func style(for region: LandmarkRegion) -> ElementStyle {
        switch region {
        case .face: return faceStyle
        case .body: return bodyStyle
        case .hands: return handsStyle
        case .eyes: return eyesStyle
        case .contour: return contourStyle
        }
    }
}
