import CoreGraphics
import CoreVideo
import Foundation
import SketchCamCore
import Vision

/// Apple Vision landmark backend. Runs off the frame hot path on the
/// detection queue; the caller hands in an already-downsampled buffer.
/// Request objects are created once and reused (re-creating them per call
/// re-validates model state every time).
final class VisionLandmarkTracker {
    private let sequenceHandler = VNSequenceRequestHandler()
    private let bodyRequest = VNDetectHumanBodyPoseRequest()
    private let handRequest: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()
    private let faceRequest = VNDetectFaceLandmarksRequest()
    private var previousGroups: [LandmarkRegion: [[CGPoint]]] = [:]

    private let minimumConfidence: Float = 0.2
    private let smoothingBlend: CGFloat = 0.45

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

        var groups: [LandmarkGroup] = []
        if settings.trackBody {
            groups.append(contentsOf: bodyGroups())
        }
        if settings.trackHands {
            groups.append(contentsOf: handGroups())
        }
        if settings.trackFace || settings.trackEyesAndIrises {
            groups.append(contentsOf: faceGroups(settings: settings))
        }
        return smooth(groups)
    }

    private func bodyGroups() -> [LandmarkGroup] {
        (bodyRequest.results ?? []).compactMap { observation in
            guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
            let points = recognized.values
                .filter { $0.confidence > minimumConfidence }
                .map { LandmarkPoint(point: $0.location, confidence: $0.confidence) }
            return points.isEmpty ? nil : LandmarkGroup(region: .body, points: points)
        }
    }

    private func handGroups() -> [LandmarkGroup] {
        (handRequest.results ?? []).compactMap { observation in
            guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
            let points = recognized.values
                .filter { $0.confidence > minimumConfidence }
                .map { LandmarkPoint(point: $0.location, confidence: $0.confidence) }
            return points.isEmpty ? nil : LandmarkGroup(region: .hands, points: points)
        }
    }

    private func faceGroups(settings: LandmarkSettings) -> [LandmarkGroup] {
        (faceRequest.results ?? []).flatMap { observation -> [LandmarkGroup] in
            guard let landmarks = observation.landmarks else { return [] }
            var groups: [LandmarkGroup] = []

            if settings.trackFace {
                var facePoints: [LandmarkPoint] = []
                append(landmarks.faceContour, in: observation, to: &facePoints)
                append(landmarks.nose, in: observation, to: &facePoints)
                append(landmarks.outerLips, in: observation, to: &facePoints)
                append(landmarks.innerLips, in: observation, to: &facePoints)
                append(landmarks.leftEyebrow, in: observation, to: &facePoints)
                append(landmarks.rightEyebrow, in: observation, to: &facePoints)
                if !facePoints.isEmpty {
                    groups.append(LandmarkGroup(region: .face, points: facePoints))
                }
            }

            if settings.trackEyesAndIrises {
                var eyePoints: [LandmarkPoint] = []
                append(landmarks.leftEye, in: observation, to: &eyePoints)
                append(landmarks.rightEye, in: observation, to: &eyePoints)
                append(landmarks.leftPupil, in: observation, to: &eyePoints)
                append(landmarks.rightPupil, in: observation, to: &eyePoints)
                if !eyePoints.isEmpty {
                    groups.append(LandmarkGroup(region: .eyes, points: eyePoints))
                }
            }

            return groups
        }
    }

    private func append(_ region: VNFaceLandmarkRegion2D?, in observation: VNFaceObservation, to points: inout [LandmarkPoint]) {
        guard let region else { return }
        let box = observation.boundingBox
        points.append(contentsOf: region.normalizedPoints.map { normalized in
            let point = CGPoint(
                x: box.origin.x + normalized.x * box.width,
                y: box.origin.y + normalized.y * box.height
            )
            return LandmarkPoint(point: point, confidence: observation.confidence)
        })
    }

    /// One-pole smoothing against the previous detection to tame jitter.
    private func smooth(_ groups: [LandmarkGroup]) -> [LandmarkGroup] {
        var regionCounts: [LandmarkRegion: Int] = [:]
        var nextPrevious: [LandmarkRegion: [[CGPoint]]] = [:]

        let smoothed = groups.map { group -> LandmarkGroup in
            let groupIndex = regionCounts[group.region, default: 0]
            regionCounts[group.region] = groupIndex + 1
            let previous = previousGroups[group.region]?[safe: groupIndex]
            let points = group.points.enumerated().map { index, point -> LandmarkPoint in
                guard let old = previous?[safe: index] else { return point }
                let smoothedPoint = CGPoint(
                    x: old.x + (point.point.x - old.x) * smoothingBlend,
                    y: old.y + (point.point.y - old.y) * smoothingBlend
                )
                return LandmarkPoint(point: smoothedPoint, confidence: point.confidence)
            }
            nextPrevious[group.region, default: []].append(points.map(\.point))
            return LandmarkGroup(region: group.region, points: points)
        }

        previousGroups = nextPrevious
        return smoothed
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
