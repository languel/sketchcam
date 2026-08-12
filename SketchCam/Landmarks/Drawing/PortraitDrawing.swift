import AppKit
import CoreGraphics
import Foundation
import SketchCamCore

/// Portrait: a stable semantic line through facial and body features. Unlike
/// Yarn/LineWalk it never solves a nearest-neighbour tour, so a moving landmark
/// deforms the existing portrait instead of reconnecting the drawing.
struct PortraitDrawing: DrawingAlgorithm {
    func isEnabled(_ landmarks: LandmarkSettings) -> Bool {
        landmarks.resolvedPortraitEnabled
    }

    func render(groups: [MappedGroup], landmarks: LandmarkSettings, into context: CGContext) {
        for stroke in strokes(groups: groups, landmarks: landmarks) {
            DrawingSupport.renderStroke(stroke, bead: landmarks.beadStroke, into: context)
        }
    }

    func strokes(groups: [MappedGroup], landmarks: LandmarkSettings) -> [StrokeTessellator.Stroke] {
        semanticRoutes(groups: groups, landmarks: landmarks).enumerated().flatMap { index, route in
            DrawingSupport.ribbonStrokes(
                route,
                color: landmarks.resolvedPortraitColor,
                baseWidth: CGFloat(max(0.4, landmarks.resolvedPortraitWidth)),
                widthVariation: landmarks.resolvedPortraitWidthVariation,
                halo: landmarks.resolvedPortraitHalo,
                seed: 401 + index * 17
            )
        }
    }

    /// Exposed internally for geometry tests. The first route is the face, the
    /// second is the body; either may be absent when its markers are unavailable.
    func semanticRoutes(groups: [MappedGroup], landmarks: LandmarkSettings) -> [[CGPoint]] {
        // A segmentation contour can contain hundreds of points. It is only a
        // fallback silhouette when no articulated body route exists, so do not
        // build its connectivity graph just to discard it below. Prefer Hull
        // over Contour to match the established body-order fallback.
        let hasArticulatedBody = groups.contains {
            PortraitPathBuilder.isArticulatedBodyRegion($0.region) && $0.points.count >= 2
        }
        let hasHull = groups.contains { $0.region == .bodyHull && $0.points.count >= 2 }
        let routeGroups = groups.filter { group in
            switch group.region {
            case .bodyHull: return !hasArticulatedBody
            case .contour: return !hasArticulatedBody && !hasHull
            default: return true
            }
        }
        let components = routeGroups.flatMap(PortraitPathBuilder.components)
        let componentsByRegion = Dictionary(grouping: components, by: \.region)
        var routes: [[CGPoint]] = []

        let faceOrder: [LandmarkRegion] = [
            .leftBrow, .leftEye, .nose, .rightEye, .rightBrow, .jaw, .mouth
        ]
        var faceFeatures: [PortraitPathBuilder.Component] = []
        for region in faceOrder {
            let candidates = (componentsByRegion[region] ?? []).sorted { $0.points.count > $1.points.count }
            if region == .mouth {
                faceFeatures.append(contentsOf: candidates.prefix(2))
            } else if let first = candidates.first {
                faceFeatures.append(first)
            }
        }
        if let face = route(
            features: faceFeatures,
            style: landmarks.resolvedPortraitStyle,
            follow: landmarks.resolvedPortraitFollow,
            flourish: landmarks.resolvedPortraitFlourish,
            seed: 17
        ) {
            routes.append(face)
        }

        let bodyOrder: [LandmarkRegion] = [
            .head, .leftArm, .torso, .rightArm, .rightLeg, .leftLeg, .hands, .bodyHull, .contour
        ]
        var bodyFeatures: [PortraitPathBuilder.Component] = []
        for region in bodyOrder {
            let candidates = (componentsByRegion[region] ?? []).sorted { $0.points.count > $1.points.count }
            // A silhouette is an alternative body outline, not another pass
            // over an already complete skeleton.
            if region == .bodyHull || region == .contour {
                if bodyFeatures.isEmpty, let first = candidates.first { bodyFeatures.append(first) }
            } else {
                bodyFeatures.append(contentsOf: candidates)
            }
        }
        if let body = route(
            features: bodyFeatures,
            style: landmarks.resolvedPortraitStyle,
            follow: landmarks.resolvedPortraitFollow,
            flourish: landmarks.resolvedPortraitFlourish,
            seed: 53
        ) {
            routes.append(body)
        }
        return routes
    }

    private func route(
        features: [PortraitPathBuilder.Component],
        style: PortraitStyle,
        follow: Float,
        flourish: Float,
        seed: Int
    ) -> [CGPoint]? {
        let usable = features.filter { $0.points.count >= 2 }
        guard !usable.isEmpty else { return nil }
        let bounds = usable.reduce(CGRect.null) { partial, feature in
            feature.points.reduce(partial) { $0.union(CGRect(origin: $1, size: .zero)) }
        }
        let scale = max(8, max(bounds.width, bounds.height))
        var result: [CGPoint] = []
        result.reserveCapacity(usable.reduce(0) { $0 + $1.points.count * 2 })

        for (index, feature) in usable.enumerated() {
            let sourcePoints = PortraitPathBuilder.uniformlySample(feature.points, maximumCount: 160)
            let points = PortraitPathBuilder.stylize(
                sourcePoints,
                closed: feature.closed,
                style: style,
                follow: follow,
                flourish: flourish,
                scale: scale,
                seed: seed + index * 31
            )
            guard !points.isEmpty else { continue }
            if let from = result.last, let to = points.first {
                result.append(contentsOf: PortraitPathBuilder.bridge(
                    from: from,
                    to: to,
                    style: style,
                    flourish: flourish,
                    scale: scale,
                    index: index
                ))
            }
            result.append(contentsOf: points)
        }

        guard result.count >= 2 else { return nil }
        // Predictive tracking can rebuild the route at display cadence. Bound
        // pathological contour/multi-person inputs while leaving ordinary
        // face/body routes untouched. Uniform sampling preserves the semantic
        // itinerary, endpoints, and incoming motion.
        let bounded = PortraitPathBuilder.uniformlySample(result, maximumCount: 320)
        let fit: CurveFit = style == .cubist ? .polyline : .hobby
        return DrawingSupport.curvePoints(bounded, fit: fit, samplesPerSegment: style == .ornate ? 4 : 3)
    }
}

enum PortraitPathBuilder {
    struct Component {
        var region: LandmarkRegion
        var points: [CGPoint]
        var closed: Bool
    }

    static func isArticulatedBodyRegion(_ region: LandmarkRegion) -> Bool {
        switch region {
        case .torso, .leftArm, .rightArm, .leftLeg, .rightLeg, .hands: return true
        default: return false
        }
    }

    /// Split compound landmark groups (outer/inner lips, eye/pupil, hands) into
    /// stable edge-connected paths and order every path deterministically.
    static func components(_ group: MappedGroup) -> [Component] {
        guard !group.points.isEmpty else { return [] }
        guard !group.edges.isEmpty else {
            return group.points.count >= 2
                ? [Component(region: group.region, points: group.points, closed: false)]
                : []
        }

        var adjacency = Array(repeating: [Int](), count: group.points.count)
        var validEdges: [(Int, Int)] = []
        for (a, b) in group.edges where group.points.indices.contains(a) && group.points.indices.contains(b) && a != b {
            adjacency[a].append(b)
            adjacency[b].append(a)
            validEdges.append((a, b))
        }
        adjacency.indices.forEach { adjacency[$0].sort() }

        var unseen = Set(validEdges.flatMap { [$0.0, $0.1] })
        var output: [Component] = []
        while let seed = unseen.min() {
            var stack = [seed]
            var indices = Set<Int>()
            while let current = stack.popLast() {
                guard indices.insert(current).inserted else { continue }
                unseen.remove(current)
                stack.append(contentsOf: adjacency[current])
            }
            guard indices.count >= 2 else { continue }
            let closed = indices.allSatisfy { adjacency[$0].filter(indices.contains).count == 2 }
            let start = indices.filter { adjacency[$0].filter(indices.contains).count == 1 }.min() ?? indices.min()!
            let order = edgeWalk(start: start, allowed: indices, adjacency: adjacency)
            guard order.count >= 2 else { continue }
            var points = order.map { group.points[$0] }
            if closed, let first = points.first, points.last != first { points.append(first) }
            output.append(Component(region: group.region, points: points, closed: closed))
        }
        return output
    }

    private static func edgeWalk(start: Int, allowed: Set<Int>, adjacency: [[Int]]) -> [Int] {
        struct Edge: Hashable {
            let a: Int
            let b: Int
            init(_ x: Int, _ y: Int) { a = min(x, y); b = max(x, y) }
        }
        var used = Set<Edge>()
        var route = [start]

        func visit(_ node: Int) {
            for next in adjacency[node] where allowed.contains(next) {
                let edge = Edge(node, next)
                guard used.insert(edge).inserted else { continue }
                route.append(next)
                visit(next)
                if adjacency[next].filter(allowed.contains).count > 2 {
                    route.append(node)
                }
            }
        }
        visit(start)
        return route
    }

    static func stylize(
        _ input: [CGPoint],
        closed: Bool,
        style: PortraitStyle,
        follow: Float,
        flourish: Float,
        scale: CGFloat,
        seed: Int
    ) -> [CGPoint] {
        guard input.count >= 2 else { return input }
        let clampedFollow = CGFloat(max(0, min(1, follow)))
        let clampedFlourish = CGFloat(max(0, min(1, flourish)))
        let raw = input
        let smoothed = smooth(raw, closed: closed, passes: style == .fluid ? 2 : 1)
        let artistic: [CGPoint]
        switch style {
        case .fluid:
            artistic = smoothed
        case .cubist:
            artistic = polygonalize(smoothed, closed: closed, anchors: closed ? 7 : 5)
        case .ornate:
            artistic = wave(smoothed, amplitude: scale * (0.015 + clampedFlourish * 0.045), seed: seed)
        }

        // Even at full follow retain a trace of the selected drawing hand;
        // Follow controls likeness, while Style remains independently visible.
        let artisticWeight = 1 - clampedFollow * 0.85
        let blended = zip(raw, artistic).map { source, target in
            CGPoint(
                x: source.x + (target.x - source.x) * artisticWeight,
                y: source.y + (target.y - source.y) * artisticWeight
            )
        }
        return embellish(
            blended,
            style: style,
            amount: clampedFlourish,
            scale: scale,
            seed: seed
        )
    }

    static func bridge(
        from: CGPoint,
        to: CGPoint,
        style: PortraitStyle,
        flourish: Float,
        scale: CGFloat,
        index: Int
    ) -> [CGPoint] {
        let f = CGFloat(max(0, min(1, flourish)))
        let midpoint = CGPoint(x: (from.x + to.x) * 0.5, y: (from.y + to.y) * 0.5)
        let dx = to.x - from.x, dy = to.y - from.y
        let length = max(1, hypot(dx, dy))
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let sign: CGFloat = index.isMultiple(of: 2) ? 1 : -1
        switch style {
        case .fluid:
            let amplitude = min(length * 0.18, scale * (0.015 + f * 0.03)) * sign
            return [CGPoint(x: midpoint.x + normal.x * amplitude, y: midpoint.y + normal.y * amplitude)]
        case .cubist:
            return index.isMultiple(of: 2)
                ? [CGPoint(x: to.x, y: from.y)]
                : [CGPoint(x: from.x, y: to.y)]
        case .ornate:
            let amplitude = min(length * 0.28, scale * (0.025 + f * 0.08)) * sign
            return [
                CGPoint(x: midpoint.x + normal.x * amplitude, y: midpoint.y + normal.y * amplitude),
                CGPoint(x: midpoint.x - normal.x * amplitude * 0.8, y: midpoint.y - normal.y * amplitude * 0.8),
                CGPoint(x: midpoint.x + normal.x * amplitude * 0.35, y: midpoint.y + normal.y * amplitude * 0.35)
            ]
        }
    }

    static func uniformlySample(_ points: [CGPoint], maximumCount: Int) -> [CGPoint] {
        guard maximumCount >= 2, points.count > maximumCount else { return points }
        let last = points.count - 1
        return (0..<maximumCount).map { index in
            points[Int((Double(index) * Double(last) / Double(maximumCount - 1)).rounded())]
        }
    }

    private static func smooth(_ points: [CGPoint], closed: Bool, passes: Int) -> [CGPoint] {
        var result = points
        guard result.count > 2 else { return result }
        for _ in 0..<passes {
            let source = result
            for index in source.indices {
                if !closed, index == source.startIndex || index == source.index(before: source.endIndex) { continue }
                let previous = source[(index - 1 + source.count) % source.count]
                let next = source[(index + 1) % source.count]
                result[index] = CGPoint(
                    x: previous.x * 0.22 + source[index].x * 0.56 + next.x * 0.22,
                    y: previous.y * 0.22 + source[index].y * 0.56 + next.y * 0.22
                )
            }
        }
        return result
    }

    private static func polygonalize(_ points: [CGPoint], closed: Bool, anchors target: Int) -> [CGPoint] {
        guard points.count > target else { return points }
        let last = closed && points.first == points.last ? points.count - 1 : points.count
        let anchorCount = max(2, min(target, last))
        let anchors = (0..<anchorCount).map { index -> Int in
            Int((Double(index) / Double(closed ? anchorCount : anchorCount - 1) * Double(closed ? last : last - 1)).rounded(.down)) % last
        }
        return points.indices.map { index in
            if closed && index == points.count - 1 { return points[0] }
            let position = Double(index) / Double(max(1, last - (closed ? 0 : 1))) * Double(closed ? anchorCount : anchorCount - 1)
            let lower = Int(floor(position)) % anchorCount
            let upper = closed ? (lower + 1) % anchorCount : min(anchorCount - 1, lower + 1)
            let t = CGFloat(position - floor(position))
            let a = points[anchors[lower]], b = points[anchors[upper]]
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
        }
    }

    private static func wave(_ points: [CGPoint], amplitude: CGFloat, seed: Int) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let phase = CGFloat(abs(seed % 360)) * .pi / 180
        return points.indices.map { index in
            let previous = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 1)]
            let dx = next.x - previous.x, dy = next.y - previous.y
            let length = max(1, hypot(dx, dy))
            let wave = sin(CGFloat(index) * 1.37 + phase) * amplitude
            return CGPoint(x: points[index].x - dy / length * wave, y: points[index].y + dx / length * wave)
        }
    }

    private static func embellish(
        _ points: [CGPoint],
        style: PortraitStyle,
        amount: CGFloat,
        scale: CGFloat,
        seed: Int
    ) -> [CGPoint] {
        guard amount > 0.001, points.count >= 2 else { return points }
        let stride = style == .ornate ? 2 : (style == .cubist ? 4 : 5)
        var result: [CGPoint] = []
        result.reserveCapacity(points.count * 2)
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            result.append(a)
            guard (index + abs(seed)) % stride == 0 else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let length = max(1, hypot(dx, dy))
            let nx = -dy / length, ny = dx / length
            let amplitude = min(length * 0.45, scale * amount * (style == .ornate ? 0.06 : 0.035))
            let midpoint = CGPoint(x: (a.x + b.x) * 0.5, y: (a.y + b.y) * 0.5)
            if style == .cubist {
                result.append(CGPoint(x: midpoint.x + nx * amplitude, y: midpoint.y + ny * amplitude))
            } else {
                result.append(CGPoint(x: midpoint.x + nx * amplitude, y: midpoint.y + ny * amplitude))
                result.append(CGPoint(x: midpoint.x - nx * amplitude * 0.75, y: midpoint.y - ny * amplitude * 0.75))
            }
        }
        if let last = points.last { result.append(last) }
        return result
    }
}
