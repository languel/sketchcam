import CoreGraphics
import Foundation

/// Pure geometry for pen strokes: jitter removal + a smooth Catmull-Rom path.
/// No rendering — the app layer strokes the returned `CGPath` with Core Graphics.
public enum PenStrokeGeometry {
    /// Iterated binomial [0.25, 0.5, 0.25] low-pass that removes input jitter while
    /// fixing the endpoints. Keeps the overall shape; just de-noises the samples.
    public static func lowPass(_ points: [CGPoint], passes: Int) -> [CGPoint] {
        guard points.count > 2, passes > 0 else { return points }
        var pts = points
        for _ in 0..<passes {
            var next = pts
            for i in 1..<(pts.count - 1) {
                next[i] = CGPoint(x: pts[i - 1].x * 0.25 + pts[i].x * 0.5 + pts[i + 1].x * 0.25,
                                  y: pts[i - 1].y * 0.25 + pts[i].y * 0.5 + pts[i + 1].y * 0.25)
            }
            pts = next
        }
        return pts
    }

    /// A smooth C1 curve THROUGH the points as a `CGPath`, using the standard
    /// Catmull-Rom → cubic-Bézier conversion (control points from neighbour
    /// tangents). Core Graphics rasterizes the Béziers with analytic AA, so the
    /// stroke is crisp at any width/zoom — no tessellation scallop, no SDF
    /// under-sampling.
    public static func smoothPath(_ points: [CGPoint]) -> CGPath? {
        let n = points.count
        guard n > 1 else { return nil }
        let path = CGMutablePath()
        if n == 2 {
            path.move(to: points[0])
            path.addLine(to: points[1])
            return path
        }
        func pt(_ i: Int) -> CGPoint { points[min(max(i, 0), n - 1)] }
        path.move(to: points[0])
        for i in 0..<(n - 1) {
            let p0 = pt(i - 1), p1 = pt(i), p2 = pt(i + 1), p3 = pt(i + 2)
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }

    /// Total arc length of a polyline — handy for tests / decimation.
    public static func length(_ points: [CGPoint]) -> CGFloat {
        guard points.count > 1 else { return 0 }
        var total: CGFloat = 0
        for i in 1..<points.count {
            total += hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
        }
        return total
    }
}
