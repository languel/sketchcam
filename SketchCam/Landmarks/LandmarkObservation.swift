import CoreGraphics
import Foundation

enum LandmarkRegion: String, CaseIterable {
    case face
    case body
    case hands
    case eyes

    var displayName: String {
        switch self {
        case .face: return "Face"
        case .body: return "Body"
        case .hands: return "Hands"
        case .eyes: return "Eyes"
        }
    }
}

struct LandmarkPoint {
    var point: CGPoint
    var confidence: Float
}

struct LandmarkGroup {
    var region: LandmarkRegion
    var points: [LandmarkPoint]
}

/// One detection result: the groups plus a monotonically increasing id the
/// overlay compositor uses to know when its cached layer is stale.
struct LandmarkDetection {
    var groups: [LandmarkGroup]
    var detectionID: UInt64
    /// Pixel size of the frame the normalized coordinates refer to.
    var sourceSize: CGSize
}
