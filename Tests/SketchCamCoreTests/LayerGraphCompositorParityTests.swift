import CoreImage
import CoreMedia
import XCTest
@testable import SketchCamCore
@testable import SketchCamShared

/// Phase 2: the graph-driven movable-layer compositing (`useLayerGraph = true`)
/// must be PIXEL-IDENTICAL to the legacy hardcoded order, since the graph is
/// migrated from the same placement flags.
final class LayerGraphCompositorParityTests: XCTestCase {

    private let format = FrameFormat(id: "parity", width: 80, height: 48)

    private func semiTransparent(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: r, green: g, blue: b, alpha: 0.5)).cropped(to: rect)
    }

    private func run(useGraph: Bool, inkPlacement: WebLayerPlacement, webPlacement: WebLayerPlacement) throws -> CVPixelBuffer {
        var s = ProcessingSettings()
        // Flags aligned with the images we pass, so the migrated graph contains
        // exactly the marks/ink/web layers (mirrors real ViewModel usage).
        s.landmarks.enabled = true
        s.landmarks.showStick = true          // → marks layer (overlay)
        s.landmarks.inkEnabled = true         // → ink layer
        s.landmarks.inkPlacement = inkPlacement
        s.web.enabled = true                  // → web layer
        s.web.placement = webPlacement
        s.useLayerGraph = useGraph

        let rect = CGRect(origin: .zero, size: format.size)
        let input = try PixelBufferUtils.makePixelBuffer(format: format)
        let processor = CoreImageFrameProcessor()
        let frame = try processor.process(
            pixelBuffer: input, settings: s, outputFormat: format,
            frameIndex: 0, timestamp: .zero,
            overlay: semiTransparent(1, 0, 0, rect: rect),
            matte: nil,
            webLayer: semiTransparent(0, 1, 0, rect: rect),
            inkLayer: semiTransparent(0, 0, 1, rect: rect),
            webAboveDrawing: webPlacement == .aboveDrawing
        )
        return frame.pixelBuffer
    }

    private func assertIdentical(_ a: CVPixelBuffer, _ b: CVPixelBuffer, _ msg: String) {
        CVPixelBufferLockBaseAddress(a, .readOnly); CVPixelBufferLockBaseAddress(b, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(a, .readOnly); CVPixelBufferUnlockBaseAddress(b, .readOnly) }
        let h = CVPixelBufferGetHeight(a)
        let rowA = CVPixelBufferGetBytesPerRow(a), rowB = CVPixelBufferGetBytesPerRow(b)
        XCTAssertEqual(CVPixelBufferGetWidth(a), CVPixelBufferGetWidth(b), msg)
        XCTAssertEqual(h, CVPixelBufferGetHeight(b), msg)
        guard let pa = CVPixelBufferGetBaseAddress(a), let pb = CVPixelBufferGetBaseAddress(b) else {
            return XCTFail("no base address")
        }
        let w = CVPixelBufferGetWidth(a) * 4
        for y in 0..<h {
            let cmp = memcmp(pa.advanced(by: y * rowA), pb.advanced(by: y * rowB), w)
            XCTAssertEqual(cmp, 0, "\(msg): row \(y) differs")
        }
    }

    func testParityAcrossPlacements() throws {
        let placements: [WebLayerPlacement] = [.behindDrawing, .aboveDrawing]
        for ink in placements {
            for web in placements {
                let legacy = try run(useGraph: false, inkPlacement: ink, webPlacement: web)
                let graph = try run(useGraph: true, inkPlacement: ink, webPlacement: web)
                assertIdentical(legacy, graph, "ink=\(ink.rawValue) web=\(web.rawValue)")
            }
        }
    }
}
