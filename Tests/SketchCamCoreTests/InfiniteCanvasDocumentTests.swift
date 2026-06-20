import CoreGraphics
import XCTest
@testable import SketchCamCore

final class InfiniteCanvasDocumentTests: XCTestCase {
    func testCameraRoundTripsAcrossAspectAndRotation() {
        let camera = CanvasCamera(center: CGPoint(x: 12, y: -4), viewHeight: 2.5, rotation: .pi / 5)
        for aspect: CGFloat in [1, 16.0 / 9.0, 9.0 / 16.0] {
            for uv in [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.87, y: 0.23)] {
                let world = camera.worldPoint(fromViewportUV: uv, aspect: aspect)
                let result = camera.viewportUV(fromWorldPoint: world, aspect: aspect)
                XCTAssertEqual(result.x, uv.x, accuracy: 0.000_001)
                XCTAssertEqual(result.y, uv.y, accuracy: 0.000_001)
            }
        }
    }

    func testCameraMetricIsIsotropic() {
        let camera = CanvasCamera()
        let aspect = CGFloat(16.0 / 9.0)
        let dx = camera.worldPoint(fromViewportUV: CGPoint(x: 0.5 + 0.1 / aspect, y: 0.5), aspect: aspect)
        let dy = camera.worldPoint(fromViewportUV: CGPoint(x: 0.5, y: 0.6), aspect: aspect)
        XCTAssertEqual(hypot(dx.x, dx.y), hypot(dy.x, dy.y), accuracy: 0.000_001)
    }

    func testRotatedBoundsIncludeGuard() {
        let camera = CanvasCamera(viewHeight: 1, rotation: .pi / 4, guardFraction: 0.05)
        let plain = camera.worldBounds(aspect: 1, includeGuard: false)
        let guarded = camera.worldBounds(aspect: 1, includeGuard: true)
        XCTAssertGreaterThan(guarded.width, plain.width)
        XCTAssertGreaterThan(guarded.height, plain.height)
    }

    func testLegacyPathMigrationPreservesIdentityAndEndpoints() {
        let id = UUID()
        let legacy = InkEditorPath(
            id: id,
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)],
            brushMode: .brush,
            width: 0.7,
            flow: 0.4,
            color: RGBAColor(red: 1, green: 0, blue: 0)
        )
        let clip = GestureClip(legacy: legacy, aspect: 2)
        XCTAssertEqual(clip.id, id)
        XCTAssertEqual(clip.kind, .wash)
        XCTAssertEqual(clip.samples.first?.position, CGPoint(x: -1, y: -0.5))
        XCTAssertEqual(clip.samples.last?.position, CGPoint(x: 1, y: 0.5))
        XCTAssertEqual(clip.strokeProfile.size, 0.7)
        XCTAssertTrue(clip.timingEstimated)
        XCTAssertGreaterThan(clip.duration, 0)
    }

    func testManifestRoundTripIncludesTypedAutomation() throws {
        let owner = UUID()
        let track = AutomationTrack(
            name: "Flow",
            address: ParameterAddress(ownerID: owner, component: "ink", parameter: "flow"),
            keyframes: [
                AutomationKeyframe(time: 0, value: .scalar(0.2), interpolation: .linear),
                AutomationKeyframe(time: 1, value: .scalar(0.9), interpolation: .smooth)
            ],
            armed: true
        )
        let manifest = SketchProjectManifest(automationTracks: [track])
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(SketchProjectManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
    }
}
