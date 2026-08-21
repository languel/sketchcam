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

    func testPortraitSeedIsDeterministicButChangesTheLook() throws {
        let groups = portraitGroups(offset: .zero)
        let drawing = PortraitDrawing()
        var firstSettings = LandmarkSettings()
        firstSettings.portraitEnabled = true
        firstSettings.portraitStyle = .ornate
        firstSettings.portraitFlourish = 0.65
        firstSettings.portraitVariation = 0.8
        firstSettings.portraitSeed = 17
        var secondSettings = firstSettings
        secondSettings.portraitSeed = 18

        let first = drawing.semanticRoutes(groups: groups, landmarks: firstSettings)
        let repeatFirst = drawing.semanticRoutes(groups: groups, landmarks: firstSettings)
        let second = drawing.semanticRoutes(groups: groups, landmarks: secondSettings)

        XCTAssertEqual(first, repeatFirst)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.count, second.count)
        XCTAssertTrue(second.allSatisfy { $0.count >= 2 })
    }

    func testPortraitSeedExploresItineraryAndSampleSubset() {
        let groups = portraitGroups(offset: .zero)
        let faceRegions: Set<LandmarkRegion> = [
            .jaw, .nose, .mouth, .leftBrow, .rightBrow, .leftEye, .rightEye
        ]
        let features = groups
            .filter { faceRegions.contains($0.region) }
            .flatMap(PortraitPathBuilder.components)

        let itineraries = (0..<24).map { seed in
            PortraitPathBuilder.faceItinerary(features, variation: 0.8, seed: seed)
                .map(\.region.rawValue)
                .joined(separator: ">")
        }
        XCTAssertGreaterThan(Set(itineraries).count, 1)

        let source = (0..<24).map { CGPoint(x: CGFloat($0), y: sin(CGFloat($0) * 0.2)) }
        let samples = (0..<24).map { seed in
            PortraitPathBuilder.sampledLandmarks(source, closed: false, variation: 0.75, seed: seed)
        }
        XCTAssertGreaterThan(Set(samples.map { $0.map { "\($0.x),\($0.y)" }.joined(separator: ";") }).count, 1)
        XCTAssertTrue(samples.allSatisfy { route in
            guard let first = route.first, let last = route.last else { return false }
            return (first == source.first && last == source.last) || (first == source.last && last == source.first)
        })
    }

    func testPortraitHairUsesFaceOnlyAndSupportsACompactWildWeave() throws {
        let face = MappedGroup(
            region: .jaw,
            points: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 100), CGPoint(x: 150, y: 260)],
            edges: [(0, 1), (1, 2)]
        )
        let hands = MappedGroup(
            region: .hands,
            points: [CGPoint(x: -900, y: 900), CGPoint(x: 900, y: 900)],
            edges: [(0, 1)]
        )
        let clean = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [face, hands], style: .clean, amount: 0.4, seed: 1))
        let wild = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [face, hands], style: .wild, amount: 0.9, seed: 1))

        XCTAssertEqual(clean.points.count, 9)
        XCTAssertEqual(wild.points.count, 19)
        XCTAssertGreaterThan(clean.points.map(\.x).min()!, 90)
        XCTAssertLessThan(clean.points.map(\.x).max()!, 210)
        XCTAssertLessThan(clean.points.map(\.y).max()!, 500)
        XCTAssertNotEqual(clean.points, wild.points)
        XCTAssertLessThan(
            wild.points.map(\.y).max()! - wild.points.map(\.y).min()!,
            130,
            "The wild crown should fill a shallow scalp cap, not form a cone."
        )
    }

    func testPortraitHairRotatesWithFaceBrowAxis() throws {
        let base = portraitGroups(offset: .zero).filter {
            [.jaw, .nose, .mouth, .leftBrow, .rightBrow, .leftEye, .rightEye].contains($0.region)
        }
        let center = CGPoint(x: 200, y: 150)
        let angle: CGFloat = .pi / 5
        func rotate(_ point: CGPoint) -> CGPoint {
            let x = point.x - center.x
            let y = point.y - center.y
            return CGPoint(
                x: center.x + x * cos(angle) - y * sin(angle),
                y: center.y + x * sin(angle) + y * cos(angle)
            )
        }
        let rotated = base.map { group in
            MappedGroup(region: group.region, points: group.points.map(rotate), edges: group.edges, labels: group.labels)
        }

        let originalHair = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: base, style: .wild, amount: 0.65, seed: 17))
        let rotatedHair = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: rotated, style: .wild, amount: 0.65, seed: 17))

        XCTAssertEqual(originalHair.points.count, rotatedHair.points.count)
        for (original, actual) in zip(originalHair.points, rotatedHair.points) {
            let expected = rotate(original)
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.001)
        }
    }

    func testPortraitSegmentsKeepSameRegionComponentsTogether() {
        let outer = loop(center: CGPoint(x: 100, y: 100), rx: 30, ry: 12, count: 8)
        let inner = loop(center: CGPoint(x: 100, y: 100), rx: 15, ry: 5, count: 6)
        let mouth = MappedGroup(
            region: .mouth,
            points: outer.points + inner.points,
            edges: outer.edges + inner.edges.map { ($0.0 + outer.points.count, $0.1 + outer.points.count) }
        )
        let brow = MappedGroup(
            region: .leftBrow,
            points: [CGPoint(x: 55, y: 80), CGPoint(x: 100, y: 70), CGPoint(x: 145, y: 80)],
            edges: [(0, 1), (1, 2)]
        )
        let nose = MappedGroup(
            region: .nose,
            points: [CGPoint(x: 100, y: 80), CGPoint(x: 95, y: 115), CGPoint(x: 105, y: 120)],
            edges: [(0, 1), (1, 2)]
        )
        let features = [brow, nose, mouth].flatMap(PortraitPathBuilder.components)
        let segments = PortraitPathBuilder.segmentFeatures(features, count: 3, seed: 42)

        XCTAssertEqual(segments.count, 3)
        let mouthSegments = segments.filter { $0.contains { $0.region == .mouth } }
        XCTAssertEqual(mouthSegments.count, 1)
        XCTAssertEqual(mouthSegments[0].filter { $0.region == .mouth }.count, 2)
    }

    func testPortraitConnectorWidthCreatesLighterCrossPartStrokes() {
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitWidth = 4
        settings.portraitWidthVariation = 0
        settings.portraitConnectorWidth = 0.2
        settings.portraitSegments = 1
        let strokes = PortraitDrawing().strokes(groups: portraitGroups(offset: .zero), landmarks: settings)
        let widths = strokes.map(\.baseWidth)

        XCTAssertGreaterThan(widths.count, 3)
        XCTAssertLessThan(widths.min()!, widths.max()!)
        XCTAssertEqual(widths.max()!, 4, accuracy: 0.001)
    }

    func testPortraitCanAddASeparateBodyOutlineRoute() {
        let groups = portraitGroups(offset: .zero)
        let drawing = PortraitDrawing()
        var disabled = LandmarkSettings()
        disabled.portraitEnabled = true
        disabled.portraitOutlineEnabled = false
        var enabled = disabled
        enabled.portraitOutlineEnabled = true
        enabled.portraitVariation = 0

        let withoutOutline = drawing.semanticRoutes(groups: groups, landmarks: disabled)
        let withOutline = drawing.semanticRoutes(groups: groups, landmarks: enabled)

        XCTAssertEqual(withoutOutline.count, 2)
        XCTAssertEqual(withOutline.count, 3)
        XCTAssertGreaterThan(withOutline[2].count, 2)
    }

    func testPortraitUnifiedRouteConnectsFaceBodyAndOutline() {
        let groups = portraitGroups(offset: .zero)
        let drawing = PortraitDrawing()
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitUnifiedRoute = true
        settings.portraitOutlineEnabled = true
        settings.portraitRouteVariation = 0.35

        let routes = drawing.semanticRoutes(groups: groups, landmarks: settings)

        XCTAssertEqual(routes.count, 1)
        XCTAssertGreaterThan(routes[0].count, 20)
        XCTAssertGreaterThan(routes[0].map(\.y).max() ?? 0, 500, "The unified route should reach the articulated body/outline")
    }

    func testPortraitDetailPriorityChangesUnifiedItinerary() {
        let groups = portraitGroups(offset: .zero)
        let faceRegions: Set<LandmarkRegion> = [
            .jaw, .nose, .mouth, .leftBrow, .rightBrow, .leftEye, .rightEye
        ]
        let face = groups
            .filter { faceRegions.contains($0.region) }
            .flatMap(PortraitPathBuilder.components)
        let body = groups
            .filter { PortraitPathBuilder.isArticulatedBodyRegion($0.region) }
            .flatMap(PortraitPathBuilder.components)
        let outline = PortraitPathBuilder.outlineComponent(from: groups)

        let geometric = PortraitPathBuilder.unifiedItinerary(
            face: face,
            body: body,
            outline: outline,
            variation: 0,
            detailPriority: 0,
            seed: 23
        )
        let detailFirst = PortraitPathBuilder.unifiedItinerary(
            face: face,
            body: body,
            outline: outline,
            variation: 0,
            detailPriority: 1,
            seed: 23
        )

        XCTAssertNotEqual(geometric.map(\.region), detailFirst.map(\.region))
        let highValue: Set<LandmarkRegion> = [.leftEye, .rightEye, .nose, .mouth]
        XCTAssertGreaterThanOrEqual(detailFirst.prefix(4).filter { highValue.contains($0.region) }.count, 2)
    }

    func testPortraitSubsampleIsSeededAndKeepsOpenEndpoints() {
        let source = (0..<40).map { CGPoint(x: CGFloat($0), y: sin(CGFloat($0) * 0.2)) }
        let sparse = PortraitPathBuilder.sampledLandmarks(
            source,
            closed: false,
            variation: 0,
            subsample: 0.3,
            seed: 19
        )
        let repeatSparse = PortraitPathBuilder.sampledLandmarks(
            source,
            closed: false,
            variation: 0,
            subsample: 0.3,
            seed: 19
        )

        XCTAssertEqual(sparse, repeatSparse)
        XCTAssertLessThan(sparse.count, source.count)
        XCTAssertEqual(sparse.first, source.first)
        XCTAssertEqual(sparse.last, source.last)
    }

    func testPortraitPromotesIsolatedPupilAndVariesNoseSelection() {
        let eye = loop(center: CGPoint(x: 100, y: 100), rx: 24, ry: 10, count: 8)
        let points = eye.points + [CGPoint(x: 100, y: 100)]
        let edges = eye.edges
        let group = MappedGroup(
            region: .leftEye,
            points: points,
            edges: edges,
            labels: Array(repeating: nil, count: eye.points.count) + ["pL"]
        )

        let components = PortraitPathBuilder.components(group)
        XCTAssertEqual(components.filter { $0.isPupil }.count, 1)
        XCTAssertGreaterThanOrEqual(components.first(where: { $0.isPupil })?.points.count ?? 0, 4)

        let nose = [
            CGPoint(x: 100, y: 50), CGPoint(x: 94, y: 70),
            CGPoint(x: 106, y: 82), CGPoint(x: 98, y: 92), CGPoint(x: 100, y: 105)
        ]
        let first = PortraitPathBuilder.noseVariant(nose, closed: false, seed: 1)
        let second = PortraitPathBuilder.noseVariant(nose, closed: false, seed: 2)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.first, nose.first)
        XCTAssertEqual(first.last, nose.last)
    }

    func testUnifiedPortraitRendersPreparedSourceAsOneStroke() {
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitUnifiedRoute = true
        settings.portraitOutlineEnabled = true
        settings.portraitSubsample = 0.55
        settings.portraitRouteVariation = 1

        let strokes = PortraitDrawing().strokes(groups: portraitGroups(offset: .zero), landmarks: settings)

        XCTAssertEqual(strokes.count, 1, "Unified mode should render the prepared face/body/outline route as one stroke")
    }

    func testPortraitOutlinePrefersTheDetailedContourLine() throws {
        let contourPoints = [
            CGPoint(x: 120, y: 80), CGPoint(x: 220, y: 80), CGPoint(x: 250, y: 150),
            CGPoint(x: 220, y: 220), CGPoint(x: 190, y: 180), CGPoint(x: 160, y: 220),
            CGPoint(x: 90, y: 150)
        ]
        let contour = MappedGroup(
            region: .contour,
            points: contourPoints,
            edges: (0..<contourPoints.count).map { ($0, ($0 + 1) % contourPoints.count) }
        )
        let hull = MappedGroup(
            region: .bodyHull,
            points: [CGPoint(x: 60, y: 60), CGPoint(x: 280, y: 60), CGPoint(x: 280, y: 240), CGPoint(x: 60, y: 240)],
            edges: [(0, 1), (1, 2), (2, 3), (3, 0)]
        )

        let outline = try XCTUnwrap(PortraitPathBuilder.outlineComponent(from: [hull, contour]))

        XCTAssertEqual(outline.region, .contour)
        XCTAssertTrue(outline.closed)
        XCTAssertEqual(outline.points.first, contourPoints.first)
        XCTAssertEqual(outline.points.last, contourPoints.first)
        XCTAssertTrue(outline.points.contains(CGPoint(x: 190, y: 180)), "Concavities must survive as line detail")
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

    func testHandRouteFollowsAnatomicalLabelsWhenMirroredAndObservationOrderFlips() {
        let leftArm = MappedGroup(
            region: .leftArm,
            points: [CGPoint(x: 0.76, y: 0.3), CGPoint(x: 0.86, y: 0.45)],
            edges: [(0, 1)]
        )
        let rightArm = MappedGroup(
            region: .rightArm,
            points: [CGPoint(x: 0.24, y: 0.3), CGPoint(x: 0.14, y: 0.45)],
            edges: [(0, 1)]
        )
        // These coordinates are already horizontally flipped: anatomical left
        // is on the viewer's right. Deliberately return the right hand first.
        let rightHand = MappedGroup(
            region: .hands,
            points: [CGPoint(x: 0.14, y: 0.45), CGPoint(x: 0.08, y: 0.5)],
            edges: [(0, 1)],
            labels: ["R0", "R1"]
        )
        let leftHand = MappedGroup(
            region: .hands,
            points: [CGPoint(x: 0.86, y: 0.45), CGPoint(x: 0.92, y: 0.5)],
            edges: [(0, 1)],
            labels: ["L0", "L1"]
        )
        let torso = MappedGroup(
            region: .torso,
            points: [CGPoint(x: 0.35, y: 0.3), CGPoint(x: 0.65, y: 0.3)],
            edges: [(0, 1)]
        )

        let components = [rightArm, rightHand, torso, leftHand, leftArm]
            .flatMap(PortraitPathBuilder.components)
        let ordered = PortraitPathBuilder.orderedBodyFeatures(components)

        XCTAssertEqual(ordered.map(\.region), [.leftArm, .hands, .torso, .rightArm, .hands])
        XCTAssertEqual(ordered.compactMap { $0.region == .hands ? $0.handedness : nil }, [.left, .right])
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
