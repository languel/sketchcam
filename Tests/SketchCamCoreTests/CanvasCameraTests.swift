import CoreGraphics
import XCTest
@testable import SketchCamCore

final class CanvasCameraTests: XCTestCase {
    func testViewportWorldPointRoundTripsUnderPanZoomAndRotation() {
        let camera = CanvasCamera(
            center: CGPoint(x: 0.62, y: 0.37),
            viewHeight: 0.28,
            rotation: .pi / 7,
            guardFraction: 0.05
        )
        let aspect: CGFloat = 16.0 / 9.0
        let points = [
            CGPoint(x: 0, y: 0),
            CGPoint(x: 0.5, y: 0.5),
            CGPoint(x: 1, y: 1),
            CGPoint(x: 0.18, y: 0.82),
            CGPoint(x: 0.93, y: 0.12)
        ]

        for uv in points {
            let world = camera.worldPoint(fromViewportUV: uv, aspect: aspect)
            let roundTrip = camera.viewportUV(fromWorldPoint: world, aspect: aspect)
            XCTAssertEqual(roundTrip.x, uv.x, accuracy: 0.000_001)
            XCTAssertEqual(roundTrip.y, uv.y, accuracy: 0.000_001)
        }
    }

    func testRenderContextMapsCenteredInitialViewportIntoWorldPixels() {
        let context = CanvasRenderContext(
            camera: CanvasCamera(center: CGPoint(x: 0.5, y: 0.5), viewHeight: 1),
            worldPixelExtent: 8192,
            worldHeight: 1
        )

        let rect = context.worldPixelRect(aspect: 16.0 / 9.0, includeGuard: false)

        XCTAssertEqual(rect.midX, 4096, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 4096, accuracy: 0.001)
        XCTAssertEqual(rect.height, 8192, accuracy: 0.001)
        XCTAssertEqual(rect.width, 8192 * 16.0 / 9.0, accuracy: 0.001)
    }

    func testGuardBandExpandsActiveDomain() {
        let camera = CanvasCamera(center: CGPoint(x: 0.5, y: 0.5), viewHeight: 0.5, guardFraction: 0.05)
        let context = CanvasRenderContext(camera: camera, worldPixelExtent: 8192, worldHeight: 1)

        let visible = context.worldPixelRect(aspect: 1, includeGuard: false)
        let guarded = context.worldPixelRect(aspect: 1, includeGuard: true)

        XCTAssertEqual(guarded.width, visible.width * 1.1, accuracy: 0.001)
        XCTAssertEqual(guarded.height, visible.height * 1.1, accuracy: 0.001)
        XCTAssertEqual(guarded.midX, visible.midX, accuracy: 0.001)
        XCTAssertEqual(guarded.midY, visible.midY, accuracy: 0.001)
    }
}
