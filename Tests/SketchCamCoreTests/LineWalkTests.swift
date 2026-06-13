import CoreGraphics
import XCTest
@testable import SketchCamCore

/// Unit + throughput guards for the LineWalk path-planning geometry.
final class LineWalkTests: XCTestCase {

    // MARK: - Fixtures

    private func loop(tag: Int, center: CGPoint, radius: CGFloat, count: Int) -> LineWalk.Shape {
        let points = (0..<count).map { i -> CGPoint in
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi
            return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius * 0.8)
        }
        var edges = (0..<(count - 1)).map { ($0, $0 + 1) }
        edges.append((count - 1, 0))
        return LineWalk.Shape(points: points, edges: edges, tag: tag)
    }

    private func chain(tag: Int, from: CGPoint, to: CGPoint, count: Int) -> LineWalk.Shape {
        let points = (0..<count).map { i -> CGPoint in
            let t = CGFloat(i) / CGFloat(count - 1)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t + sin(t * .pi) * 10)
        }
        let edges = (0..<(count - 1)).map { ($0, $0 + 1) }
        return LineWalk.Shape(points: points, edges: edges, tag: tag)
    }

    private func skeleton(tag: Int) -> LineWalk.Shape {
        let points = [
            CGPoint(x: 100, y: 300), CGPoint(x: 100, y: 250),
            CGPoint(x: 60, y: 240), CGPoint(x: 140, y: 240),
            CGPoint(x: 100, y: 160), CGPoint(x: 70, y: 90), CGPoint(x: 130, y: 90)
        ]
        let edges = [(0, 1), (1, 2), (1, 3), (1, 4), (4, 5), (4, 6)]
        return LineWalk.Shape(points: points, edges: edges, tag: tag)
    }

    private func sampleShapes() -> [LineWalk.Shape] {
        [
            loop(tag: 0, center: CGPoint(x: 200, y: 400), radius: 60, count: 16),
            loop(tag: 1, center: CGPoint(x: 180, y: 420), radius: 14, count: 10),
            loop(tag: 1, center: CGPoint(x: 220, y: 420), radius: 14, count: 10),
            chain(tag: 0, from: CGPoint(x: 160, y: 450), to: CGPoint(x: 200, y: 450), count: 6),
            skeleton(tag: 2),
            LineWalk.Shape(points: [CGPoint(x: 180, y: 420)], edges: [], tag: 1)
        ]
    }

    private func build(
        _ shapes: [LineWalk.Shape],
        density: Float = 0.6,
        continuity: Float = 1,
        along: Float = 0,
        ortho: Float = 0,
        scale: Float = 0.5,
        seed: Int = 7
    ) -> [[LineWalk.Vertex]] {
        LineWalk.build(shapes: shapes, density: density, continuity: continuity,
                       wildnessAlong: along, wildnessOrtho: ortho, scale: scale, seed: seed)
    }

    private func vertexCount(_ paths: [[LineWalk.Vertex]]) -> Int { paths.reduce(0) { $0 + $1.count } }

    // MARK: - Determinism

    func testDeterministicForSameSeed() {
        let shapes = sampleShapes()
        let a = build(shapes, continuity: 0.6, along: 0.3, ortho: 0.4, seed: 42)
        let b = build(shapes, continuity: 0.6, along: 0.3, ortho: 0.4, seed: 42)
        XCTAssertEqual(a, b)
        XCTAssertFalse(a.isEmpty)
    }

    func testDifferentSeedsDiffer() {
        let shapes = sampleShapes()
        let a = build(shapes, continuity: 0.5, ortho: 0.5, seed: 1)
        let b = build(shapes, continuity: 0.5, ortho: 0.5, seed: 999)
        XCTAssertNotEqual(a, b)
    }

    // MARK: - Continuity → number of paths

    func testContinuityDrivesPathCount() {
        let shapes = sampleShapes()
        let one = build(shapes, continuity: 1.0).count
        let some = build(shapes, continuity: 0.5).count
        let many = build(shapes, continuity: 0.0).count
        XCTAssertEqual(one, 1, "continuity 1 must be a single continuous line")
        XCTAssertGreaterThan(some, one)
        XCTAssertGreaterThan(many, some)
    }

    // MARK: - Continuity = 1, no wildness ⇒ one ordered line

    func testUnicursalProducesSingleContinuousLine() {
        let paths = build(sampleShapes(), continuity: 1, along: 0, ortho: 0)
        XCTAssertEqual(paths.count, 1)
        let vertices = paths[0]
        XCTAssertGreaterThan(vertices.count, 2)
        var expected = 0
        for v in vertices {
            XCTAssertTrue(v.featureIndex == expected || v.featureIndex == expected + 1)
            expected = v.featureIndex
        }
    }

    func testEmptyInput() {
        XCTAssertTrue(build([]).isEmpty)
    }

    // MARK: - Perturbation

    func testZeroWildnessIsUnperturbed() {
        let shapes = sampleShapes()
        let calm = build(shapes, continuity: 1, along: 0, ortho: 0, seed: 3)
        // Zero wildness must not resample/displace — identical to the plain tour.
        let again = build(shapes, continuity: 1, along: 0, ortho: 0, seed: 3)
        XCTAssertEqual(calm, again)
    }

    func testWildnessChangesGeometryDeterministically() {
        let shapes = sampleShapes()
        let calm = build(shapes, continuity: 1, along: 0, ortho: 0, seed: 5)
        let wild = build(shapes, continuity: 1, along: 0.5, ortho: 0.7, seed: 5)
        XCTAssertNotEqual(calm, wild, "wildness must perturb the geometry")
        let wildAgain = build(shapes, continuity: 1, along: 0.5, ortho: 0.7, seed: 5)
        XCTAssertEqual(wild, wildAgain, "perturbation must be deterministic")
    }

    // MARK: - Density morph

    func testDensityIsMonotonic() {
        let shapes = sampleShapes()
        let sparse = vertexCount(build(shapes, density: 0.3, continuity: 1, seed: 5))
        let mid = vertexCount(build(shapes, density: 0.7, continuity: 1, seed: 5))
        let dense = vertexCount(build(shapes, density: 1.0, continuity: 1, seed: 5))
        XCTAssertLessThanOrEqual(sparse, mid)
        XCTAssertLessThanOrEqual(mid, dense)
        XCTAssertGreaterThan(dense, sparse)
    }

    // MARK: - Stability under motion

    func testTourStableUnderSmallJitter() {
        let shapes = sampleShapes()
        let jittered = shapes.map { shape in
            LineWalk.Shape(
                points: shape.points.map { CGPoint(x: $0.x + 0.4, y: $0.y - 0.3) },
                edges: shape.edges,
                tag: shape.tag
            )
        }
        let a = build(shapes, continuity: 0.6, seed: 11)
        let b = build(jittered, continuity: 0.6, seed: 11)
        XCTAssertEqual(a.count, b.count)
        XCTAssertEqual(a.flatMap { $0.map(\.tag) }, b.flatMap { $0.map(\.tag) })
    }

    // MARK: - Throughput

    func testBuildThroughput() {
        let shapes = sampleShapes()
        let iterations = 2_000
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<iterations {
            _ = build(shapes, density: 0.8, continuity: 0.5, along: 0.4, ortho: 0.5, seed: i)
        }
        let perCall = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations) * 1_000
        let line = String(format: "linewalk build (6 features, density 0.8, perturbed): %.3f ms/call", perCall)
        print(line)
        let url = URL(fileURLWithPath: "/tmp/sketchcam-perf.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertLessThan(perCall, 2.0)
    }
}
