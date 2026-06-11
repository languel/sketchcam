import CoreGraphics
import Foundation
import SketchCamCore

enum SyntheticLandmarkGenerator {
    static func makeGroups(settings: ProcessingSettings, frameIndex: Int) -> [LandmarkGroup] {
        let t = CGFloat(frameIndex) * 0.045
        var groups: [LandmarkGroup] = []

        if settings.landmarks.trackBody {
            groups.append(LandmarkGroup(region: .body, points: bodyPoints(t: t), edges: bodyEdges))
        }

        if settings.landmarks.trackHands {
            groups.append(handGroup(center: CGPoint(x: 0.28, y: 0.56), phase: t, prefix: "L"))
            groups.append(handGroup(center: CGPoint(x: 0.72, y: 0.56), phase: -t, prefix: "R"))
        }

        if settings.landmarks.trackFace {
            groups.append(faceGroup(t: t))
        }

        if settings.landmarks.trackEyesAndIrises {
            groups.append(eyeGroup(t: t))
        }

        return groups
    }

    // 0 head, 1/2 shoulders, 3/4 elbows, 5/6 wrists, 7/8 hips, 9/10 knees, 11/12 ankles
    private static let bodyEdges: [(Int, Int)] = [
        (0, 1), (0, 2), (1, 2),
        (1, 3), (3, 5), (2, 4), (4, 6),
        (1, 7), (2, 8), (7, 8),
        (7, 9), (9, 11), (8, 10), (10, 12)
    ]

    private static func bodyPoints(t: CGFloat) -> [LandmarkPoint] {
        let sway = sin(t) * 0.025
        let points = [
            CGPoint(x: 0.50 + sway, y: 0.28),
            CGPoint(x: 0.43 + sway, y: 0.34),
            CGPoint(x: 0.57 + sway, y: 0.34),
            CGPoint(x: 0.38 + sway, y: 0.48),
            CGPoint(x: 0.62 + sway, y: 0.48),
            CGPoint(x: 0.34 + sway, y: 0.64),
            CGPoint(x: 0.66 + sway, y: 0.64),
            CGPoint(x: 0.44 + sway, y: 0.61),
            CGPoint(x: 0.56 + sway, y: 0.61),
            CGPoint(x: 0.42 + sway, y: 0.80),
            CGPoint(x: 0.58 + sway, y: 0.80),
            CGPoint(x: 0.40 + sway, y: 0.95),
            CGPoint(x: 0.60 + sway, y: 0.95)
        ]
        return points.enumerated().map { LandmarkPoint(point: $1, confidence: 1, label: "b\($0)") }
    }

    private static func faceGroup(t: CGFloat) -> LandmarkGroup {
        let center = CGPoint(x: 0.5 + sin(t) * 0.018, y: 0.23)
        var points: [CGPoint] = []
        for index in 0..<44 {
            let angle = CGFloat(index) / 44 * .pi * 2
            let radiusX = 0.072 + sin(angle * 3 + t) * 0.006
            let radiusY = 0.096 + cos(angle * 2 - t) * 0.004
            points.append(CGPoint(x: center.x + cos(angle) * radiusX, y: center.y + sin(angle) * radiusY))
        }
        for index in 0..<16 {
            let angle = CGFloat(index) / 16 * .pi * 2
            points.append(CGPoint(x: center.x + cos(angle) * 0.025, y: center.y + 0.025 + sin(angle) * 0.018))
        }
        var edges = loopEdges(start: 0, count: 44)
        edges.append(contentsOf: loopEdges(start: 44, count: 16))
        let landmarkPoints = points.enumerated().map { LandmarkPoint(point: $1, confidence: 1, label: "f\($0)") }
        return LandmarkGroup(region: .face, points: landmarkPoints, edges: edges)
    }

    private static func eyeGroup(t: CGFloat) -> LandmarkGroup {
        let centers = [
            CGPoint(x: 0.47 + sin(t) * 0.018, y: 0.215),
            CGPoint(x: 0.53 + sin(t) * 0.018, y: 0.215)
        ]
        var points: [CGPoint] = []
        var edges: [(Int, Int)] = []
        for center in centers {
            let start = points.count
            for index in 0..<12 {
                let angle = CGFloat(index) / 12 * .pi * 2
                points.append(CGPoint(x: center.x + cos(angle) * 0.021, y: center.y + sin(angle) * 0.011))
            }
            edges.append(contentsOf: loopEdges(start: start, count: 12))
            points.append(CGPoint(x: center.x + cos(t) * 0.004, y: center.y + sin(t * 0.7) * 0.003))
        }
        let landmarkPoints = points.enumerated().map { LandmarkPoint(point: $1, confidence: 1, label: "e\($0)") }
        return LandmarkGroup(region: .eyes, points: landmarkPoints, edges: edges)
    }

    private static func handGroup(center: CGPoint, phase: CGFloat, prefix: String) -> LandmarkGroup {
        var points: [CGPoint] = [center]
        var edges: [(Int, Int)] = []
        for finger in 0..<5 {
            let spread = (CGFloat(finger) - 2) * 0.045
            let base = points.count
            for joint in 1...4 {
                let curl = sin(phase + CGFloat(finger) * 0.65) * 0.012
                points.append(CGPoint(
                    x: center.x + spread + curl * CGFloat(joint),
                    y: center.y - CGFloat(joint) * (0.038 + CGFloat(finger) * 0.002)
                ))
            }
            edges.append((0, base))
            edges.append(contentsOf: (0..<3).map { (base + $0, base + $0 + 1) })
        }
        let landmarkPoints = points.enumerated().map { LandmarkPoint(point: $1, confidence: 1, label: "\(prefix)\($0)") }
        return LandmarkGroup(region: .hands, points: landmarkPoints, edges: edges)
    }

    private static func loopEdges(start: Int, count: Int) -> [(Int, Int)] {
        var edges = (0..<(count - 1)).map { (start + $0, start + $0 + 1) }
        edges.append((start + count - 1, start))
        return edges
    }
}
