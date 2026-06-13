import CoreGraphics
import Foundation

enum LandmarkRegion: String, CaseIterable {
    // Face, split into independently toggleable / styleable subparts.
    case jaw          // face contour: chin + jawline up to the ears
    case nose
    case mouth        // outer + inner lips
    case leftBrow
    case rightBrow
    case leftEye      // eye ring + pupil
    case rightEye
    // Body, split into independently toggleable / styleable subparts so e.g.
    // the head markers can be turned off when face tracking already covers them.
    case head
    case torso
    case leftArm
    case rightArm
    case leftLeg
    case rightLeg
    case hands
    case contour      // person silhouette (Vision segmentation)
    case bodyHull     // seg-free person outline (convex hull of landmarks)

    var displayName: String {
        switch self {
        case .jaw: return "Jaw"
        case .nose: return "Nose"
        case .mouth: return "Mouth"
        case .leftBrow: return "L Brow"
        case .rightBrow: return "R Brow"
        case .leftEye: return "L Eye"
        case .rightEye: return "R Eye"
        case .head: return "Head"
        case .torso: return "Torso"
        case .leftArm: return "L Arm"
        case .rightArm: return "R Arm"
        case .leftLeg: return "L Leg"
        case .rightLeg: return "R Leg"
        case .hands: return "Hands"
        case .contour: return "Person"
        case .bodyHull: return "Hull"
        }
    }

    /// The face subparts derived from Vision face landmarks.
    static let faceParts: [LandmarkRegion] = [.jaw, .nose, .mouth, .leftBrow, .rightBrow, .leftEye, .rightEye]
    /// The six subparts that make up the body skeleton.
    static let bodyParts: [LandmarkRegion] = [.head, .torso, .leftArm, .rightArm, .leftLeg, .rightLeg]
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
        case .jaw: return jawStyle
        case .nose: return noseStyle
        case .mouth: return mouthStyle
        case .leftBrow: return leftBrowStyle
        case .rightBrow: return rightBrowStyle
        case .leftEye: return leftEyeStyle
        case .rightEye: return rightEyeStyle
        case .head: return headStyle
        case .torso: return torsoStyle
        case .leftArm: return leftArmStyle
        case .rightArm: return rightArmStyle
        case .leftLeg: return leftLegStyle
        case .rightLeg: return rightLegStyle
        case .hands: return handsStyle
        case .contour: return contourStyle
        case .bodyHull: return bodyHullStyle
        }
    }

    /// Whether a region is currently tracked (drives detection + rendering).
    func tracks(_ region: LandmarkRegion) -> Bool {
        switch region {
        case .jaw: return trackJaw
        case .nose: return trackNose
        case .mouth: return trackMouth
        case .leftBrow: return trackLeftBrow
        case .rightBrow: return trackRightBrow
        case .leftEye: return trackLeftEye
        case .rightEye: return trackRightEye
        case .head: return trackHead
        case .torso: return trackTorso
        case .leftArm: return trackLeftArm
        case .rightArm: return trackRightArm
        case .leftLeg: return trackLeftLeg
        case .rightLeg: return trackRightLeg
        case .hands: return trackHands
        case .contour: return trackContour
        case .bodyHull: return trackBodyHull
        }
    }
}
