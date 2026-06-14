import AppKit
import CoreGraphics
import Foundation
import SketchCamCore

/// Yarn: a seeded random subset of each region's points, woven into a
/// many-pass tangle. Truly random sampling — wild and decorative, but it does
/// not preserve semantic structure (cf. `LineWalkDrawing`). The body-wrapping
/// variant lives in `WrapDrawing`.
struct YarnDrawing: DrawingAlgorithm {
    func isEnabled(_ landmarks: LandmarkSettings) -> Bool { landmarks.yarnEnabled }

    func render(groups: [MappedGroup], landmarks: LandmarkSettings, into context: CGContext) {
        for group in groups {
            let selected = LandmarkYarnWeaver.seededSubset(
                group.points,
                seed: landmarks.yarnSeed + DrawingSupport.seedOffset(for: group.region),
                ratio: landmarks.subsetRatio
            )
            guard selected.count > 2 else { continue }
            let stroke = DrawingSupport.stroke(for: group.region, landmarks: landmarks, matchColors: landmarks.yarnMatchesLandmarkColors, palette: landmarks.yarnPalette, width: landmarks.yarnWidth)
            let seed = landmarks.yarnSeed + DrawingSupport.seedOffset(for: group.region)
            let ordered = LandmarkYarnWeaver.wovenOrder(selected, seed: seed)
            let coiled = LandmarkYarnWeaver.coilPath(ordered, linear: landmarks.yarnLinear, circular: landmarks.yarnCircular, winding: landmarks.yarnWinding, seed: seed, closed: true)
            YarnDrawing.strokePasses(coiled, closed: true, stroke: stroke, weave: CGFloat(landmarks.yarnWeaveAmount), in: context)
        }
    }

    /// The yarn look: four overlapping strokes (dark halo, soft fill, core,
    /// white highlight). Shared by the per-region and wrap renderers.
    static func strokePasses(_ points: [CGPoint], closed: Bool, stroke: (color: RGBAColor, width: CGFloat), weave: CGFloat, in context: CGContext) {
        guard points.count >= 2 else { return }
        let width = stroke.width
        let opacity = CGFloat(min(1, max(0, stroke.color.alpha)))
        for pass in 0..<4 {
            let path = DrawingSupport.hobbyPath(points: points, weave: weave, pass: pass, closed: closed)
            let alpha = CGFloat([0.18, 0.22, 0.84, 0.46][pass]) * opacity
            let passWidth = width * CGFloat([7.5, 4.2, 1.0, 2.0][pass])
            let color: NSColor
            switch pass {
            case 0: color = NSColor.black.withAlphaComponent(alpha * 0.45)
            case 1: color = DrawingSupport.nsColor(stroke.color, alpha: alpha * 0.38)
            case 2: color = DrawingSupport.nsColor(stroke.color, alpha: alpha)
            default: color = NSColor.white.withAlphaComponent(alpha * 0.48)
            }
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(passWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }
}

enum LandmarkYarnWeaver {
    /// Turns a woven point loop into a denser coiled/zigzagged loop. `linear` =
    /// perpendicular zigzag amplitude; `circular` = coil radius (drifting circle
    /// per segment → loops); `winding` = loops per segment (>1 = local tangles).
    /// No-op when both amplitudes are ~0.
    static func coilPath(_ points: [CGPoint], linear: Float, circular: Float, winding: Float, seed: Int, closed: Bool = true) -> [CGPoint] {
        let lin = CGFloat(max(0, linear)), circ = CGFloat(max(0, circular))
        guard points.count >= 2, lin > 0.001 || circ > 0.001 else { return points }
        let wind = CGFloat(max(1, winding))
        let phase = CGFloat(seed % 360) * (.pi / 180)
        // Cap sub-samples so high winding can't explode the geometry.
        let samplesPerSegment = min(20, max(3, Int((wind * 6).rounded())))
        var dense: [CGPoint] = []
        dense.reserveCapacity(points.count * samplesPerSegment)
        let n = points.count
        let segments = closed ? n : n - 1
        for i in 0..<segments {
            let p0 = points[i], p1 = points[(i + 1) % n]
            let dx = p1.x - p0.x, dy = p1.y - p0.y
            let len = max(1, hypot(dx, dy))
            let tx = dx / len, ty = dy / len
            let nx = -ty, ny = tx
            let linAmp = lin * len * 0.4
            let circR = circ * len * 0.5
            for s in 0..<samplesPerSegment {
                let f = CGFloat(s) / CGFloat(samplesPerSegment)
                let theta = 2 * .pi * wind * f + phase
                let alongN = circR * sin(theta) + linAmp * sin(f * .pi * 3 + phase)
                let alongT = circR * cos(theta)
                dense.append(CGPoint(
                    x: p0.x + dx * f + nx * alongN + tx * alongT,
                    y: p0.y + dy * f + ny * alongN + ty * alongT
                ))
            }
        }
        if !closed, let last = points.last { dense.append(last) }
        return dense
    }

    static func seededSubset(_ points: [CGPoint], seed: Int, ratio: Float) -> [CGPoint] {
        guard points.count > 3 else { return points }
        let clamped = min(1, max(0.12, ratio))
        let target = max(4, Int(Float(points.count) * clamped))
        return points.enumerated()
            .map { (index, point) in
                (score: seededScore(index: index, seed: seed), point: point)
            }
            .sorted { $0.score < $1.score }
            .prefix(target)
            .map(\.point)
    }

    static func wovenOrder(_ points: [CGPoint], seed: Int) -> [CGPoint] {
        guard points.count > 3 else { return points }
        let centroid = center(of: points)
        let sorted = points.sorted {
            let lhsAngle = atan2($0.y - centroid.y, $0.x - centroid.x)
            let rhsAngle = atan2($1.y - centroid.y, $1.x - centroid.x)
            if lhsAngle == rhsAngle {
                return distanceSquared($0, centroid) > distanceSquared($1, centroid)
            }
            return lhsAngle < rhsAngle
        }

        let count = sorted.count
        let start = abs(seed) % count
        let step = coprimeStep(for: count, seed: seed)
        var visited = Array(repeating: false, count: count)
        var ordered: [CGPoint] = []
        var index = start

        while ordered.count < count {
            if visited[index] {
                index = nextUnvisited(after: index, visited: visited) ?? 0
            }
            visited[index] = true
            ordered.append(sorted[index])
            index = (index + step) % count
        }

        return seed.isMultiple(of: 2) ? ordered : ordered.reversed()
    }

    private static func coprimeStep(for count: Int, seed: Int) -> Int {
        guard count > 3 else { return 1 }
        let lowerBound = max(2, count / 3)
        let span = max(1, count - lowerBound - 1)
        var candidate = lowerBound + abs(seed &* 31) % span
        while greatestCommonDivisor(candidate, count) != 1 {
            candidate += 1
            if candidate >= count {
                candidate = 2
            }
        }
        return candidate
    }

    private static func nextUnvisited(after index: Int, visited: [Bool]) -> Int? {
        guard !visited.allSatisfy({ $0 }) else { return nil }
        for offset in 1...visited.count {
            let candidate = (index + offset) % visited.count
            if !visited[candidate] {
                return candidate
            }
        }
        return nil
    }

    private static func seededScore(index: Int, seed: Int) -> UInt64 {
        var value = UInt64(bitPattern: Int64(index &* 1_103_515_245 &+ seed &* 12_345))
        value ^= value >> 33
        value &*= 0xff51afd7ed558ccd
        value ^= value >> 33
        value &*= 0xc4ceb9fe1a85ec53
        value ^= value >> 33
        return value
    }

    private static func center(of points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return x
    }
}
