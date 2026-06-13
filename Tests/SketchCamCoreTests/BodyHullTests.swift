import CoreGraphics
import XCTest
@testable import SketchCamCore

final class BodyHullTests: XCTestCase {
    func testHullOfSquareWithInteriorPoints() {
        let points = [
            CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0),
            CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10),
            CGPoint(x: 5, y: 5), CGPoint(x: 3, y: 7)   // interior — must be excluded
        ]
        let hull = BodyHull.convexHull(points)
        XCTAssertEqual(hull.count, 4)
        // All four corners present.
        for corner in [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10)] {
            XCTAssertTrue(hull.contains { abs($0.x - corner.x) < 1e-6 && abs($0.y - corner.y) < 1e-6 })
        }
    }

    func testDegenerateInputsReturnedAsIs() {
        XCTAssertTrue(BodyHull.convexHull([]).isEmpty)
        let two = [CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2)]
        XCTAssertEqual(BodyHull.convexHull(two).count, 2)
    }

    func testHullIsConvexLoop() {
        // Random-ish cloud → hull vertices should all lie on the boundary.
        let pts: [CGPoint] = (0..<50).map { i in
            let x = Double((i * 37) % 100)
            let y = Double((i * 53) % 100)
            return CGPoint(x: x, y: y)
        }
        let hull = BodyHull.convexHull(pts)
        XCTAssertGreaterThanOrEqual(hull.count, 3)
        // Convexity: every consecutive turn has the same sign (CCW ⇒ ≥ 0).
        func cross(_ o: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let ax: CGFloat = a.x - o.x
            let ay: CGFloat = a.y - o.y
            let bx: CGFloat = b.x - o.x
            let by: CGFloat = b.y - o.y
            return ax * by - ay * bx
        }
        let n = hull.count
        for i in 0..<n {
            let c = cross(hull[i], hull[(i + 1) % n], hull[(i + 2) % n])
            XCTAssertGreaterThanOrEqual(c, -1e-6)
        }
    }
}
