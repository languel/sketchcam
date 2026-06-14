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
        guard let boundary = personBoundary(groups), boundary.count >= 3 else { return }

        // Heavily sample the interior — density scales the anchor count up.
        let count = max(10, min(160, Int(10 + landmarks.wrapDensity * 150)))
        let interior = Self.interiorSamples(boundary: boundary, count: count, seed: landmarks.wrapSeed)
        guard interior.count >= 2 else { return }

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
        let curve = DrawingSupport.curvePoints(coiled, fit: landmarks.wrapCurveFit)

        let stroke = DrawingSupport.stroke(for: .bodyHull, landmarks: landmarks, matchColors: landmarks.wrapMatchesLandmarkColors, palette: landmarks.wrapPalette, width: landmarks.wrapWidth)
        YarnDrawing.strokePasses(curve, closed: false, stroke: stroke, weave: 0, in: context)
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
        guard points.count > 2 else { return points }
        var remaining = points
        var order = [remaining.removeFirst()]
        while !remaining.isEmpty {
            let last = order[order.count - 1]
            var bestIndex = 0
            var bestDist = CGFloat.greatestFiniteMagnitude
            for (i, p) in remaining.enumerated() {
                let dx = p.x - last.x, dy = p.y - last.y
                let d = dx * dx + dy * dy
                if d < bestDist { bestDist = d; bestIndex = i }
            }
            order.append(remaining.remove(at: bestIndex))
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
