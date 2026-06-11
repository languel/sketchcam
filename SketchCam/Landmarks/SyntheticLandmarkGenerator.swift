import CoreGraphics
import Foundation
import SketchCamCore

enum SyntheticLandmarkGenerator {
    static func makeGroups(settings: ProcessingSettings, frameIndex: Int) -> [LandmarkGroup] {
        let t = CGFloat(frameIndex) * 0.045
        var groups: [LandmarkGroup] = []

        if settings.landmarks.trackBody {
            groups.append(LandmarkGroup(region: .body, points: bodyPoints(t: t)))
        }

        if settings.landmarks.trackHands {
            groups.append(LandmarkGroup(region: .hands, points: handPoints(center: CGPoint(x: 0.28, y: 0.56), phase: t)))
            groups.append(LandmarkGroup(region: .hands, points: handPoints(center: CGPoint(x: 0.72, y: 0.56), phase: -t)))
        }

        if settings.landmarks.trackFace {
            groups.append(LandmarkGroup(region: .face, points: facePoints(t: t)))
        }

        if settings.landmarks.trackEyesAndIrises {
            groups.append(LandmarkGroup(region: .eyes, points: eyePoints(t: t)))
        }

        return groups
    }

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
        return points.map { LandmarkPoint(point: $0, confidence: 1) }
    }

    private static func facePoints(t: CGFloat) -> [LandmarkPoint] {
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
        return points.map { LandmarkPoint(point: $0, confidence: 1) }
    }

    private static func eyePoints(t: CGFloat) -> [LandmarkPoint] {
        let centers = [
            CGPoint(x: 0.47 + sin(t) * 0.018, y: 0.215),
            CGPoint(x: 0.53 + sin(t) * 0.018, y: 0.215)
        ]
        var points: [CGPoint] = []
        for center in centers {
            for index in 0..<12 {
                let angle = CGFloat(index) / 12 * .pi * 2
                points.append(CGPoint(x: center.x + cos(angle) * 0.021, y: center.y + sin(angle) * 0.011))
            }
            points.append(CGPoint(x: center.x + cos(t) * 0.004, y: center.y + sin(t * 0.7) * 0.003))
        }
        return points.map { LandmarkPoint(point: $0, confidence: 1) }
    }

    private static func handPoints(center: CGPoint, phase: CGFloat) -> [LandmarkPoint] {
        var points: [CGPoint] = [center]
        for finger in 0..<5 {
            let spread = (CGFloat(finger) - 2) * 0.045
            for joint in 1...4 {
                let curl = sin(phase + CGFloat(finger) * 0.65) * 0.012
                points.append(CGPoint(
                    x: center.x + spread + curl * CGFloat(joint),
                    y: center.y - CGFloat(joint) * (0.038 + CGFloat(finger) * 0.002)
                ))
            }
        }
        return points.map { LandmarkPoint(point: $0, confidence: 1) }
    }
}

