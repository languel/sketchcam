import AppKit
import CoreGraphics
import Foundation
import SketchCamCore

/// Wrap: a continuous yarn-wire that winds through the INSIDE of the person.
/// Points are sampled densely within the silhouette (so the figure stays
/// legible), ordered by proximity into one meandering wire, then given
/// LineWalk-style path variation (wildness along/orthogonal × scale) plus
/// optional coil/winding loops. Unlike the old wrap it does NOT clip to the
/// silhouette — it's anchored inside but free to spill out a little, like
/// Gormley's wire figures.
struct WrapDrawing: DrawingAlgorithm {
    func isEnabled(_ landmarks: LandmarkSettings) -> Bool { landmarks.wrapEnabled }

    func render(groups: [MappedGroup], landmarks: LandmarkSettings, into context: CGContext) {
        for stroke in strokes(groups: groups, landmarks: landmarks) {
            DrawingSupport.renderStroke(stroke, bead: landmarks.beadStroke, into: context)
        }
    }

    func strokes(groups: [MappedGroup], landmarks: LandmarkSettings) -> [StrokeTessellator.Stroke] {
        guard let wire = wireCurve(groups: groups, landmarks: landmarks) else { return [] }
        let stroke = DrawingSupport.stroke(for: .bodyHull, landmarks: landmarks, matchColors: landmarks.wrapMatchesLandmarkColors, palette: landmarks.wrapPalette, width: landmarks.wrapWidth)
        let seed = landmarks.wrapSeed + DrawingSupport.seedOffset(for: .bodyHull)
        return DrawingSupport.ribbonStrokes(wire, color: stroke.color, baseWidth: stroke.width, widthVariation: landmarks.wrapWidthVariation, halo: landmarks.wrapHalo, seed: seed)
    }

    /// The wrap wire as a single curve-sampled polyline (shared by the CPU and
    /// GPU renderers): heavy interior sampling → proximity order → LineWalk
    /// perturbation → coil/winding loops → curve fit.
    private func wireCurve(groups: [MappedGroup], landmarks: LandmarkSettings) -> [CGPoint]? {
        guard let boundary = personBoundary(groups), boundary.count >= 3 else { return nil }

        // Heavily sample the interior — density scales the anchor count up.
        let count = max(10, min(160, Int(10 + landmarks.wrapDensity * 150)))
        let interior = Self.interiorSamples(boundary: boundary, count: count, seed: landmarks.wrapSeed)
        guard interior.count >= 2 else { return nil }

        let seed = landmarks.wrapSeed + DrawingSupport.seedOffset(for: .bodyHull)
        // Proximity order → short segments that stay near the body.
        let ordered = Self.nearestNeighborOrder(interior)

        // LineWalk path variation (reuses the exact same perturbation).
        let vertices = ordered.map { LineWalk.Vertex(point: $0, featureIndex: 0, tag: 0) }
        let perturbed = LineWalk.perturb(
            vertices,
            along: landmarks.wrapWildnessAlong,
            ortho: landmarks.wrapWildnessOrtho,
            scale: landmarks.wrapScale,
            seed: seed
        ).map(\.point)

        // Coil/winding loops on top (no-op when circular ~0).
        let coiled = LandmarkYarnWeaver.coilPath(
            perturbed, linear: 0, circular: landmarks.wrapCircular,
            winding: landmarks.wrapWinding, seed: seed, closed: false
        )
        return DrawingSupport.curvePoints(coiled, fit: landmarks.wrapCurveFit, samplesPerSegment: 4)
    }

    /// The figure boundary used only to sample interior points (not to clip):
    /// Person silhouette → Hull → on-the-fly convex hull of all landmarks.
    private func personBoundary(_ groups: [MappedGroup]) -> [CGPoint]? {
        if let contour = groups.first(where: { $0.region == .contour }), contour.points.count >= 3 {
            return contour.points
        }
        if let hull = groups.first(where: { $0.region == .bodyHull }), hull.points.count >= 3 {
            return hull.points
        }
        let hull = BodyHull.convexHull(groups.flatMap { $0.points })
        return hull.count >= 3 ? hull : nil
    }

    // MARK: - Geometry

    /// Greedy nearest-neighbour ordering so consecutive points are close.
    static func nearestNeighborOrder(_ points: [CGPoint]) -> [CGPoint] {
        nearestNeighborIndices(points).map { points[$0] }
    }

    /// Original indices let callers find a route in a stable reference space,
    /// then deform those same samples with live landmarks without rewiring it.
    static func nearestNeighborIndices(_ points: [CGPoint]) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        // Preserve the original greedy route (including original-index tie
        // breaking), but skip exhausted spatial subtrees instead of scanning
        // every remaining point and shifting an Array on each step. Dense
        // portrait hair can contain thousands of samples per detection.
        var index = NearestNeighborIndex(points: points)
        var order: [Int] = []
        order.reserveCapacity(points.count)
        var current = 0
        index.remove(current)
        order.append(current)
        while let next = index.nearest(to: points[current]) {
            current = next
            index.remove(current)
            order.append(current)
        }
        return order
    }

    /// Seeded rejection sampling of points inside the boundary polygon.
    static func interiorSamples(boundary: [CGPoint], count: Int, seed: Int) -> [CGPoint] {
        var minX = boundary[0].x, maxX = boundary[0].x, minY = boundary[0].y, maxY = boundary[0].y
        for p in boundary {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        var rng = WrapRNG(seed: seed)
        var out: [CGPoint] = []
        var attempts = 0
        let maxAttempts = count * 40
        while out.count < count, attempts < maxAttempts {
            attempts += 1
            let p = CGPoint(x: minX + rng.unit() * (maxX - minX), y: minY + rng.unit() * (maxY - minY))
            if pointInPolygon(p, boundary) { out.append(p) }
        }
        return out
    }

    static func pointInPolygon(_ p: CGPoint, _ poly: [CGPoint]) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in 0..<poly.count {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y) {
                let xCross = a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x)
                if p.x < xCross { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

private struct NearestNeighborIndex {
    private struct Node {
        var pointIndex: Int
        var axis: Int
        var parent: Int?
        var left: Int?
        var right: Int?
        var remaining: Int
    }

    private let points: [CGPoint]
    private var nodes: [Node] = []
    private var nodeForPoint: [Int]
    private var removed: [Bool]
    private var root: Int?

    init(points: [CGPoint]) {
        self.points = points
        nodeForPoint = Array(repeating: 0, count: points.count)
        removed = Array(repeating: false, count: points.count)
        root = nil
        nodes.reserveCapacity(points.count)
        root = build(Array(points.indices), depth: 0, parent: nil)
    }

    private mutating func build(_ indices: [Int], depth: Int, parent: Int?) -> Int? {
        guard !indices.isEmpty else { return nil }
        let axis = depth & 1
        let sorted = indices.sorted { lhs, rhs in
            let a = axis == 0 ? points[lhs].x : points[lhs].y
            let b = axis == 0 ? points[rhs].x : points[rhs].y
            return a == b ? lhs < rhs : a < b
        }
        let middle = sorted.count / 2
        let slot = nodes.count
        let pointIndex = sorted[middle]
        nodeForPoint[pointIndex] = slot
        nodes.append(Node(pointIndex: pointIndex, axis: axis, parent: parent,
                          left: nil, right: nil, remaining: indices.count))
        nodes[slot].left = build(Array(sorted[..<middle]), depth: depth + 1, parent: slot)
        nodes[slot].right = build(Array(sorted[(middle + 1)...]), depth: depth + 1, parent: slot)
        return slot
    }

    mutating func remove(_ pointIndex: Int) {
        guard !removed[pointIndex] else { return }
        removed[pointIndex] = true
        var slot: Int? = nodeForPoint[pointIndex]
        while let current = slot {
            nodes[current].remaining -= 1
            slot = nodes[current].parent
        }
    }

    func nearest(to point: CGPoint) -> Int? {
        var bestIndex: Int?
        var bestDistance = CGFloat.greatestFiniteMagnitude

        func search(_ slot: Int?) {
            guard let slot, nodes[slot].remaining > 0 else { return }
            let node = nodes[slot]
            let candidate = points[node.pointIndex]
            let dx = candidate.x - point.x
            let dy = candidate.y - point.y
            let distance = dx * dx + dy * dy
            if !removed[node.pointIndex],
               distance < bestDistance || (distance == bestDistance && node.pointIndex < (bestIndex ?? Int.max)) {
                bestDistance = distance
                bestIndex = node.pointIndex
            }
            let splitDelta = node.axis == 0 ? point.x - candidate.x : point.y - candidate.y
            let near = splitDelta < 0 ? node.left : node.right
            let far = splitDelta < 0 ? node.right : node.left
            search(near)
            if splitDelta * splitDelta <= bestDistance { search(far) }
        }

        search(root)
        return bestIndex
    }
}

/// Small deterministic RNG for wrap interior sampling.
private struct WrapRNG {
    private var state: UInt64
    init(seed: Int) { state = UInt64(bitPattern: Int64(seed)) &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> CGFloat { CGFloat(next() >> 11) * CGFloat(1.0 / 9_007_199_254_740_992.0) }
}
