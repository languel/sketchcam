import CoreGraphics
import Foundation

/// Seg-free person outline: the convex hull of the detected landmarks. Gives a
/// rough enclosing contour around the person with NO segmentation cost — cruder
/// than the Vision silhouette (it can't enter concavities like between the legs)
/// but free and stable. Pure geometry; deterministic.
public enum BodyHull {
    /// Andrew's monotone-chain convex hull, returned as an ordered loop
    /// (counter-clockwise). Fewer than 3 input points are returned as-is.
    public static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let pts = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
        guard pts.count >= 3 else { return pts }

        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }

        var lower: [CGPoint] = []
        for p in pts {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 {
                lower.removeLast()
            }
            lower.append(p)
        }
        var upper: [CGPoint] = []
        for p in pts.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 {
                upper.removeLast()
            }
            upper.append(p)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }
}
