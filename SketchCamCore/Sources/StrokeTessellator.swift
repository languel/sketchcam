import CoreGraphics
import Foundation

/// Converts polyline strokes into a flat triangle-vertex buffer for the GPU.
///
/// The CPU `CGContext` stroke path (one `strokePath` per sub-segment) was the
/// pipeline's dominant cost (~54 ms/overlay). The geometry math is cheap; only
/// the rasterization belonged on the GPU. This turns each stroke into triangles
/// — variable-width quads per segment plus round discs at every vertex (caps +
/// joins) — which Metal rasterizes in well under a millisecond.
///
/// Output layout: interleaved floats, `floatsPerVertex` per vertex, as a
/// triangle list (every 3 vertices = 1 triangle). Positions are in the caller's
/// canvas pixel space; the vertex shader maps them to NDC with a viewport
/// uniform. Pure and deterministic — no Metal dependency, fully testable.
public enum StrokeTessellator {
    /// x, y, r, g, b, a.
    public static let floatsPerVertex = 6

    /// One stroke to tessellate. `points` is the already curve-sampled polyline.
    public struct Stroke: Sendable {
        public var points: [CGPoint]
        public var color: RGBAColor
        public var baseWidth: Float
        public var widthVariation: Float
        public var seed: Int

        public init(points: [CGPoint], color: RGBAColor, baseWidth: Float, widthVariation: Float = 0, seed: Int = 0) {
            self.points = points
            self.color = color
            self.baseWidth = baseWidth
            self.widthVariation = widthVariation
            self.seed = seed
        }
    }

    /// Number of triangles in the round cap/join disc at each vertex. Cheap;
    /// the GPU eats tens of thousands of these without noticing.
    private static let discSegments = 10

    public static func tessellate(_ strokes: [Stroke]) -> [Float] {
        var out: [Float] = []
        // Rough preallocation: per point ~ 1 quad (6 verts) + 1 disc.
        let pointCount = strokes.reduce(0) { $0 + $1.points.count }
        out.reserveCapacity(pointCount * (6 + discSegments * 3) * floatsPerVertex)
        for stroke in strokes {
            tessellate(stroke, into: &out)
        }
        return out
    }

    static func tessellate(_ stroke: Stroke, into out: inout [Float]) {
        let pts = stroke.points
        guard !pts.isEmpty else { return }
        let c = stroke.color
        let halfWidths = halfWidthProfile(stroke)

        // Single point → just a dot.
        if pts.count == 1 {
            appendDisc(center: pts[0], radius: halfWidths[0], color: c, into: &out)
            return
        }

        for i in 0..<(pts.count - 1) {
            appendSegmentQuad(a: pts[i], b: pts[i + 1], halfA: halfWidths[i], halfB: halfWidths[i + 1], color: c, into: &out)
        }
        // Round caps + joins so there are no gaps at turns / ends.
        for i in 0..<pts.count {
            appendDisc(center: pts[i], radius: halfWidths[i], color: c, into: &out)
        }
    }

    /// Per-point half-width: end-taper × seeded-noise swell (calligraphic),
    /// matching the look of the CPU `strokeVariableWidth`.
    static func halfWidthProfile(_ stroke: Stroke) -> [CGFloat] {
        let n = stroke.points.count
        let base = CGFloat(max(0.2, stroke.baseWidth))
        guard n > 1 else { return [base / 2] }
        var widths = [CGFloat](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / Double(n - 1)
            let taper = 0.55 + 0.45 * sin(.pi * t)
            let swell = stroke.widthVariation > 0
                ? 1 + Double(stroke.widthVariation) * LineWalk.valueNoise1D(Double(i) * 0.25, stroke.seed, 7)
                : 1
            widths[i] = max(0.1, base * CGFloat(taper * max(0.1, swell))) / 2
        }
        return widths
    }

    // MARK: - Primitives

    private static func appendSegmentQuad(a: CGPoint, b: CGPoint, halfA: CGFloat, halfB: CGFloat, color: RGBAColor, into out: inout [Float]) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(1e-5, hypot(dx, dy))
        let nx = -dy / len, ny = dx / len   // unit normal
        let a0 = CGPoint(x: a.x + nx * halfA, y: a.y + ny * halfA)
        let a1 = CGPoint(x: a.x - nx * halfA, y: a.y - ny * halfA)
        let b0 = CGPoint(x: b.x + nx * halfB, y: b.y + ny * halfB)
        let b1 = CGPoint(x: b.x - nx * halfB, y: b.y - ny * halfB)
        // two triangles: a0,a1,b0 and a1,b1,b0
        appendVertex(a0, color, &out); appendVertex(a1, color, &out); appendVertex(b0, color, &out)
        appendVertex(a1, color, &out); appendVertex(b1, color, &out); appendVertex(b0, color, &out)
    }

    private static func appendDisc(center: CGPoint, radius: CGFloat, color: RGBAColor, into out: inout [Float]) {
        guard radius > 0.05 else { return }
        let step = (2 * Double.pi) / Double(discSegments)
        for s in 0..<discSegments {
            let a0 = Double(s) * step
            let a1 = Double(s + 1) * step
            let p0 = CGPoint(x: center.x + radius * CGFloat(cos(a0)), y: center.y + radius * CGFloat(sin(a0)))
            let p1 = CGPoint(x: center.x + radius * CGFloat(cos(a1)), y: center.y + radius * CGFloat(sin(a1)))
            appendVertex(center, color, &out); appendVertex(p0, color, &out); appendVertex(p1, color, &out)
        }
    }

    private static func appendVertex(_ p: CGPoint, _ c: RGBAColor, _ out: inout [Float]) {
        out.append(Float(p.x)); out.append(Float(p.y))
        out.append(c.red); out.append(c.green); out.append(c.blue); out.append(c.alpha)
    }
}
