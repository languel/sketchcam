import CoreMedia
import XCTest
@testable import SketchCamCore
@testable import SketchCamShared

final class CoreImageFrameProcessorTests: XCTestCase {
    func testProcessorReturnsRequestedOutputFormat() throws {
        let inputFormat = FrameFormat(id: "input", width: 64, height: 36)
        let input = try PixelBufferUtils.makePixelBuffer(format: inputFormat)
        fillGradient(input)

        let outputFormat = FrameFormat(id: "output", width: 128, height: 72)
        let processor = CoreImageFrameProcessor()
        let processed = try processor.process(
            pixelBuffer: input,
            settings: ProcessingSettings(threshold: 0.5, edgeStrength: 0, invert: false, mirror: true),
            outputFormat: outputFormat,
            frameIndex: 7,
            timestamp: CMTime(value: 7, timescale: 30)
        )

        XCTAssertEqual(CVPixelBufferGetWidth(processed.pixelBuffer), outputFormat.width)
        XCTAssertEqual(CVPixelBufferGetHeight(processed.pixelBuffer), outputFormat.height)
        XCTAssertEqual(processed.state.frameIndex, 7)
        XCTAssertEqual(processed.state.outputResolution, outputFormat.size)
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(processed.sampleBuffer))
    }

    private func fillGradient(_ pixelBuffer: CVPixelBuffer) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let pointer = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let value = UInt8((Double(x) / Double(max(1, width - 1))) * 255)
                pointer[offset + 0] = value
                pointer[offset + 1] = value
                pointer[offset + 2] = value
                pointer[offset + 3] = 255
            }
        }
    }
}

