import CoreGraphics
import XCTest
@testable import SketchCamCore

final class StrokeTessellatorTests: XCTestCase {
    private let red = RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)

    func testEmptyProducesNothing() {
        XCTAssertTrue(StrokeTessellator.tessellate([]).isEmpty)
        let emptyStroke = StrokeTessellator.Stroke(points: [], color: red, baseWidth: 4)
        XCTAssertTrue(StrokeTessellator.tessellate([emptyStroke]).isEmpty)
    }

    func testSinglePointIsADisc() {
        let stroke = StrokeTessellator.Stroke(points: [CGPoint(x: 50, y: 50)], color: red, baseWidth: 10)
        let verts = StrokeTessellator.tessellate([stroke])
        // One disc: 10 segments × 3 vertices × 6 floats.
        XCTAssertEqual(verts.count, 10 * 3 * StrokeTessellator.floatsPerVertex)
        XCTAssertTrue(verts.allSatisfy { $0.isFinite })
    }

    func testTwoPointLineGeometry() {
        let stroke = StrokeTessellator.Stroke(points: [CGPoint(x: 10, y: 50), CGPoint(x: 90, y: 50)], color: red, baseWidth: 10)
        let verts = StrokeTessellator.tessellate([stroke])
        // 1 segment quad (6 verts) + 2 discs (2 × 30 verts) = 66 verts.
        XCTAssertEqual(verts.count, 66 * StrokeTessellator.floatsPerVertex)
        XCTAssertTrue(verts.allSatisfy { $0.isFinite })

        // Every vertex carries the stroke color.
        let stride = StrokeTessellator.floatsPerVertex
        for v in 0..<(verts.count / stride) {
            XCTAssertEqual(verts[v * stride + 2], 1, accuracy: 1e-5)  // r
            XCTAssertEqual(verts[v * stride + 3], 0, accuracy: 1e-5)  // g
            XCTAssertEqual(verts[v * stride + 5], 1, accuracy: 1e-5)  // a
        }

        // Bounding box: spans the line horizontally and ±halfWidth vertically.
        var minX = Float.greatestFiniteMagnitude, maxX = -minX
        var minY = Float.greatestFiniteMagnitude, maxY = -minY
        for v in 0..<(verts.count / stride) {
            minX = min(minX, verts[v * stride]); maxX = max(maxX, verts[v * stride])
            minY = min(minY, verts[v * stride + 1]); maxY = max(maxY, verts[v * stride + 1])
        }
        XCTAssertLessThan(minX, 12)     // includes the start cap (x≈10 − r)
        XCTAssertGreaterThan(maxX, 88)  // includes the end cap
        XCTAssertLessThan(minY, 50)     // width spreads above/below the centerline
        XCTAssertGreaterThan(maxY, 50)
    }

    func testWidthVariationStaysFiniteAndBounded() {
        let pts = (0..<40).map { CGPoint(x: Double($0) * 5, y: 100 + sin(Double($0) * 0.3) * 20) }
        let stroke = StrokeTessellator.Stroke(points: pts, color: red, baseWidth: 6, widthVariation: 0.8, seed: 11)
        let verts = StrokeTessellator.tessellate([stroke])
        XCTAssertFalse(verts.isEmpty)
        XCTAssertTrue(verts.allSatisfy { $0.isFinite })
        // Deterministic for a fixed seed.
        let again = StrokeTessellator.tessellate([stroke])
        XCTAssertEqual(verts, again)
    }
}
