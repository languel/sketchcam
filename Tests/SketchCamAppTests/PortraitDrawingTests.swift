import CoreGraphics
import XCTest
@testable import SketchCam
import SketchCamCore
import SketchCamShared

final class PortraitDrawingTests: XCTestCase {
    func testPortraitStrokeGenerationPerformance() {
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitStyle = .ornate
        settings.portraitFollow = 0.72
        settings.portraitFlourish = 0.5
        let groups = portraitGroups(offset: .zero)
        let drawing = PortraitDrawing()

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<100 {
                _ = drawing.strokes(groups: groups, landmarks: settings)
            }
        }
    }

    func testPortraitCPURenderPerformance() throws {
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitStyle = .ornate
        settings.portraitFollow = 0.72
        settings.portraitFlourish = 0.5
        let groups = portraitGroups(offset: .zero)
        let drawing = PortraitDrawing()
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: 1280,
            height: 720,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ))

        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<20 {
                context.clear(CGRect(x: 0, y: 0, width: 1280, height: 720))
                drawing.render(groups: groups, landmarks: settings, into: context)
            }
        }
    }

    func testPortraitMetalRenderPerformance() throws {
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitStyle = .ornate
        settings.portraitFollow = 0.72
        settings.portraitFlourish = 0.5
        let strokes = PortraitDrawing().strokes(groups: portraitGroups(offset: .zero), landmarks: settings)
        guard let renderer = MetalLineRenderer() else {
            throw XCTSkip("Metal drawing is unavailable on this test host")
        }
        let buffer = try PixelBufferUtils.makePixelBuffer(
            format: FrameFormat(id: "portrait-performance", width: 1280, height: 720)
        )

        // Includes tessellation, reusable-buffer upload, MSAA render, and the
        // synchronization needed before the compositor consumes the image.
        measure(metrics: [XCTClockMetric()]) {
            for _ in 0..<20 {
                XCTAssertTrue(renderer.render(strokes: strokes, into: buffer))
            }
        }
    }

    func testCompoundMouthSplitsIntoStableOuterAndInnerPaths() {
        let outer = loop(center: CGPoint(x: 100, y: 100), rx: 30, ry: 12, count: 8)
        let inner = loop(center: CGPoint(x: 100, y: 100), rx: 15, ry: 5, count: 6)
        let points = outer.points + inner.points
        let edges = outer.edges + inner.edges.map { ($0.0 + outer.points.count, $0.1 + outer.points.count) }
        let group = MappedGroup(region: .mouth, points: points, edges: edges)

        let components = PortraitPathBuilder.components(group).sorted { $0.points.count > $1.points.count }

        XCTAssertEqual(components.count, 2)
        XCTAssertTrue(components.allSatisfy(\.closed))
        XCTAssertEqual(components.map { $0.points.count }, [outer.points.count + 1, inner.points.count + 1])
    }

    func testLiveLandmarkMotionMorphsStableFaceAndBodyRoutes() throws {
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitStyle = .fluid
        settings.portraitFollow = 0.8
        settings.portraitFlourish = 0.3
        let drawing = PortraitDrawing()
        let firstGroups = portraitGroups(offset: .zero)
        let movedGroups = portraitGroups(offset: CGPoint(x: 24, y: -12))

        let first = drawing.semanticRoutes(groups: firstGroups, landmarks: settings)
        let moved = drawing.semanticRoutes(groups: movedGroups, landmarks: settings)

        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(moved.map(\.count), first.map(\.count))
        let firstStart = try XCTUnwrap(first.first?.first)
        let movedStart = try XCTUnwrap(moved.first?.first)
        XCTAssertEqual(movedStart.x - firstStart.x, 24, accuracy: 0.001)
        XCTAssertEqual(movedStart.y - firstStart.y, -12, accuracy: 0.001)
    }

    func testStylesChangeExpressionWithoutChangingSemanticDestinations() throws {
        let groups = portraitGroups(offset: .zero)
        let drawing = PortraitDrawing()
        var fluid = LandmarkSettings()
        fluid.portraitEnabled = true
        fluid.portraitStyle = .fluid
        fluid.portraitFollow = 0.7
        fluid.portraitFlourish = 0.5
        var cubist = fluid
        cubist.portraitStyle = .cubist
        var ornate = fluid
        ornate.portraitStyle = .ornate

        let fluidRoute = try XCTUnwrap(drawing.semanticRoutes(groups: groups, landmarks: fluid).first)
        let cubistRoute = try XCTUnwrap(drawing.semanticRoutes(groups: groups, landmarks: cubist).first)
        let ornateRoute = try XCTUnwrap(drawing.semanticRoutes(groups: groups, landmarks: ornate).first)

        XCTAssertNotEqual(fluidRoute, cubistRoute)
        XCTAssertNotEqual(fluidRoute, ornateRoute)
        XCTAssertGreaterThan(ornateRoute.count, cubistRoute.count)
    }

    func testFollowControlsLikenessWithoutChangingRouteTopology() {
        let markers = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 20, y: 18),
            CGPoint(x: 40, y: -14),
            CGPoint(x: 60, y: 22),
            CGPoint(x: 80, y: 0),
        ]
        let idealized = PortraitPathBuilder.stylize(
            markers,
            closed: false,
            style: .fluid,
            follow: 0,
            flourish: 0,
            scale: 80,
            seed: 1
        )
        let closelyTracked = PortraitPathBuilder.stylize(
            markers,
            closed: false,
            style: .fluid,
            follow: 1,
            flourish: 0,
            scale: 80,
            seed: 1
        )

        XCTAssertEqual(idealized.count, markers.count)
        XCTAssertEqual(closelyTracked.count, markers.count)
        XCTAssertLessThan(totalDistance(closelyTracked, from: markers), totalDistance(idealized, from: markers))
    }

    func testPathologicalInputIsBoundedWithoutLosingEndpoints() {
        let points = (0..<2_000).map { index in
            CGPoint(x: CGFloat(index), y: sin(CGFloat(index) * 0.03) * 40)
        }

        let sampled = PortraitPathBuilder.uniformlySample(points, maximumCount: 320)

        XCTAssertEqual(sampled.count, 320)
        XCTAssertEqual(sampled.first, points.first)
        XCTAssertEqual(sampled.last, points.last)
    }

    func testDenseContourIsIgnoredWhenArticulatedBodyIsAvailable() {
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        let base = portraitGroups(offset: .zero)
        let denseContourPoints = (0..<2_000).map { index -> CGPoint in
            let angle = CGFloat(index) / 2_000 * .pi * 2
            return CGPoint(x: 200 + cos(angle) * 180, y: 300 + sin(angle) * 260)
        }
        let denseContour = MappedGroup(
            region: .contour,
            points: denseContourPoints,
            edges: (0..<2_000).map { ($0, ($0 + 1) % 2_000) }
        )
        let drawing = PortraitDrawing()

        let withoutContour = drawing.semanticRoutes(groups: base, landmarks: settings)
        let withContour = drawing.semanticRoutes(groups: base + [denseContour], landmarks: settings)

        XCTAssertEqual(withContour, withoutContour)
    }

    private func portraitGroups(offset: CGPoint) -> [MappedGroup] {
        func shifted(_ points: [CGPoint]) -> [CGPoint] {
            points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) }
        }
        let jaw = loop(center: CGPoint(x: 200, y: 150), rx: 80, ry: 105, count: 18)
        let mouth = loop(center: CGPoint(x: 200, y: 190), rx: 32, ry: 12, count: 10)
        let leftEye = loop(center: CGPoint(x: 168, y: 125), rx: 22, ry: 10, count: 8)
        let rightEye = loop(center: CGPoint(x: 232, y: 125), rx: 22, ry: 10, count: 8)
        let chainEdges = { (count: Int) in (0..<max(0, count - 1)).map { ($0, $0 + 1) } }
        let nose = [CGPoint(x: 200, y: 135), CGPoint(x: 190, y: 165), CGPoint(x: 208, y: 168)]
        let leftBrow = [CGPoint(x: 145, y: 105), CGPoint(x: 168, y: 98), CGPoint(x: 190, y: 106)]
        let rightBrow = [CGPoint(x: 210, y: 106), CGPoint(x: 232, y: 98), CGPoint(x: 255, y: 105)]
        let torso = [CGPoint(x: 165, y: 285), CGPoint(x: 235, y: 285), CGPoint(x: 225, y: 400), CGPoint(x: 175, y: 400)]
        let leftArm = [CGPoint(x: 165, y: 285), CGPoint(x: 125, y: 345), CGPoint(x: 105, y: 420)]
        let rightArm = [CGPoint(x: 235, y: 285), CGPoint(x: 275, y: 345), CGPoint(x: 295, y: 420)]
        let leftLeg = [CGPoint(x: 175, y: 400), CGPoint(x: 160, y: 500), CGPoint(x: 150, y: 590)]
        let rightLeg = [CGPoint(x: 225, y: 400), CGPoint(x: 240, y: 500), CGPoint(x: 250, y: 590)]

        return [
            MappedGroup(region: .jaw, points: shifted(jaw.points), edges: jaw.edges),
            MappedGroup(region: .leftBrow, points: shifted(leftBrow), edges: chainEdges(leftBrow.count)),
            MappedGroup(region: .leftEye, points: shifted(leftEye.points), edges: leftEye.edges),
            MappedGroup(region: .nose, points: shifted(nose), edges: chainEdges(nose.count)),
            MappedGroup(region: .rightEye, points: shifted(rightEye.points), edges: rightEye.edges),
            MappedGroup(region: .rightBrow, points: shifted(rightBrow), edges: chainEdges(rightBrow.count)),
            MappedGroup(region: .mouth, points: shifted(mouth.points), edges: mouth.edges),
            MappedGroup(region: .torso, points: shifted(torso), edges: [(0, 1), (1, 2), (2, 3), (3, 0)]),
            MappedGroup(region: .leftArm, points: shifted(leftArm), edges: chainEdges(leftArm.count)),
            MappedGroup(region: .rightArm, points: shifted(rightArm), edges: chainEdges(rightArm.count)),
            MappedGroup(region: .leftLeg, points: shifted(leftLeg), edges: chainEdges(leftLeg.count)),
            MappedGroup(region: .rightLeg, points: shifted(rightLeg), edges: chainEdges(rightLeg.count))
        ]
    }

    private func loop(center: CGPoint, rx: CGFloat, ry: CGFloat, count: Int) -> (points: [CGPoint], edges: [(Int, Int)]) {
        let points = (0..<count).map { index in
            let angle = CGFloat(index) / CGFloat(count) * .pi * 2
            return CGPoint(x: center.x + cos(angle) * rx, y: center.y + sin(angle) * ry)
        }
        let edges = (0..<count).map { ($0, ($0 + 1) % count) }
        return (points, edges)
    }

    private func totalDistance(_ points: [CGPoint], from reference: [CGPoint]) -> CGFloat {
        zip(points, reference).reduce(0) { distance, pair in
            distance + hypot(pair.0.x - pair.1.x, pair.0.y - pair.1.y)
        }
    }
}
