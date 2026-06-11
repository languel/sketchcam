import CoreGraphics
import CoreVideo
import Foundation
import SketchCamCore
import Vision

/// Apple Vision landmark backend. Runs off the frame hot path on the
/// detection queue; the caller hands in an already-downsampled buffer.
///
/// Stability rules (the yarn rewires and points jitter without them):
/// - `recognizedPoints(.all)` is an UNORDERED dictionary — joints are
///   emitted in a fixed canonical order, never dictionary order.
/// - Hands are assigned stable slots by chirality (left/right), so the two
///   observations can't swap from one detection to the next.
/// - Smoothing is keyed by joint identity (e.g. "hand.left.thumbTip"), not
///   by array index, and a joint that drops below the confidence threshold
///   for one detection carries over its previous position instead of
///   changing the point count (count changes re-weave the whole yarn).
final class VisionLandmarkTracker {
    private let sequenceHandler = VNSequenceRequestHandler()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    private let faceRequest = VNDetectFaceLandmarksRequest()

    private let minimumConfidence: Float = 0.2
    private let smoothingBlend: CGFloat = 0.45
    /// Previous smoothed positions, keyed by stable joint identity.
    private var previousPoints: [String: CGPoint] = [:]
    /// Joints allowed to carry over once when confidence drops.
    private var carryoverBudget: [String: Int] = [:]
    private let maxCarryoverDetections = 3

    private static let bodyJointOrder: [VNHumanBodyPoseObservation.JointName] = [
        .nose, .leftEye, .rightEye, .leftEar, .rightEar,
        .neck, .leftShoulder, .rightShoulder,
        .leftElbow, .rightElbow, .leftWrist, .rightWrist,
        .root, .leftHip, .rightHip,
        .leftKnee, .rightKnee, .leftAnkle, .rightAnkle
    ]

    /// Short labels for the canonical body joints (same order).
    private static let bodyJointLabels: [String] = [
        "nose", "Leye", "Reye", "Lear", "Rear",
        "neck", "Lsho", "Rsho",
        "Lelb", "Relb", "Lwri", "Rwri",
        "root", "Lhip", "Rhip",
        "Lkne", "Rkne", "Lank", "Rank"
    ]

    /// Skeleton connections over the canonical body joints (by canonical
    /// index; remapped to emitted indices per detection since dropped
    /// joints shift positions).
    private static let bodyEdges: [(Int, Int)] = [
        (0, 1), (0, 2), (1, 3), (2, 4),          // head
        (0, 5),                                   // nose-neck
        (5, 6), (5, 7),                           // neck-shoulders
        (6, 8), (8, 10), (7, 9), (9, 11),         // arms
        (5, 12), (12, 13), (12, 14),              // spine-hips
        (13, 15), (15, 17), (14, 16), (16, 18)    // legs
    ]

    /// MediaPipe hand connections — `handJointOrder` matches MediaPipe's
    /// 0–20 hand-landmark indexing, so these are the documented pairs.
    private static let handEdges: [(Int, Int)] = [
        (0, 1), (1, 2), (2, 3), (3, 4),           // thumb
        (0, 5), (5, 6), (6, 7), (7, 8),           // index
        (5, 9), (9, 10), (10, 11), (11, 12),      // middle
        (9, 13), (13, 14), (14, 15), (15, 16),    // ring
        (13, 17), (0, 17), (17, 18), (18, 19), (19, 20) // pinky + palm edge
    ]

    private static let handJointOrder: [VNHumanHandPoseObservation.JointName] = [
        .wrist,
        .thumbCMC, .thumbMP, .thumbIP, .thumbTip,
        .indexMCP, .indexPIP, .indexDIP, .indexTip,
        .middleMCP, .middlePIP, .middleDIP, .middleTip,
        .ringMCP, .ringPIP, .ringDIP, .ringTip,
        .littleMCP, .littlePIP, .littleDIP, .littleTip
    ]

    func detect(in pixelBuffer: CVPixelBuffer, settings: LandmarkSettings) -> [LandmarkGroup] {
        var requests: [VNRequest] = []
        if settings.trackBody { requests.append(bodyRequest) }
        if settings.trackHands { requests.append(handRequest) }
        if settings.trackFace || settings.trackEyesAndIrises { requests.append(faceRequest) }
        guard !requests.isEmpty else { return [] }

        do {
            try sequenceHandler.perform(requests, on: pixelBuffer, orientation: .up)
        } catch {
            return []
        }

        var nextPoints: [String: CGPoint] = [:]
        var groups: [LandmarkGroup] = []
        if settings.trackBody {
            groups.append(contentsOf: bodyGroups(into: &nextPoints))
        }
        if settings.trackHands {
            groups.append(contentsOf: handGroups(into: &nextPoints))
        }
        if settings.trackFace || settings.trackEyesAndIrises {
            groups.append(contentsOf: faceGroups(settings: settings, into: &nextPoints))
        }
        previousPoints = nextPoints
        return groups
    }

    // MARK: - Body

    private func bodyGroups(into nextPoints: inout [String: CGPoint]) -> [LandmarkGroup] {
        // Sort multi-person observations left-to-right so person slots are stable.
        let observations = (bodyRequest.results ?? []).sorted {
            centerX(of: $0) < centerX(of: $1)
        }
        return observations.enumerated().compactMap { index, observation in
            guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
            var points: [LandmarkPoint] = []
            var emittedIndex: [Int: Int] = [:]  // canonical index → emitted index
            for (canonicalIndex, joint) in Self.bodyJointOrder.enumerated() {
                let label = Self.bodyJointLabels[canonicalIndex]
                let key = "body\(index).\(label)"
                if var smoothed = resolve(
                    key: key,
                    candidate: recognized[joint].flatMap { $0.confidence > minimumConfidence ? ($0.location, $0.confidence) : nil }
                ) {
                    smoothed.label = label
                    emittedIndex[canonicalIndex] = points.count
                    points.append(smoothed)
                    nextPoints[key] = smoothed.point
                }
            }
            let edges = Self.bodyEdges.compactMap { edge -> (Int, Int)? in
                guard let a = emittedIndex[edge.0], let b = emittedIndex[edge.1] else { return nil }
                return (a, b)
            }
            return points.isEmpty ? nil : LandmarkGroup(region: .body, points: points, edges: edges)
        }
    }

    private func centerX(of observation: VNHumanBodyPoseObservation) -> CGFloat {
        guard let recognized = try? observation.recognizedPoints(.all), !recognized.isEmpty else { return 0.5 }
        let sum = recognized.values.reduce(CGFloat.zero) { $0 + $1.location.x }
        return sum / CGFloat(recognized.count)
    }

    // MARK: - Hands

    private func handGroups(into nextPoints: inout [String: CGPoint]) -> [LandmarkGroup] {
        let observations = handRequest.results ?? []
        // Stable slots: left hand, right hand, extras by x position. A hand
        // whose chirality flips between detections would otherwise swap all
        // of its joints with the other hand.
        var slots: [(slot: String, observation: VNHumanHandPoseObservation)] = []
        var unknowns: [VNHumanHandPoseObservation] = []
        for observation in observations {
            switch observation.chirality {
            case .left where !slots.contains(where: { $0.slot == "left" }):
                slots.append(("left", observation))
            case .right where !slots.contains(where: { $0.slot == "right" }):
                slots.append(("right", observation))
            default:
                unknowns.append(observation)
            }
        }
        for (offset, observation) in unknowns.enumerated() {
            slots.append(("extra\(offset)", observation))
        }

        return slots.compactMap { slot, observation in
            guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
            // Label prefix: MediaPipe-style indices per hand ("L4" = left thumb tip).
            let prefix = slot == "left" ? "L" : slot == "right" ? "R" : "E"
            var points: [LandmarkPoint] = []
            var emittedIndex: [Int: Int] = [:]
            for (canonicalIndex, joint) in Self.handJointOrder.enumerated() {
                let label = "\(prefix)\(canonicalIndex)"
                let key = "hand.\(slot).\(canonicalIndex)"
                if var smoothed = resolve(
                    key: key,
                    candidate: recognized[joint].flatMap { $0.confidence > minimumConfidence ? ($0.location, $0.confidence) : nil }
                ) {
                    smoothed.label = label
                    emittedIndex[canonicalIndex] = points.count
                    points.append(smoothed)
                    nextPoints[key] = smoothed.point
                }
            }
            let edges = Self.handEdges.compactMap { edge -> (Int, Int)? in
                guard let a = emittedIndex[edge.0], let b = emittedIndex[edge.1] else { return nil }
                return (a, b)
            }
            return points.isEmpty ? nil : LandmarkGroup(region: .hands, points: points, edges: edges)
        }
    }

    // MARK: - Face

    private func faceGroups(settings: LandmarkSettings, into nextPoints: inout [String: CGPoint]) -> [LandmarkGroup] {
        let observations = (faceRequest.results ?? []).sorted {
            $0.boundingBox.midX < $1.boundingBox.midX
        }
        return observations.enumerated().flatMap { index, observation -> [LandmarkGroup] in
            guard let landmarks = observation.landmarks else { return [] }
            var groups: [LandmarkGroup] = []

            if settings.trackFace {
                var facePoints: [LandmarkPoint] = []
                var faceEdges: [(Int, Int)] = []
                appendRegion(landmarks.faceContour, short: "c", chain: .open, faceIndex: index, observation: observation, to: &facePoints, edges: &faceEdges, nextPoints: &nextPoints)
                appendRegion(landmarks.nose, short: "n", chain: .open, faceIndex: index, observation: observation, to: &facePoints, edges: &faceEdges, nextPoints: &nextPoints)
                appendRegion(landmarks.outerLips, short: "oL", chain: .closed, faceIndex: index, observation: observation, to: &facePoints, edges: &faceEdges, nextPoints: &nextPoints)
                appendRegion(landmarks.innerLips, short: "iL", chain: .closed, faceIndex: index, observation: observation, to: &facePoints, edges: &faceEdges, nextPoints: &nextPoints)
                appendRegion(landmarks.leftEyebrow, short: "bL", chain: .open, faceIndex: index, observation: observation, to: &facePoints, edges: &faceEdges, nextPoints: &nextPoints)
                appendRegion(landmarks.rightEyebrow, short: "bR", chain: .open, faceIndex: index, observation: observation, to: &facePoints, edges: &faceEdges, nextPoints: &nextPoints)
                if !facePoints.isEmpty {
                    groups.append(LandmarkGroup(region: .face, points: facePoints, edges: faceEdges))
                }
            }

            if settings.trackEyesAndIrises {
                var eyePoints: [LandmarkPoint] = []
                var eyeEdges: [(Int, Int)] = []
                appendRegion(landmarks.leftEye, short: "eL", chain: .closed, faceIndex: index, observation: observation, to: &eyePoints, edges: &eyeEdges, nextPoints: &nextPoints)
                appendRegion(landmarks.rightEye, short: "eR", chain: .closed, faceIndex: index, observation: observation, to: &eyePoints, edges: &eyeEdges, nextPoints: &nextPoints)
                appendRegion(landmarks.leftPupil, short: "pL", chain: .none, faceIndex: index, observation: observation, to: &eyePoints, edges: &eyeEdges, nextPoints: &nextPoints)
                appendRegion(landmarks.rightPupil, short: "pR", chain: .none, faceIndex: index, observation: observation, to: &eyePoints, edges: &eyeEdges, nextPoints: &nextPoints)
                if !eyePoints.isEmpty {
                    groups.append(LandmarkGroup(region: .eyes, points: eyePoints, edges: eyeEdges))
                }
            }

            return groups
        }
    }

    private enum ChainStyle {
        case none
        case open
        case closed
    }

    private func appendRegion(
        _ region: VNFaceLandmarkRegion2D?,
        short: String,
        chain: ChainStyle,
        faceIndex: Int,
        observation: VNFaceObservation,
        to points: inout [LandmarkPoint],
        edges: inout [(Int, Int)],
        nextPoints: inout [String: CGPoint]
    ) {
        guard let region else { return }
        let box = observation.boundingBox
        let start = points.count
        for (pointIndex, normalized) in region.normalizedPoints.enumerated() {
            let key = "face\(faceIndex).\(short).\(pointIndex)"
            let location = CGPoint(
                x: box.origin.x + normalized.x * box.width,
                y: box.origin.y + normalized.y * box.height
            )
            if var smoothed = resolve(key: key, candidate: (location, observation.confidence)) {
                smoothed.label = "\(short)\(pointIndex)"
                points.append(smoothed)
                nextPoints[key] = smoothed.point
            }
        }
        let count = points.count - start
        guard count > 1, chain != .none else { return }
        for offset in 0..<(count - 1) {
            edges.append((start + offset, start + offset + 1))
        }
        if chain == .closed {
            edges.append((start + count - 1, start))
        }
    }

    // MARK: - Keyed smoothing + carry-over

    /// One-pole smoothing against the previous detection, keyed by joint
    /// identity. When `candidate` is nil (joint dropped this detection) the
    /// previous position carries over for up to `maxCarryoverDetections`
    /// so the group's point count stays stable through brief dropouts.
    private func resolve(key: String, candidate: (location: CGPoint, confidence: Float)?) -> LandmarkPoint? {
        if let candidate {
            carryoverBudget[key] = maxCarryoverDetections
            guard let previous = previousPoints[key] else {
                return LandmarkPoint(point: candidate.location, confidence: candidate.confidence)
            }
            let smoothed = CGPoint(
                x: previous.x + (candidate.location.x - previous.x) * smoothingBlend,
                y: previous.y + (candidate.location.y - previous.y) * smoothingBlend
            )
            return LandmarkPoint(point: smoothed, confidence: candidate.confidence)
        }

        guard let previous = previousPoints[key], let budget = carryoverBudget[key], budget > 0 else {
            return nil
        }
        carryoverBudget[key] = budget - 1
        return LandmarkPoint(point: previous, confidence: minimumConfidence)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
