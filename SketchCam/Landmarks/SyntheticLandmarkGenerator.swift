import CoreGraphics
import Foundation
import SketchCamCore

enum SyntheticLandmarkGenerator {
    static func makeGroups(settings: ProcessingSettings, frameIndex: Int) -> [LandmarkGroup] {
        let t = CGFloat(frameIndex) * 0.045
        var groups: [LandmarkGroup] = []

        let pts = bodyPoints(t: t)
        for part in bodySubparts where settings.landmarks.tracks(part.region) {
            let points = part.joints.map { pts[$0] }
            let edges = part.edges
            groups.append(LandmarkGroup(region: part.region, points: points, edges: edges))
        }

        if settings.landmarks.trackHands {
            groups.append(handGroup(center: CGPoint(x: 0.28, y: 0.56), phase: t, prefix: "L"))
            groups.append(handGroup(center: CGPoint(x: 0.72, y: 0.56), phase: -t, prefix: "R"))
        }

        groups.append(contentsOf: faceGroups(t: t, settings: settings.landmarks))

        return groups
    }

    // Synthetic body layout (13 points):
    // 0 head, 1/2 shoulders, 3/4 elbows, 5/6 wrists, 7/8 hips, 9/10 knees, 11/12 ankles.
    private struct BodySubpart {
        let region: LandmarkRegion
        let joints: [Int]        // indices into bodyPoints
        let edges: [(Int, Int)]  // positions within `joints`
    }

    private static let bodySubparts: [BodySubpart] = [
        BodySubpart(region: .head, joints: [0], edges: []),
        BodySubpart(region: .torso, joints: [1, 2, 8, 7], edges: [(0, 1), (1, 2), (2, 3), (3, 0)]),
        BodySubpart(region: .leftArm, joints: [1, 3, 5], edges: [(0, 1), (1, 2)]),
        BodySubpart(region: .rightArm, joints: [2, 4, 6], edges: [(0, 1), (1, 2)]),
        BodySubpart(region: .leftLeg, joints: [7, 9, 11], edges: [(0, 1), (1, 2)]),
        BodySubpart(region: .rightLeg, joints: [8, 10, 12], edges: [(0, 1), (1, 2)])
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

    /// Builds the tracked face subparts as separate groups (mirrors the Vision
    /// breakdown: jaw, nose, mouth, brows, eyes).
    private static func faceGroups(t: CGFloat, settings: LandmarkSettings) -> [LandmarkGroup] {
        let center = CGPoint(x: 0.5 + sin(t) * 0.018, y: 0.23)
        var groups: [LandmarkGroup] = []
        func emit(_ region: LandmarkRegion, _ make: () -> LandmarkGroup) {
            if settings.tracks(region) { groups.append(make()) }
        }
        emit(.jaw) { closedLoop(.jaw, center: center, rx: 0.072, ry: 0.096, count: 44, short: "c", t: t) }
        emit(.nose) { openArc(.nose, center: CGPoint(x: center.x, y: center.y + 0.02), width: 0.02, dip: -0.04, count: 5, short: "n") }
        emit(.mouth) { closedLoop(.mouth, center: CGPoint(x: center.x, y: center.y + 0.055), rx: 0.03, ry: 0.012, count: 12, short: "m", t: t) }
        emit(.leftBrow) { openArc(.leftBrow, center: CGPoint(x: center.x - 0.03, y: center.y - 0.045), width: 0.03, dip: 0.012, count: 5, short: "bL") }
        emit(.rightBrow) { openArc(.rightBrow, center: CGPoint(x: center.x + 0.03, y: center.y - 0.045), width: 0.03, dip: 0.012, count: 5, short: "bR") }
        emit(.leftEye) { eyeRing(.leftEye, center: CGPoint(x: center.x - 0.03, y: center.y - 0.015), t: t, short: "eL") }
        emit(.rightEye) { eyeRing(.rightEye, center: CGPoint(x: center.x + 0.03, y: center.y - 0.015), t: t, short: "eR") }
        return groups
    }

    private static func closedLoop(_ region: LandmarkRegion, center: CGPoint, rx: CGFloat, ry: CGFloat, count: Int, short: String, t: CGFloat) -> LandmarkGroup {
        let points = (0..<count).map { index -> LandmarkPoint in
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            return LandmarkPoint(point: CGPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry), confidence: 1, label: "\(short)\(index)")
        }
        return LandmarkGroup(region: region, points: points, edges: loopEdges(start: 0, count: count))
    }

    private static func openArc(_ region: LandmarkRegion, center: CGPoint, width: CGFloat, dip: CGFloat, count: Int, short: String) -> LandmarkGroup {
        let points = (0..<count).map { index -> LandmarkPoint in
            let f = CGFloat(index) / CGFloat(count - 1)
            return LandmarkPoint(point: CGPoint(x: center.x - width / 2 + width * f, y: center.y - sin(f * .pi) * dip), confidence: 1, label: "\(short)\(index)")
        }
        let edges = (0..<(count - 1)).map { ($0, $0 + 1) }
        return LandmarkGroup(region: region, points: points, edges: edges)
    }

    private static func eyeRing(_ region: LandmarkRegion, center: CGPoint, t: CGFloat, short: String) -> LandmarkGroup {
        var points: [LandmarkPoint] = []
        for index in 0..<12 {
            let angle = CGFloat(index) / 12 * .pi * 2
            points.append(LandmarkPoint(point: CGPoint(x: center.x + cos(angle) * 0.021, y: center.y + sin(angle) * 0.011), confidence: 1, label: "\(short)\(index)"))
        }
        let edges = loopEdges(start: 0, count: 12)
        points.append(LandmarkPoint(point: CGPoint(x: center.x + cos(t) * 0.004, y: center.y + sin(t * 0.7) * 0.003), confidence: 1, label: "\(short)p"))
        return LandmarkGroup(region: region, points: points, edges: edges)
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
