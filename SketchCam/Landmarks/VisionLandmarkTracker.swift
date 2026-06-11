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
            for joint in Self.bodyJointOrder {
                let key = "body\(index).\(joint.rawValue.rawValue)"
                if let smoothed = resolve(
                    key: key,
                    candidate: recognized[joint].flatMap { $0.confidence > minimumConfidence ? ($0.location, $0.confidence) : nil }
                ) {
                    points.append(smoothed)
                    nextPoints[key] = smoothed.point
                }
            }
            return points.isEmpty ? nil : LandmarkGroup(region: .body, points: points)
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
            var points: [LandmarkPoint] = []
            for joint in Self.handJointOrder {
                let key = "hand.\(slot).\(joint.rawValue.rawValue)"
                if let smoothed = resolve(
                    key: key,
                    candidate: recognized[joint].flatMap { $0.confidence > minimumConfidence ? ($0.location, $0.confidence) : nil }
                ) {
                    points.append(smoothed)
                    nextPoints[key] = smoothed.point
                }
            }
            return points.isEmpty ? nil : LandmarkGroup(region: .hands, points: points)
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
                appendRegion(landmarks.faceContour, name: "contour", faceIndex: index, observation: observation, to: &facePoints, nextPoints: &nextPoints)
                appendRegion(landmarks.nose, name: "nose", faceIndex: index, observation: observation, to: &facePoints, nextPoints: &nextPoints)
                appendRegion(landmarks.outerLips, name: "outerLips", faceIndex: index, observation: observation, to: &facePoints, nextPoints: &nextPoints)
                appendRegion(landmarks.innerLips, name: "innerLips", faceIndex: index, observation: observation, to: &facePoints, nextPoints: &nextPoints)
                appendRegion(landmarks.leftEyebrow, name: "leftBrow", faceIndex: index, observation: observation, to: &facePoints, nextPoints: &nextPoints)
                appendRegion(landmarks.rightEyebrow, name: "rightBrow", faceIndex: index, observation: observation, to: &facePoints, nextPoints: &nextPoints)
                if !facePoints.isEmpty {
                    groups.append(LandmarkGroup(region: .face, points: facePoints))
                }
            }

            if settings.trackEyesAndIrises {
                var eyePoints: [LandmarkPoint] = []
                appendRegion(landmarks.leftEye, name: "leftEye", faceIndex: index, observation: observation, to: &eyePoints, nextPoints: &nextPoints)
                appendRegion(landmarks.rightEye, name: "rightEye", faceIndex: index, observation: observation, to: &eyePoints, nextPoints: &nextPoints)
                appendRegion(landmarks.leftPupil, name: "leftPupil", faceIndex: index, observation: observation, to: &eyePoints, nextPoints: &nextPoints)
                appendRegion(landmarks.rightPupil, name: "rightPupil", faceIndex: index, observation: observation, to: &eyePoints, nextPoints: &nextPoints)
                if !eyePoints.isEmpty {
                    groups.append(LandmarkGroup(region: .eyes, points: eyePoints))
                }
            }

            return groups
        }
    }

    private func appendRegion(
        _ region: VNFaceLandmarkRegion2D?,
        name: String,
        faceIndex: Int,
        observation: VNFaceObservation,
        to points: inout [LandmarkPoint],
        nextPoints: inout [String: CGPoint]
    ) {
        guard let region else { return }
        let box = observation.boundingBox
        for (pointIndex, normalized) in region.normalizedPoints.enumerated() {
            let key = "face\(faceIndex).\(name).\(pointIndex)"
            let location = CGPoint(
                x: box.origin.x + normalized.x * box.width,
                y: box.origin.y + normalized.y * box.height
            )
            if let smoothed = resolve(key: key, candidate: (location, observation.confidence)) {
                points.append(smoothed)
                nextPoints[key] = smoothed.point
            }
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
