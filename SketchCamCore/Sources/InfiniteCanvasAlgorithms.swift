import CoreGraphics
import Foundation

public enum CurveFitter {
    public static func fit(samples: [GestureSample], recipe: CurveFitRecipe, tolerance: CGFloat = 0.002) -> EditableCurve {
        let points = simplify(samples.map(\.position), tolerance: max(0, tolerance))
        guard !points.isEmpty else { return EditableCurve(anchors: [], fitRecipe: recipe) }
        guard points.count > 1 else { return EditableCurve(anchors: [CurveAnchor(position: points[0])], fitRecipe: recipe) }

        switch recipe {
        case .polyline:
            return EditableCurve(anchors: points.map { CurveAnchor(position: $0) }, fitRecipe: recipe)
        case .catmullRom, .hobby, .bezier:
            let tension: CGFloat = recipe == .hobby ? 0.72 : (recipe == .bezier ? 0.58 : 1)
            var anchors: [CurveAnchor] = []
            for index in points.indices {
                let previous = points[max(0, index - 1)]
                let next = points[min(points.count - 1, index + 1)]
                let tangent = CGPoint(x: (next.x - previous.x) * tension / 6,
                                      y: (next.y - previous.y) * tension / 6)
                let endpoint = index == points.startIndex || index == points.index(before: points.endIndex)
                anchors.append(CurveAnchor(
                    position: points[index],
                    tangentIn: endpoint && index == points.startIndex ? .zero : CGPoint(x: -tangent.x, y: -tangent.y),
                    tangentOut: endpoint && index == points.index(before: points.endIndex) ? .zero : tangent,
                    kind: endpoint ? .smooth : .symmetric
                ))
            }
            return EditableCurve(anchors: anchors, fitRecipe: recipe)
        }
    }

    /// Ramer-Douglas-Peucker simplification. Endpoints and expressive corners
    /// survive while mouse-event noise is discarded.
    public static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2, tolerance > 0 else { return points }
        var keep = Set([0, points.count - 1])

        func recurse(_ first: Int, _ last: Int) {
            guard last > first + 1 else { return }
            var bestIndex = first
            var bestDistance: CGFloat = 0
            for index in (first + 1)..<last {
                let distance = distanceToSegment(points[index], points[first], points[last])
                if distance > bestDistance { bestDistance = distance; bestIndex = index }
            }
            guard bestDistance > tolerance else { return }
            keep.insert(bestIndex)
            recurse(first, bestIndex)
            recurse(bestIndex, last)
        }
        recurse(0, points.count - 1)
        return keep.sorted().map { points[$0] }
    }

    private static func distanceToSegment(_ point: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + dx * t), point.y - (a.y + dy * t))
    }
}

public extension EditableCurve {
    var bounds: CGRect {
        guard let first = anchors.first else { return .null }
        return anchors.dropFirst().reduce(CGRect(origin: first.position, size: .zero)) { bounds, anchor in
            bounds.union(CGRect(origin: anchor.position, size: .zero))
        }
    }

    func sampled(pointsPerSegment: Int = 12) -> [CGPoint] {
        guard let first = anchors.first else { return [] }
        guard anchors.count > 1 else { return [first.position] }
        var result = [first.position]
        let segmentCount = closed ? anchors.count : anchors.count - 1
        for index in 0..<segmentCount {
            let a = anchors[index]
            let b = anchors[(index + 1) % anchors.count]
            for step in 1...max(1, pointsPerSegment) {
                let t = CGFloat(step) / CGFloat(max(1, pointsPerSegment))
                result.append(cubic(
                    a.position,
                    CGPoint(x: a.position.x + a.tangentOut.x, y: a.position.y + a.tangentOut.y),
                    CGPoint(x: b.position.x + b.tangentIn.x, y: b.position.y + b.tangentIn.y),
                    b.position,
                    t
                ))
            }
        }
        return result
    }

    private func cubic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x,
                       y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }
}

/// Native centerline-to-outline generator inspired by Perfect Freehand. It is
/// intentionally independent from rendering so SwiftUI, SVG, and Metal can use
/// the exact same tapered silhouette.
public enum ExpressiveStrokeBuilder {
    public static func outline(samples: [GestureSample], curve: EditableCurve, profile: StrokeProfile) -> [CGPoint] {
        let centerline = curve.sampled(pointsPerSegment: 10)
        guard centerline.count > 1 else { return centerline }
        let pressures = resamplePressures(samples, count: centerline.count)
        let base = max(0.000_01, CGFloat(profile.size) * 0.006)
        var left: [CGPoint] = [], right: [CGPoint] = []
        for index in centerline.indices {
            let previous = centerline[max(0, index - 1)]
            let next = centerline[min(centerline.count - 1, index + 1)]
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = max(0.000_001, hypot(dx, dy))
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let progress = CGFloat(index) / CGFloat(max(1, centerline.count - 1))
            let start = taper(progress, amount: CGFloat(profile.startTaper))
            let end = taper(1 - progress, amount: CGFloat(profile.endTaper))
            let pressure = CGFloat(pressures[index])
            let width = base * (1 + CGFloat(profile.thinning) * (pressure * 2 - 1)) * start * end
            left.append(CGPoint(x: centerline[index].x + normal.x * width, y: centerline[index].y + normal.y * width))
            right.append(CGPoint(x: centerline[index].x - normal.x * width, y: centerline[index].y - normal.y * width))
        }
        return left + right.reversed()
    }

    private static func taper(_ distance: CGFloat, amount: CGFloat) -> CGFloat {
        guard amount > 0 else { return 1 }
        let edge = min(1, distance / max(0.000_001, amount))
        return edge * edge * (3 - 2 * edge)
    }

    private static func resamplePressures(_ samples: [GestureSample], count: Int) -> [Float] {
        guard !samples.isEmpty else { return Array(repeating: 1, count: count) }
        guard count > 1 else { return [samples[0].pressure] }
        return (0..<count).map { index in
            let position = Double(index) / Double(count - 1) * Double(samples.count - 1)
            let lower = Int(floor(position)), upper = min(samples.count - 1, lower + 1)
            let mix = Float(position - Double(lower))
            return samples[lower].pressure * (1 - mix) + samples[upper].pressure * mix
        }
    }
}

public enum TimelineEvaluator {
    public static func value(on track: AutomationTrack, at time: TimeInterval) -> AutomationValue? {
        let keys = track.keyframes.sorted { $0.time < $1.time }
        guard let first = keys.first else { return nil }
        guard time > first.time else { return first.value }
        guard let last = keys.last, time < last.time else { return keys.last?.value }
        guard let upperIndex = keys.firstIndex(where: { $0.time >= time }), upperIndex > 0 else { return last.value }
        let lower = keys[upperIndex - 1], upper = keys[upperIndex]
        guard lower.interpolation != .hold else { return lower.value }
        var t = (time - lower.time) / max(0.000_001, upper.time - lower.time)
        if lower.interpolation == .smooth { t = t * t * (3 - 2 * t) }
        return interpolate(lower.value, upper.value, t: t)
    }

    public static func camera(on track: CameraTrack, at time: TimeInterval) -> CanvasCamera? {
        let keys = track.keyframes.sorted { $0.time < $1.time }
        guard let first = keys.first else { return nil }
        guard time > first.time else { return first.camera }
        guard let upperIndex = keys.firstIndex(where: { $0.time >= time }), upperIndex > 0 else { return keys.last?.camera }
        let lower = keys[upperIndex - 1], upper = keys[upperIndex]
        guard lower.interpolation != .hold else { return lower.camera }
        var t = (time - lower.time) / max(0.000_001, upper.time - lower.time)
        if lower.interpolation == .smooth { t = t * t * (3 - 2 * t) }
        return CanvasCamera(
            center: CGPoint(x: mix(lower.camera.center.x, upper.camera.center.x, t), y: mix(lower.camera.center.y, upper.camera.center.y, t)),
            viewHeight: mix(lower.camera.viewHeight, upper.camera.viewHeight, t),
            rotation: mixAngle(lower.camera.rotation, upper.camera.rotation, t),
            guardFraction: mix(lower.camera.guardFraction, upper.camera.guardFraction, t)
        )
    }

    private static func interpolate(_ a: AutomationValue, _ b: AutomationValue, t: Double) -> AutomationValue {
        switch (a, b) {
        case let (.scalar(x), .scalar(y)): return .scalar(x + (y - x) * t)
        case let (.point(x), .point(y)):
            return .point(CGPoint(x: mix(x.x, y.x, t), y: mix(x.y, y.y, t)))
        case let (.color(x), .color(y)):
            return .color(RGBAColor(red: Float(Double(x.red) + (Double(y.red - x.red) * t)),
                                    green: Float(Double(x.green) + (Double(y.green - x.green) * t)),
                                    blue: Float(Double(x.blue) + (Double(y.blue - x.blue) * t)),
                                    alpha: Float(Double(x.alpha) + (Double(y.alpha - x.alpha) * t))))
        default: return t < 1 ? a : b
        }
    }

    private static func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
    private static func mixAngle(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        var delta = (b - a).truncatingRemainder(dividingBy: .pi * 2)
        if delta > .pi { delta -= .pi * 2 }
        if delta < -.pi { delta += .pi * 2 }
        return a + delta * CGFloat(t)
    }
}

public struct WorldTileIndex: Codable, Equatable, Hashable, Sendable {
    public var level: Int
    public var x: Int
    public var y: Int

    public init(level: Int, x: Int, y: Int) { self.level = level; self.x = x; self.y = y }
}

public enum WorldTileLayout {
    public static let pixelSize = 512

    public static func level(forPixelsPerWorldUnit density: CGFloat, baseDensity: CGFloat) -> Int {
        guard density > 0, baseDensity > 0 else { return 0 }
        return Int(round(log2(density / baseDensity)))
    }

    public static func indices(intersecting bounds: CGRect, level: Int, baseDensity: CGFloat) -> Set<WorldTileIndex> {
        let density = max(0.000_001, baseDensity * pow(2, CGFloat(level)))
        let span = CGFloat(pixelSize) / density
        let minX = Int(floor(bounds.minX / span)), maxX = Int(floor((bounds.maxX.nextDown) / span))
        let minY = Int(floor(bounds.minY / span)), maxY = Int(floor((bounds.maxY.nextDown) / span))
        var result = Set<WorldTileIndex>()
        guard maxX >= minX, maxY >= minY else { return result }
        for y in minY...maxY { for x in minX...maxX { result.insert(WorldTileIndex(level: level, x: x, y: y)) } }
        return result
    }
}
