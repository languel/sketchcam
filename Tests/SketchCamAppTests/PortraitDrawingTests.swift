import CoreGraphics
import CoreImage
import CoreVideo
import XCTest
@testable import SketchCam
import SketchCamCore
import SketchCamShared

final class WrapNearestNeighborTests: XCTestCase {
    func testSpatialOrderMatchesOriginalGreedyOrderIncludingTies() {
        for count in [3, 17, 96, 512] {
            let points = (0..<count).map { index in
                CGPoint(x: (index * 37 % 23) * 3, y: (index * 19 % 29) * 2)
            }
            var remaining = points
            var expected = [remaining.removeFirst()]
            while !remaining.isEmpty {
                let last = expected[expected.count - 1]
                let nearest = remaining.enumerated().min { left, right in
                    let ldx = left.element.x - last.x, ldy = left.element.y - last.y
                    let rdx = right.element.x - last.x, rdy = right.element.y - last.y
                    let ld = ldx * ldx + ldy * ldy
                    let rd = rdx * rdx + rdy * rdy
                    return ld == rd ? left.offset < right.offset : ld < rd
                }!.offset
                expected.append(remaining.remove(at: nearest))
            }
            XCTAssertEqual(WrapDrawing.nearestNeighborOrder(points), expected)
        }
    }
}

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

    func testBrowCenterlineAveragesReturningOutline() throws {
        let brow = PortraitPathBuilder.Component(region: .leftBrow, points: [
            CGPoint(x: 0, y: 0), CGPoint(x: 5, y: -2), CGPoint(x: 10, y: 0),
            CGPoint(x: 5, y: 2), CGPoint(x: 0, y: 0)
        ], closed: false, handedness: .unknown)
        let centered = try XCTUnwrap(PortraitPathBuilder.browCenterline([brow]))
        XCTAssertFalse(centered.closed)
        XCTAssertEqual(centered.points.first?.x, 0)
        XCTAssertEqual(centered.points.last?.x, 10)
        XCTAssertEqual(centered.points[centered.points.count / 2].y, 0, accuracy: 0.01)
    }

    func testMouthCenterlineAveragesInnerAndOuterRings() throws {
        let outer = loop(center: CGPoint(x: 100, y: 100), rx: 30, ry: 12, count: 16)
        let inner = loop(center: CGPoint(x: 100, y: 100), rx: 16, ry: 4, count: 12)
        let group = MappedGroup(region: .mouth, points: outer.points + inner.points,
            edges: outer.edges + inner.edges.map { ($0.0 + outer.points.count, $0.1 + outer.points.count) })
        let centered = PortraitPathBuilder.mouthFeatures(PortraitPathBuilder.components(group),
            connection: .sharedCorner, innerEnabled: true, centerline: true,
            leftEye: [], rightEye: [])
        XCTAssertEqual(centered.count, 1)
        let ring = try XCTUnwrap(centered.first)
        XCTAssertTrue(ring.closed)
        XCTAssertEqual(ring.points.first, ring.points.last)
        XCTAssertEqual(ring.points.map(\.x).min() ?? 0, 77, accuracy: 1.5)
        XCTAssertEqual(ring.points.map(\.x).max() ?? 0, 123, accuracy: 1.5)
    }

    func testLiveLandmarkMotionMorphsStableFaceAndBodyRoutes() throws {
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitStyle = .fluid
        settings.portraitFollow = 0.8
        settings.portraitFlourish = 0.3
        settings.portraitPoseBodyEnabled = false
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

    func testPortraitHairAnchorsToFaceAndFillsScalpWithWildWeave() throws {
        let face = MappedGroup(
            region: .jaw,
            points: [CGPoint(x: 100, y: 130), CGPoint(x: 105, y: 175),
                     CGPoint(x: 150, y: 260), CGPoint(x: 195, y: 175),
                     CGPoint(x: 200, y: 130)],
            edges: [(0, 1), (1, 2), (2, 3), (3, 4)]
        )
        let hands = MappedGroup(
            region: .hands,
            points: [CGPoint(x: -900, y: 900), CGPoint(x: 900, y: 900)],
            edges: [(0, 1)]
        )
        let clean = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [face, hands], style: .clean, amount: 0.4, seed: 1))
        let wild = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [face, hands], style: .wild, amount: 0.9, seed: 1))

        XCTAssertEqual(clean.points.count, 17)
        XCTAssertGreaterThan(wild.points.count, 120)
        XCTAssertLessThan(wild.points.count, 300)
        XCTAssertEqual(clean.points.first, face.points.first)
        XCTAssertEqual(clean.points.last, face.points.last)
        XCTAssertEqual(wild.points.first, face.points.first)
        XCTAssertEqual(wild.points.last, face.points.last)
        XCTAssertEqual(clean.points, PortraitPathBuilder.hairComponent(from: [face], style: .clean, amount: 0.4, seed: 1)?.points,
                       "Hands must not move the scalp")
        XCTAssertLessThan(clean.points.map(\.y).min()!, 70,
                          "The crown must rise above the brows, not read as a unibrow")
        XCTAssertNotEqual(clean.points, wild.points)
        XCTAssertEqual(wild.scalpApex, clean.scalpApex)
        XCTAssertTrue(wild.points.dropFirst().dropLast().allSatisfy {
            $0.x > face.points.first!.x - 5 && $0.x < face.points.last!.x + 5
        }, "The dense walk should remain between the two ear anchors")
        let sparse = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [face], style: .wild, amount: 0, seed: 1))
        XCTAssertLessThan(sparse.points.count, wild.points.count,
                          "Hair amount should increase fill density")
        XCTAssertEqual(sparse.scalpApex, wild.scalpApex,
                       "Hair amount should not stretch the skull")
        XCTAssertLessThan(
            wild.points.map(\.y).max()! - wild.points.map(\.y).min()!,
            160,
            "The wild crown should fill a head-sized cap, not form a cone."
        )
    }

    func testZigzagHairContinuesToGainDensityPastFour() throws {
        let face = MappedGroup(
            region: .jaw,
            points: [CGPoint(x: 100, y: 130), CGPoint(x: 105, y: 175),
                     CGPoint(x: 150, y: 260), CGPoint(x: 195, y: 175),
                     CGPoint(x: 200, y: 130)],
            edges: [(0, 1), (1, 2), (2, 3), (3, 4)]
        )
        let medium = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [face], style: .hatchVertical, amount: 4, seed: 5))
        let dense = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [face], style: .hatchVertical, amount: 12, seed: 5))
        XCTAssertGreaterThan(dense.points.count, medium.points.count * 2)
        XCTAssertEqual(dense.scalpApex, medium.scalpApex)
        XCTAssertEqual(dense.points.first, face.points.first)
        XCTAssertEqual(dense.points.last, face.points.last)
        // The first stroke traverses the cap diagonally, not straight down.
        XCTAssertGreaterThan(abs(dense.points[18].x - dense.points[42].x), 2)
    }

    func testHairOverhangExtendsTextureWithoutMovingScalpOrEarAnchors() throws {
        let jaw = MappedGroup(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 105, y: 175),
            CGPoint(x: 150, y: 260), CGPoint(x: 195, y: 175),
            CGPoint(x: 200, y: 130)
        ])
        let close = try XCTUnwrap(PortraitPathBuilder.hairComponent(
            from: [jaw], style: .wild, amount: 4, seed: 13, expansion: 0))
        let expanded = try XCTUnwrap(PortraitPathBuilder.hairComponent(
            from: [jaw], style: .wild, amount: 4, seed: 13, expansion: 1.5))
        XCTAssertEqual(Array(close.points.prefix(17)), Array(expanded.points.prefix(17)),
                       "Overhang must not raise or replace the scalp curve")
        XCTAssertEqual(close.scalpApex, expanded.scalpApex)
        XCTAssertEqual(close.points.first, expanded.points.first)
        XCTAssertEqual(close.points.last, expanded.points.last)
        XCTAssertGreaterThan(expanded.points.count, close.points.count,
                             "The additional hair area should receive more ink samples")
        XCTAssertLessThan(expanded.points.map(\.y).min()!, close.points.map(\.y).min()! - 8,
                          "Hair texture should visibly rise beyond the skull")

        var settings = LandmarkSettings()
        settings.portraitHairEnabled = true
        settings.portraitHairStyle = .wild
        let closePaint = try XCTUnwrap(PortraitFillRenderer.shapes(
            groups: [jaw], settings: settings).first { $0.part == .hair })
        settings.portraitHairExpansion = 1.5
        let expandedPaint = try XCTUnwrap(PortraitFillRenderer.shapes(
            groups: [jaw], settings: settings).first { $0.part == .hair })
        XCTAssertLessThan(expandedPaint.points.map(\.y).min()!,
                          closePaint.points.map(\.y).min()! - 8,
                          "The flat hair color should cover the overhanging marks")
    }

    func testHairOverhangSpreadsAroundEarsAndHairdosChangeOuterMass() throws {
        let jaw = MappedGroup(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 105, y: 175),
            CGPoint(x: 150, y: 260), CGPoint(x: 195, y: 175),
            CGPoint(x: 200, y: 130)
        ])
        let compact = try XCTUnwrap(PortraitPathBuilder.hairComponent(
            from: [jaw], style: .wild, amount: 3, seed: 12))
        let rounded = try XCTUnwrap(PortraitPathBuilder.hairComponent(
            from: [jaw], style: .wild, amount: 3, seed: 12,
            expansion: 1.5, hairdo: .rounded))
        let swept = try XCTUnwrap(PortraitPathBuilder.hairComponent(
            from: [jaw], style: .wild, amount: 3, seed: 12,
            expansion: 1.5, hairdo: .swept))
        let compactOuter = try XCTUnwrap(compact.hairFillOutline)
        let roundedOuter = try XCTUnwrap(rounded.hairFillOutline)
        XCTAssertLessThan(roundedOuter.map(\.x).min()!, compactOuter.map(\.x).min()! - 8)
        XCTAssertGreaterThan(roundedOuter.map(\.x).max()!, compactOuter.map(\.x).max()! + 8)
        XCTAssertEqual(Array(compact.points.prefix(17)), Array(rounded.points.prefix(17)))
        XCTAssertNotEqual(roundedOuter, swept.hairFillOutline)
    }

    func testWildAndWrapHairKeepPointCorrespondenceAsHeadMoves() throws {
        let jaw = [CGPoint(x: 100, y: 130), CGPoint(x: 105, y: 175),
                   CGPoint(x: 150, y: 260), CGPoint(x: 195, y: 175),
                   CGPoint(x: 200, y: 130)]
        let edges = [(0, 1), (1, 2), (2, 3), (3, 4)]
        let first = MappedGroup(region: .jaw, points: jaw, edges: edges)
        var movedJaw = jaw
        movedJaw[4].x += 6
        movedJaw[4].y += 3
        let moved = MappedGroup(region: .jaw, points: movedJaw, edges: edges)

        for style in [PortraitHairStyle.wild, .wrap] {
            let before = try XCTUnwrap(PortraitPathBuilder.hairComponent(
                from: [first], style: style, amount: 4, seed: 23))
            let after = try XCTUnwrap(PortraitPathBuilder.hairComponent(
                from: [moved], style: style, amount: 4, seed: 23))
            XCTAssertEqual(before.points.count, after.points.count)
            let largestStep = zip(before.points, after.points).map {
                hypot($0.x - $1.x, $0.y - $1.y)
            }.max() ?? 0
            XCTAssertLessThan(largestStep, 15,
                              "A small landmark motion must deform hair, not reorder its samples")
        }
    }

    func testHighHairFillSurvivesPortraitRouteSampling() {
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitHairEnabled = true
        settings.portraitHairStyle = .hatchVertical
        settings.portraitHairAmount = 4
        let groups = portraitGroups(offset: .zero)
        let drawing = PortraitDrawing()
        let mediumCount = drawing.semanticRoutes(groups: groups, landmarks: settings)
            .reduce(0) { $0 + $1.count }

        settings.portraitHairAmount = 20
        let denseCount = drawing.semanticRoutes(groups: groups, landmarks: settings)
            .reduce(0) { $0 + $1.count }
        XCTAssertGreaterThan(denseCount, mediumCount * 3 / 2)
    }

    func testPoseBodyShapeConnectsEarAnchorsAndArticulatesWithArms() throws {
        let jaw = MappedGroup(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 115, y: 195),
            CGPoint(x: 150, y: 230), CGPoint(x: 185, y: 195), CGPoint(x: 200, y: 130)
        ])
        let torso = MappedGroup(region: .torso, points: [
            CGPoint(x: 150, y: 260), CGPoint(x: 65, y: 290), CGPoint(x: 235, y: 290),
            CGPoint(x: 150, y: 400), CGPoint(x: 90, y: 410), CGPoint(x: 210, y: 410)
        ], labels: ["neck", "Lsho", "Rsho", "root", "Lhip", "Rhip"])
        let leftArm = MappedGroup(region: .leftArm, points: [
            CGPoint(x: 65, y: 290), CGPoint(x: 25, y: 335), CGPoint(x: 15, y: 390)
        ], labels: ["Lsho", "Lelb", "Lwri"])
        let rightArm = MappedGroup(region: .rightArm, points: [
            CGPoint(x: 235, y: 290), CGPoint(x: 275, y: 335), CGPoint(x: 285, y: 390)
        ], labels: ["Rsho", "Relb", "Rwri"])
        let groups = [jaw, torso, leftArm, rightArm]
        let shape = try XCTUnwrap(PortraitPathBuilder.poseBodyComponent(from: groups, scalp: nil, seed: 7))
        XCTAssertEqual(shape.points.first, jaw.points[1])
        XCTAssertEqual(shape.points.last, jaw.points[3])
        XCTAssertLessThan(shape.points.map(\.x).min()!, 30)
        XCTAssertGreaterThan(shape.points.map(\.x).max()!, 270)

        let movedArm = MappedGroup(region: .rightArm, points: [
            CGPoint(x: 235, y: 290), CGPoint(x: 275, y: 335), CGPoint(x: 350, y: 320)
        ], labels: ["Rsho", "Relb", "Rwri"])
        let moved = try XCTUnwrap(PortraitPathBuilder.poseBodyComponent(
            from: [jaw, torso, leftArm, movedArm], scalp: nil, seed: 7))
        XCTAssertNotEqual(shape.points, moved.points)
        XCTAssertEqual(moved.points.first, shape.points.first)
        XCTAssertEqual(moved.points.last, shape.points.last)
        XCTAssertEqual(shape.points, PortraitPathBuilder.poseBodyComponent(from: groups, scalp: nil, seed: 7)?.points)
    }

    func testPoseBodyShapePersistsFromFaceAndHandWhenPoseIsMissing() throws {
        let jaw = MappedGroup(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 115, y: 190),
            CGPoint(x: 150, y: 230), CGPoint(x: 185, y: 190), CGPoint(x: 200, y: 130)
        ])
        let hand = MappedGroup(region: .hands,
                               points: [CGPoint(x: 20, y: 310)], labels: ["L0"])
        let body = try XCTUnwrap(PortraitPathBuilder.poseBodyComponent(
            from: [jaw, hand], scalp: nil, seed: 5
        ))
        XCTAssertEqual(body.points.first, jaw.points[1])
        XCTAssertEqual(body.points.last, jaw.points[3])
        XCTAssertGreaterThan(body.points.count, 12)
        XCTAssertLessThan(body.points.map(\.x).min()!, 50)
        XCTAssertGreaterThan(body.points.map(\.y).max()!, 300)

        let movedHand = MappedGroup(region: .hands,
                                    points: [CGPoint(x: 4, y: 365)], labels: ["L0"])
        let movedBody = try XCTUnwrap(PortraitPathBuilder.poseBodyComponent(
            from: [jaw, movedHand], scalp: nil, seed: 5
        ))
        XCTAssertNotEqual(body.points, movedBody.points)
    }

    func testFigureRigInfersBothBentArmsAndNarrowNeckWithoutPose() throws {
        let jaw = MappedGroup(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 115, y: 190),
            CGPoint(x: 150, y: 230), CGPoint(x: 185, y: 190),
            CGPoint(x: 200, y: 130)
        ])
        let rig = try XCTUnwrap(PortraitPathBuilder.poseBodyComponent(
            from: [jaw], scalp: nil, seed: 9))
        XCTAssertEqual(rig.sleeveFills.count, 2,
                       "Each missing arm should retain an inferred elbow and wrist")
        XCTAssertTrue(rig.sleeveFills.allSatisfy { $0.count >= 7 })
        let neck = try XCTUnwrap(rig.neckFill)
        let torso = try XCTUnwrap(rig.torsoFill)
        let collarWidth = hypot(neck[2].x - neck[1].x, neck[2].y - neck[1].y)
        let shoulderWidth = hypot(torso.last!.x - torso.first!.x,
                                  torso.last!.y - torso.first!.y)
        XCTAssertLessThan(collarWidth, shoulderWidth * 0.65,
                          "Face color must end at a collar, not the shoulder tips")
    }

    func testZeroConnectorWidthSeparatesLandmarkAndGestureFeatures() {
        let groups = portraitGroups(offset: .zero)
        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitPoseBodyEnabled = false
        settings.portraitConnectorWidth = 0
        let drawing = PortraitDrawing()
        let landmarkRoutes = drawing.semanticRoutes(groups: groups, landmarks: settings)
        XCTAssertGreaterThan(landmarkRoutes.count, 6)
        var toggled = settings
        toggled.portraitConnectorWidth = 0.42
        toggled.portraitSeparateFeatures = true
        XCTAssertEqual(landmarkRoutes, drawing.semanticRoutes(groups: groups, landmarks: toggled))

        settings.portraitApproach = .gesture
        let gestureRoutes = drawing.semanticRoutes(groups: groups, landmarks: settings)
        XCTAssertGreaterThanOrEqual(gestureRoutes.count, 7)
        XCTAssertTrue(gestureRoutes.allSatisfy { $0.count >= 2 })
    }

    func testFeatureLineTogglesKeepEyesAndHandsIndependentAcrossApproaches() {
        let groups = portraitGroups(offset: .zero) + [sampleHandGroup()]
        let drawing = PortraitDrawing()
        for approach in PortraitApproach.allCases {
            var settings = LandmarkSettings()
            settings.portraitEnabled = true
            settings.portraitApproach = approach
            settings.portraitSeparateFeatures = true
            settings.portraitPoseBodyEnabled = false
            let all = drawing.semanticRoutes(groups: groups, landmarks: settings)
            XCTAssertTrue(all.contains { $0.count >= 20 }, "\(approach) should outline the tracked hand")

            settings.portraitLineFeatures = [.eyes: false]
            let noEyes = drawing.semanticRoutes(groups: groups, landmarks: settings)
            XCTAssertLessThan(noEyes.count, all.count, "\(approach) should hide eye outlines")

            settings.portraitLineFeatures = [.hands: false]
            let noHands = drawing.semanticRoutes(groups: groups, landmarks: settings)
            XCTAssertLessThan(noHands.count, all.count, "\(approach) should hide hand outlines")
        }
    }

    func testSegmentsSubdivideAuthoredRoutesWithoutChangingTheirPoints() {
        let groups = portraitGroups(offset: .zero)
        let drawing = PortraitDrawing()
        for approach in [PortraitApproach.gesture, .aaron] {
            var settings = LandmarkSettings()
            settings.portraitEnabled = true
            settings.portraitApproach = approach
            settings.portraitPoseBodyEnabled = false
            settings.portraitSegments = 1
            let one = drawing.semanticRoutes(groups: groups, landmarks: settings)
            settings.portraitSegments = 8
            let eight = drawing.semanticRoutes(groups: groups, landmarks: settings)
            XCTAssertGreaterThan(eight.count, one.count)
            XCTAssertEqual(eight.first?.first, one.first?.first)
        }
    }

    func testRaisedHandDoesNotPullTorsoPaintIntoTriangle() throws {
        let jaw = MappedGroup(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 115, y: 190),
            CGPoint(x: 150, y: 230), CGPoint(x: 185, y: 190),
            CGPoint(x: 200, y: 130)
        ])
        let wrist = CGPoint(x: 18, y: 40)
        let hand = MappedGroup(region: .hands, points: [wrist], labels: ["L0"])
        let body = try XCTUnwrap(PortraitPathBuilder.poseBodyComponent(
            from: [jaw, hand], scalp: nil, seed: 5))
        let torso = try XCTUnwrap(body.torsoFill)
        XCTAssertGreaterThan(body.sleeveFills.count, 0)
        XCTAssertGreaterThan(torso.map(\.x).min()!, wrist.x + 20,
                             "The raised wrist belongs to a sleeve, not the shirt fill")
        XCTAssertTrue(body.sleeveFills.contains { sleeve in
            sleeve.contains { hypot($0.x - wrist.x, $0.y - wrist.y) < 10 }
        })
    }

    func testPortraitSourceDensityCanInterpolateSparseBodyCurve() {
        let source = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 0)]
        let dense = PortraitPathBuilder.sampledLandmarks(
            source, closed: false, variation: 0, subsample: 4,
            maximumCount: 64, seed: 1
        )
        XCTAssertGreaterThan(dense.count, source.count)
        XCTAssertEqual(dense.first, source.first)
        XCTAssertEqual(dense.last, source.last)
    }

    func testTemplatePortraitKeepsAuthoredFigureWhileExpressionMovesMouth() {
        let original = portraitGroups(offset: .zero)
        var settings = LandmarkSettings()
        settings.portraitApproach = .aaron
        settings.portraitAbstraction = 0.2
        settings.portraitExpression = 1.0
        let first = AaronPortrait.paths(groups: original, settings: settings)
        XCTAssertGreaterThanOrEqual(first.count, 10)
        XCTAssertEqual(first, AaronPortrait.paths(groups: original, settings: settings))

        settings.portraitExpression = 1.8
        let expressive = AaronPortrait.paths(groups: original, settings: settings)
        XCTAssertEqual(first.count, expressive.count)
        XCTAssertEqual(first[1], expressive[1], "Expression must not warp the head outline")
        XCTAssertNotEqual(first[9], expressive[9], "Mouth opening should follow expression")

        settings.portraitSeed = 91
        let reseeded = AaronPortrait.paths(groups: original, settings: settings)
        XCTAssertNotEqual(expressive[1], reseeded[1], "Seed should explore authored head proportions")
    }

    func testGestureAndTemplateCanDrawHeadAndHandsWithoutBody() {
        let groups = portraitGroups(offset: .zero) + [sampleHandGroup()]
        let drawing = PortraitDrawing()
        for approach in [PortraitApproach.gesture, .aaron] {
            var settings = LandmarkSettings()
            settings.portraitApproach = approach
            settings.portraitSeparateFeatures = true
            settings.portraitPoseBodyEnabled = true
            settings.portraitBodyEnabled = false
            settings.portraitOutlineEnabled = true
            let routes = drawing.semanticRoutes(groups: groups, landmarks: settings)
            XCTAssertGreaterThan(routes.count, 3, "\(approach) should retain head and hand lines")
            XCTAssertTrue(routes.contains { $0.count >= 20 }, "\(approach) should retain the hand")
            let paint = PortraitFillRenderer.shapes(groups: groups, settings: settings)
            XCTAssertTrue(paint.contains { $0.part == .face })
            XCTAssertTrue(paint.contains { $0.part == .hand })
            XCTAssertFalse(paint.contains { $0.part == .body || $0.part == .neck })
        }
    }

    func testBodyOutlineOffKeepsOnlyHeadAndHandPaint() {
        let groups = portraitGroups(offset: .zero) + [sampleHandGroup()]
        for approach in [PortraitApproach.landmarks, .gesture, .aaron] {
            var settings = LandmarkSettings()
            settings.portraitApproach = approach
            settings.portraitPoseBodyEnabled = true
            settings.portraitOutlineEnabled = false
            let paint = PortraitFillRenderer.shapes(groups: groups, settings: settings)
            XCTAssertTrue(paint.contains { $0.part == .face }, "\(approach)")
            XCTAssertTrue(paint.contains { $0.part == .hand }, "\(approach)")
            XCTAssertFalse(paint.contains { $0.part == .body || $0.part == .neck }, "\(approach)")
        }
    }

    func testCenterlineOptionsReachAuthoredApproaches() {
        let groups = portraitGroups(offset: .zero)
        var settings = LandmarkSettings()
        settings.portraitApproach = .gesture
        settings.portraitSeparateFeatures = true
        settings.portraitPoseBodyEnabled = false
        let gestureOriginal = GesturePortrait.paths(groups: groups, settings: settings)
        settings.portraitMouthCenterlineEnabled = true
        let gestureCenterline = GesturePortrait.paths(groups: groups, settings: settings)
        XCTAssertEqual(gestureCenterline.count, gestureOriginal.count - 1)

        settings.portraitApproach = .aaron
        let templateCenterline = AaronPortrait.paths(groups: groups, settings: settings)
        settings.portraitMouthCenterlineEnabled = false
        let templateOriginal = AaronPortrait.paths(groups: groups, settings: settings)
        XCTAssertNotEqual(templateCenterline[9], templateOriginal[9])
    }

    func testNeckUsesLowerJawEvenWhenScalpEndsAtEyeHeight() throws {
        let jaw = MappedGroup(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 115, y: 195),
            CGPoint(x: 150, y: 230), CGPoint(x: 185, y: 195), CGPoint(x: 200, y: 130)
        ])
        let scalp = PortraitPathBuilder.Component(region: .head, points: [
            CGPoint(x: 100, y: 125), CGPoint(x: 150, y: 40), CGPoint(x: 200, y: 125)
        ], closed: false, handedness: .unknown)
        let body = try XCTUnwrap(PortraitPathBuilder.poseBodyComponent(
            from: [jaw], scalp: scalp, seed: 9))
        XCTAssertEqual(body.points.first, jaw.points[1])
        XCTAssertEqual(body.points.last, jaw.points[3])
        XCTAssertGreaterThan(body.points.first!.y, scalp.points.first!.y + 50)
        let collar = try XCTUnwrap(body.neckFill)
        XCTAssertLessThan(collar[1].y - jaw.points[2].y, 90,
                          "Missing shoulders should not create an elongated neck")
    }

    func testSyntheticEarsGrowOutwardFromJawSides() {
        let jaw = PortraitPathBuilder.Component(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 115, y: 190),
            CGPoint(x: 150, y: 230), CGPoint(x: 185, y: 190), CGPoint(x: 200, y: 130)
        ], closed: false, handedness: .unknown)
        let withEars = PortraitPathBuilder.jawWithEars(jaw)
        XCTAssertLessThan(withEars.points.map(\.x).min()!, 98)
        XCTAssertGreaterThan(withEars.points.map(\.x).max()!, 202)
        XCTAssertGreaterThan(withEars.points.map(\.x).min()!, 90)
        XCTAssertLessThan(withEars.points.map(\.x).max()!, 210)
        XCTAssertTrue(withEars.points.contains(CGPoint(x: 150, y: 230)))
    }

    func testConstructivistDirectionsPreserveEndpointsAndClosure() {
        let source = [CGPoint(x: 2, y: 3), CGPoint(x: 31, y: 15),
                      CGPoint(x: 9, y: 44), CGPoint(x: 2, y: 3)]
        XCTAssertEqual(PortraitPathBuilder.constructivistPath(source, amount: 0), source)
        let angular = PortraitPathBuilder.constructivistPath(source, amount: 1)
        XCTAssertEqual(angular.first, source.first)
        XCTAssertEqual(angular.last, source.last)
        for (a, b) in zip(angular, angular.dropFirst()) {
            let dx = abs(b.x - a.x), dy = abs(b.y - a.y)
            XCTAssertTrue(dx < 0.001 || dy < 0.001 || abs(dx - dy) < 0.001)
        }
    }

    func testConstructivistSimplifiesDenseFaceContourAtFeatureScale() {
        let dense = (0...240).map { index -> CGPoint in
            let t = CGFloat(index) / 240
            return CGPoint(x: 100 + 150 * t,
                           y: 150 + 55 * sin(.pi * t) + (index.isMultiple(of: 2) ? 1.5 : -1.5))
        }
        let reduced = PortraitPathBuilder.simplifiedFeaturePath(dense, faceWidth: 150, amount: 1)
        XCTAssertLessThan(reduced.count, 20)
        XCTAssertEqual(reduced.first, dense.first)
        XCTAssertEqual(reduced.last, dense.last)
        XCTAssertEqual(PortraitPathBuilder.simplifiedFeaturePath(dense, faceWidth: 150, amount: 0), dense)
    }

    func testTemplateHairHasTextureAndPaintAndDropsBelowTemples() throws {
        var settings = LandmarkSettings()
        settings.portraitApproach = .aaron
        settings.portraitHairEnabled = true
        settings.portraitHairStyle = .hatch
        settings.portraitHairdo = .shag
        settings.portraitHairExpansion = 1
        let groups = portraitGroups(offset: .zero)
        let geometry = AaronPortrait.geometry(groups: groups, settings: settings)
        let hair = try XCTUnwrap(geometry.hair)
        XCTAssertGreaterThan(hair.points.count, 17)
        let outer = try XCTUnwrap(hair.hairFillOutline)
        let jaw = geometry.paths[1]
        XCTAssertFalse(jaw.isEmpty)
        XCTAssertEqual(outer.first!.x, hair.points.first!.x, accuracy: 0.001)
        XCTAssertEqual(outer.first!.y, hair.points.first!.y, accuracy: 0.001)
        XCTAssertEqual(outer.last!.x, hair.points[16].x, accuracy: 0.001)
        XCTAssertEqual(outer.last!.y, hair.points[16].y, accuracy: 0.001)
        XCTAssertEqual(hair.hairSideFills.count, 2)
        let paintedHair = PortraitFillRenderer.shapes(groups: groups, settings: settings)
            .filter { $0.part == .hair }
        XCTAssertEqual(paintedHair.count, 3)
        for side in hair.hairSideFills {
            let width = (side.map(\.x).max() ?? 0) - (side.map(\.x).min() ?? 0)
            XCTAssertLessThan(width, 25)
        }
    }

    func testTemplateFollowsBlinkAndInnerLipOpening() {
        var settings = LandmarkSettings()
        settings.portraitApproach = .aaron
        settings.portraitExpression = 1
        let original = portraitGroups(offset: .zero)
        func observed(blink: Bool, lipHeight: CGFloat) -> [MappedGroup] {
            let face = original.filter { $0.region != .mouth }.map { group in
                guard blink && group.region == .leftEye else { return group }
                return MappedGroup(region: group.region,
                    points: group.points.map { CGPoint(x: $0.x, y: 125 + ($0.y - 125) * 0.02) },
                    edges: group.edges)
            }
            let outer = loop(center: CGPoint(x: 200, y: 190), rx: 32, ry: 24, count: 12)
            let inner = loop(center: CGPoint(x: 200, y: 190), rx: 24, ry: lipHeight, count: 12)
            return face + [MappedGroup(region: .mouth, points: outer.points + inner.points,
                edges: outer.edges + inner.edges.map { ($0.0 + 12, $0.1 + 12) },
                labels: (0..<12).map { "oL\($0)" } + (0..<12).map { "iL\($0)" })]
        }
        let open = AaronPortrait.paths(groups: observed(blink: false, lipHeight: 20), settings: settings)
        let closed = AaronPortrait.paths(groups: observed(blink: true, lipHeight: 0.5), settings: settings)
        func height(_ path: [CGPoint]) -> CGFloat {
            (path.map(\.y).max() ?? 0) - (path.map(\.y).min() ?? 0)
        }
        XCTAssertLessThan(height(closed[4]), height(open[4]) * 0.1)
        XCTAssertLessThan(height(closed[6]), height(open[6]) * 0.1)
        XCTAssertLessThan(height(closed[9]), height(open[9]) * 0.2)
        XCTAssertEqual(open[1], closed[1], "Expressions must not distort the head")
    }

    func testPortraitFillShapesAndCameraColorAreDeterministic() {
        let jaw = MappedGroup(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 115, y: 190),
            CGPoint(x: 150, y: 230), CGPoint(x: 185, y: 190), CGPoint(x: 200, y: 130)
        ])
        let brows = MappedGroup(region: .leftBrow, points: [
            CGPoint(x: 115, y: 115), CGPoint(x: 140, y: 110)
        ])
        var settings = LandmarkSettings()
        settings.portraitHairEnabled = true
        settings.portraitFillEnabled = true
        settings.portraitPoseBodyEnabled = true
        settings.portraitOutlineEnabled = true
        settings.portraitFillVariation = 0
        let shapes = PortraitFillRenderer.shapes(groups: [jaw, brows], settings: settings)
        XCTAssertTrue(shapes.contains { $0.part == .neck })
        XCTAssertTrue(shapes.contains { $0.part == .face })
        XCTAssertTrue(shapes.contains { $0.part == .hair })
        let camera = RGBAColor(red: 0.31, green: 0.57, blue: 0.82)
        let direct = PortraitFillRenderer.paintColor(camera: camera, part: .face,
                                                     settings: settings, seed: 11)
        XCTAssertEqual(direct.red, camera.red)
        XCTAssertEqual(direct.green, camera.green)
        XCTAssertEqual(direct.blue, camera.blue)

        settings.portraitFillPalettized = true
        settings.portraitFillPaletteSteps = 3
        settings.portraitFillVariation = 0.5
        let first = PortraitFillRenderer.paintColor(camera: camera, part: .face,
                                                    settings: settings, seed: 11)
        let second = PortraitFillRenderer.paintColor(camera: camera, part: .face,
                                                     settings: settings, seed: 11)
        XCTAssertEqual(first, second)
        XCTAssertTrue(PortraitFillRenderer.printPalette.prefix(3).contains {
            $0.red == first.red && $0.green == first.green && $0.blue == first.blue
        })
    }

    func testPortraitPaletteHoldsColorAcrossShortLuminanceChanges() {
        var settings = LandmarkSettings()
        settings.portraitFillPalettized = true
        settings.portraitFillPaletteSteps = 2
        settings.portraitFillVariation = 0
        let tracker = PortraitFillColorTracker()
        let dark = RGBAColor(red: 0.10, green: 0.10, blue: 0.10)
        let bright = RGBAColor(red: 0.95, green: 0.95, blue: 0.95)
        let first = tracker.color(camera: dark, part: .face, slot: 1,
                                  settings: settings, seed: 31, now: 0)
        for second in 1...7 {
            let held = tracker.color(camera: bright, part: .face, slot: 1,
                                      settings: settings, seed: 31, now: Double(second))
            XCTAssertEqual(held, first)
        }
        // A deliberately changed seed is a new artistic color decision.
        settings.portraitSeed = 32
        let reseeded = tracker.color(camera: bright, part: .face, slot: 1,
                                     settings: settings, seed: 32, now: 8)
        XCTAssertEqual(reseeded, PortraitFillRenderer.paintColor(
            camera: bright, part: .face, settings: settings, seed: 32))
    }

    func testPortraitColorSamplingMirrorsWithOutput() throws {
        let buffer = try PixelBufferUtils.makePixelBuffer(
            format: FrameFormat(id: "portrait-color", width: 8, height: 4)
        )
        CVPixelBufferLockBaseAddress(buffer, [])
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = try XCTUnwrap(CVPixelBufferGetBaseAddress(buffer))
            .assumingMemoryBound(to: UInt8.self)
        for y in 0..<4 {
            for x in 0..<8 {
                let offset = y * stride + x * 4
                bytes[offset] = x < 4 ? 0 : 255 // blue
                bytes[offset + 1] = 0
                bytes[offset + 2] = x < 4 ? 255 : 0 // red
                bytes[offset + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        let canvas = CGSize(width: 8, height: 4)
        let context = CIContext()
        let direct = try XCTUnwrap(PortraitColorField.capture(buffer, canvasSize: canvas,
                                                               mirrored: false, context: context))
        let flipped = try XCTUnwrap(PortraitColorField.capture(buffer, canvasSize: canvas,
                                                                mirrored: true, context: context))
        XCTAssertGreaterThan(direct.sample(at: CGPoint(x: 1, y: 2), canvasSize: canvas).red, 0.8)
        XCTAssertGreaterThan(flipped.sample(at: CGPoint(x: 1, y: 2), canvasSize: canvas).blue, 0.8)
    }

    func testPersonOutlineAddsHairMassWithoutReplacingFaceAttachedScalp() throws {
        let jaw = MappedGroup(
            region: .jaw,
            points: [CGPoint(x: 100, y: 130), CGPoint(x: 105, y: 175),
                     CGPoint(x: 150, y: 260), CGPoint(x: 195, y: 175),
                     CGPoint(x: 200, y: 130)],
            edges: [(0, 1), (1, 2), (2, 3), (3, 4)]
        )
        let silhouette = MappedGroup(region: .contour, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 50, y: 85),
            CGPoint(x: 125, y: 30), CGPoint(x: 150, y: 10),
            CGPoint(x: 175, y: 30), CGPoint(x: 195, y: 85),
            CGPoint(x: 200, y: 130)
        ])
        let plain = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [jaw], style: .wild, amount: 4, seed: 7))
        let guided = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [jaw, silhouette], style: .wild, amount: 4, seed: 7))
        XCTAssertEqual(Array(guided.points.prefix(17)), Array(plain.points.prefix(17)),
                       "The face-attached scalp must not turn into a silhouette helmet")
        let plainOuter = try XCTUnwrap(plain.hairFillOutline)
        let guidedOuter = try XCTUnwrap(guided.hairFillOutline)
        XCTAssertLessThan(guidedOuter.map(\.y).min()!, plainOuter.map(\.y).min()! - 4)
        XCTAssertLessThan(guidedOuter.map(\.x).min()!, plainOuter.map(\.x).min()! - 2)
        XCTAssertLessThan(guided.points.map(\.y).min()!, plain.points.map(\.y).min()! - 4,
                          "Wild ink must sample the silhouette-derived hair area, not only the paint")
        XCTAssertEqual(guided.points.first, jaw.points.first)
        XCTAssertEqual(guided.points.last, jaw.points.last)

        var movedPoints = jaw.points
        movedPoints[0] = CGPoint(x: 90, y: 145)
        movedPoints[movedPoints.count - 1] = CGPoint(x: 210, y: 135)
        let movedJaw = MappedGroup(region: .jaw, points: movedPoints, edges: jaw.edges)
        let moved = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [movedJaw, silhouette], style: .wild, amount: 4, seed: 7))
        XCTAssertEqual(moved.points.first, movedJaw.points.first)
        XCTAssertEqual(moved.points.last, movedJaw.points.last)
    }

    func testPortraitBodyOutlineJoinsScalpAtEarsWithoutRepeatingHeadArc() throws {
        let jaw = MappedGroup(region: .jaw, points: [
            CGPoint(x: 100, y: 130), CGPoint(x: 105, y: 175),
            CGPoint(x: 150, y: 260), CGPoint(x: 195, y: 175),
            CGPoint(x: 200, y: 130)
        ], edges: [(0, 1), (1, 2), (2, 3), (3, 4)])
        let silhouette = MappedGroup(region: .contour, points: [
            CGPoint(x: 50, y: 200), CGPoint(x: 60, y: 120),
            CGPoint(x: 90, y: 100), CGPoint(x: 100, y: 50),
            CGPoint(x: 150, y: 10), CGPoint(x: 200, y: 50),
            CGPoint(x: 210, y: 100), CGPoint(x: 240, y: 120),
            CGPoint(x: 250, y: 200), CGPoint(x: 250, y: 400),
            CGPoint(x: 50, y: 400)
        ])
        let scalp = try XCTUnwrap(PortraitPathBuilder.hairComponent(from: [jaw, silhouette],
            style: .clean, amount: 0.45, seed: 7))
        let outline = try XCTUnwrap(PortraitPathBuilder.outlineComponent(from: [jaw, silhouette], scalp: scalp))

        XCTAssertFalse(outline.closed)
        XCTAssertEqual(outline.points.first, scalp.points.first)
        XCTAssertEqual(outline.points.last, scalp.points.last)
        XCTAssertFalse(outline.points.contains(CGPoint(x: 150, y: 10)),
                       "The body contour should not draw a second, detached scalp")
        XCTAssertTrue(outline.points.contains(CGPoint(x: 250, y: 400)),
                      "The torso part of the contour must remain")
    }

    func testPortraitCrownStaysNextToJawAcrossSeededItineraries() {
        let regions: [LandmarkRegion] = [.leftBrow, .leftEye, .nose, .rightEye,
                                         .rightBrow, .jaw, .mouth]
        let features = regions.map { region in
            PortraitPathBuilder.Component(region: region,
                points: [CGPoint(x: 10, y: 10), CGPoint(x: 20, y: 20)],
                closed: false, handedness: .unknown)
        }
        let crown = PortraitPathBuilder.Component(region: .head,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 30, y: 0)],
            closed: false, handedness: .unknown, isCrown: true)
        for seed in 0..<24 {
            let route = PortraitPathBuilder.faceItinerary(features + [crown], variation: 0.8, seed: seed)
            guard let jawIndex = route.firstIndex(where: { $0.region == .jaw }),
                  let crownIndex = route.firstIndex(where: \.isCrown) else {
                XCTFail("Every route needs its jaw and crown")
                continue
            }
            XCTAssertEqual(crownIndex, jawIndex + 1)

            let unified = PortraitPathBuilder.unifiedItinerary(
                face: features + [crown], body: [], outline: nil,
                variation: 0, detailPriority: 1, seed: seed)
            guard let unifiedJaw = unified.firstIndex(where: { $0.region == .jaw }),
                  let unifiedCrown = unified.firstIndex(where: \.isCrown) else {
                XCTFail("The unified route needs its jaw and crown")
                continue
            }
            XCTAssertEqual(unifiedCrown, unifiedJaw + 1)
        }
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
        disabled.portraitPoseBodyEnabled = false
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

    func testFingerContourTracesBothSidesOfEveryFingerAndReturnsToWrist() throws {
        let hand = sampleHandGroup()
        let narrow = try XCTUnwrap(PortraitPathBuilder.fingerContourComponent(from: hand, fullness: 0.5))
        let wide = try XCTUnwrap(PortraitPathBuilder.fingerContourComponent(from: hand, fullness: 1.8))

        XCTAssertTrue(narrow.isHandContour)
        XCTAssertEqual(narrow.handedness, .left)
        XCTAssertEqual(narrow.points.count, 61)
        XCTAssertEqual(narrow.points.first, hand.points[0])
        XCTAssertEqual(narrow.points.last, hand.points[0])
        XCTAssertEqual(narrow.points.count, wide.points.count)
        // Each fingertip has an outer rail, rounded cap, and returning rail.
        for finger in 0..<5 {
            let outerTip = 4 + finger * 12
            let innerTip = outerTip + 4
            let trackedTip = hand.points[4 + finger * 4]
            XCTAssertLessThan(hypot(narrow.points[outerTip].x - trackedTip.x,
                                    narrow.points[outerTip].y - trackedTip.y), 14)
            XCTAssertGreaterThan(hypot(wide.points[outerTip].x - wide.points[innerTip].x,
                                      wide.points[outerTip].y - wide.points[innerTip].y),
                                 hypot(narrow.points[outerTip].x - narrow.points[innerTip].x,
                                       narrow.points[outerTip].y - narrow.points[innerTip].y))
        }
    }

    func testFingerContourFallsBackWhenTooFewFingersAreTracked() {
        let complete = sampleHandGroup()
        let labels = complete.labels.enumerated().map { index, label in
            index >= 9 ? nil : label
        }
        let partial = MappedGroup(region: .hands, points: complete.points,
                                  edges: complete.edges, labels: labels)
        XCTAssertNil(PortraitPathBuilder.fingerContourComponent(from: partial, fullness: 1))

        var settings = LandmarkSettings()
        settings.portraitEnabled = true
        settings.portraitFingerContoursEnabled = true
        let outlined = PortraitDrawing().semanticRoutes(groups: [partial], landmarks: settings)
        settings.portraitFingerContoursEnabled = false
        let skeleton = PortraitDrawing().semanticRoutes(groups: [partial], landmarks: settings)
        XCTAssertEqual(outlined, skeleton)
    }

    func testSeparateHandsDoNotAcquireAConnector() {
        let left = PortraitPathBuilder.Component(region: .hands,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)],
            closed: false, handedness: .left)
        let right = PortraitPathBuilder.Component(region: .hands,
            points: [CGPoint(x: 100, y: 0), CGPoint(x: 101, y: 0)],
            closed: false, handedness: .right)
        let torso = PortraitPathBuilder.Component(region: .torso,
            points: [CGPoint(x: 3, y: 0), CGPoint(x: 4, y: 0)],
            closed: false, handedness: .unknown)

        XCTAssertFalse(PortraitPathBuilder.shouldBridge(left, right))
        XCTAssertTrue(PortraitPathBuilder.shouldBridge(left, torso))
        let crown = PortraitPathBuilder.Component(region: .head,
            points: [CGPoint(x: 0, y: -5), CGPoint(x: 10, y: -5)],
            closed: false, handedness: .unknown, isCrown: true)
        XCTAssertFalse(PortraitPathBuilder.shouldBridge(torso, crown))
        for seed in 0..<16 {
            let itinerary = PortraitPathBuilder.unifiedItinerary(
                face: [], body: [left, right, torso], outline: nil,
                variation: 0, detailPriority: 0, preferNearbyBody: true, seed: seed)
            XCTAssertEqual(itinerary.map(\.region), [.hands, .torso, .hands])
        }
    }

    func testPoseBodyRoutingPrefersNearbyLandmarksAcrossCategories() {
        let jaw = PortraitPathBuilder.Component(region: .jaw,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)],
            closed: false, handedness: .unknown)
        let mouth = PortraitPathBuilder.Component(region: .mouth,
            points: [CGPoint(x: 40, y: 0), CGPoint(x: 41, y: 0)],
            closed: false, handedness: .unknown)
        let torso = PortraitPathBuilder.Component(region: .torso,
            points: [CGPoint(x: 2, y: 0), CGPoint(x: 3, y: 0)],
            closed: false, handedness: .unknown)

        let normal = PortraitPathBuilder.unifiedItinerary(
            face: [jaw, mouth], body: [torso], outline: nil,
            variation: 0, detailPriority: 0, preferNearbyBody: false, seed: 1)
        let bodyShape = PortraitPathBuilder.unifiedItinerary(
            face: [jaw, mouth], body: [torso], outline: nil,
            variation: 0, detailPriority: 0, preferNearbyBody: true, seed: 1)
        XCTAssertEqual(normal.map(\.region), [.jaw, .mouth, .torso])
        XCTAssertEqual(bodyShape.map(\.region), [.jaw, .torso, .mouth])
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

    private func sampleHandGroup() -> MappedGroup {
        let points = [
            CGPoint(x: 110, y: 230),
            CGPoint(x: 75, y: 205), CGPoint(x: 58, y: 188), CGPoint(x: 45, y: 168), CGPoint(x: 35, y: 150),
            CGPoint(x: 85, y: 170), CGPoint(x: 80, y: 140), CGPoint(x: 77, y: 110), CGPoint(x: 75, y: 90),
            CGPoint(x: 105, y: 165), CGPoint(x: 105, y: 132), CGPoint(x: 105, y: 100), CGPoint(x: 105, y: 75),
            CGPoint(x: 125, y: 170), CGPoint(x: 129, y: 140), CGPoint(x: 132, y: 110), CGPoint(x: 135, y: 90),
            CGPoint(x: 145, y: 180), CGPoint(x: 153, y: 157), CGPoint(x: 160, y: 135), CGPoint(x: 165, y: 120)
        ]
        let edges = [
            (0, 1), (1, 2), (2, 3), (3, 4),
            (0, 5), (5, 6), (6, 7), (7, 8),
            (5, 9), (9, 10), (10, 11), (11, 12),
            (9, 13), (13, 14), (14, 15), (15, 16),
            (13, 17), (0, 17), (17, 18), (18, 19), (19, 20)
        ]
        return MappedGroup(region: .hands, points: points, edges: edges,
                           labels: (0..<21).map { "L\($0)" })
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
