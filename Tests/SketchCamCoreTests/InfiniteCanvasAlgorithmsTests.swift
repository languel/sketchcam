import CoreGraphics
import XCTest
@testable import SketchCamCore

final class InfiniteCanvasAlgorithmsTests: XCTestCase {
    func testSimplifierPreservesCorner() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.5, y: 1)]
        XCTAssertEqual(CurveFitter.simplify(points, tolerance: 0.01), points)
    }

    func testFittedCurveRetainsEndpoints() {
        let samples = [GestureSample(position: .zero, time: 0), GestureSample(position: CGPoint(x: 1, y: 1), time: 1)]
        let curve = CurveFitter.fit(samples: samples, recipe: .hobby)
        XCTAssertEqual(curve.anchors.first?.position, .zero)
        XCTAssertEqual(curve.anchors.last?.position, CGPoint(x: 1, y: 1))
        XCTAssertEqual(curve.sampled().first, .zero)
        XCTAssertEqual(curve.sampled().last?.x ?? -1, 1, accuracy: 0.000_001)
    }

    func testOutlineCreatesClosedSidedPolygon() {
        let samples = [GestureSample(position: .zero, time: 0, pressure: 0.2), GestureSample(position: CGPoint(x: 1, y: 0), time: 1, pressure: 1)]
        let curve = CurveFitter.fit(samples: samples, recipe: .polyline)
        let outline = ExpressiveStrokeBuilder.outline(samples: samples, curve: curve, profile: StrokeProfile(size: 1, thinning: 0.8))
        XCTAssertGreaterThan(outline.count, curve.sampled().count)
        XCTAssertGreaterThan(abs(outline.last?.y ?? 0), 0)
    }

    func testAutomationInterpolatesAndHolds() {
        let address = ParameterAddress(ownerID: UUID(), component: "ink", parameter: "flow")
        let smooth = AutomationTrack(name: "Flow", address: address, keyframes: [
            AutomationKeyframe(time: 0, value: .scalar(0), interpolation: .linear),
            AutomationKeyframe(time: 2, value: .scalar(1))
        ])
        XCTAssertEqual(TimelineEvaluator.value(on: smooth, at: 1), .scalar(0.5))
        let hold = AutomationTrack(name: "Flow", address: address, keyframes: [
            AutomationKeyframe(time: 0, value: .scalar(0), interpolation: .hold),
            AutomationKeyframe(time: 2, value: .scalar(1))
        ])
        XCTAssertEqual(TimelineEvaluator.value(on: hold, at: 1), .scalar(0))
    }

    func testCameraUsesShortestRotationPath() {
        let track = CameraTrack(keyframes: [
            CameraKeyframe(time: 0, camera: CanvasCamera(rotation: .pi * 0.9), interpolation: .linear),
            CameraKeyframe(time: 1, camera: CanvasCamera(rotation: -.pi * 0.9))
        ])
        let middle = TimelineEvaluator.camera(on: track, at: 0.5)
        XCTAssertEqual(abs(middle?.rotation ?? 0), .pi, accuracy: 0.000_001)
    }

    func testTileLayoutIsSparseAndStableAcrossNegativeCoordinates() {
        let bounds = CGRect(x: -0.2, y: -0.2, width: 0.4, height: 0.4)
        let indices = WorldTileLayout.indices(intersecting: bounds, level: 0, baseDensity: 512)
        XCTAssertEqual(indices.count, 4)
        XCTAssertTrue(indices.contains(WorldTileIndex(level: 0, x: -1, y: -1)))
        XCTAssertTrue(indices.contains(WorldTileIndex(level: 0, x: 0, y: 0)))
    }
}
