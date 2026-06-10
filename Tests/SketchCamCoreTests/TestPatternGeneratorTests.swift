import CoreMedia
import XCTest
@testable import SketchCamCore
@testable import SketchCamShared

final class TestPatternGeneratorTests: XCTestCase {
    func testTestPatternProducesExpectedDimensions() throws {
        let format = FrameFormat(id: "tiny", width: 64, height: 36)
        let frame = try TestPatternGenerator.makeFrame(format: format, frameIndex: 12)
        let pixelBuffer = frame.pixelBuffer
        XCTAssertEqual(CVPixelBufferGetWidth(pixelBuffer), 64)
        XCTAssertEqual(CVPixelBufferGetHeight(pixelBuffer), 36)
        XCTAssertNotNil(CMSampleBufferGetImageBuffer(frame.sampleBuffer))
    }

    func testTestPatternIsNotBlank() throws {
        let format = FrameFormat(id: "tiny", width: 64, height: 36)
        let frame = try TestPatternGenerator.makeFrame(format: format, frameIndex: 1)
        let pixelBuffer = frame.pixelBuffer
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let pointer = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let first = pointer[0]
        var sawDifferentValue = false
        for y in 0..<CVPixelBufferGetHeight(pixelBuffer) {
            for x in 0..<CVPixelBufferGetWidth(pixelBuffer) {
                if pointer[y * bytesPerRow + x * 4] != first {
                    sawDifferentValue = true
                    break
                }
            }
            if sawDifferentValue { break }
        }
        XCTAssertTrue(sawDifferentValue)
    }
}

