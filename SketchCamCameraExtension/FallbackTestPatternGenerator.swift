import CoreMedia
import CoreVideo
import Foundation
import SketchCamShared

enum FallbackTestPatternGenerator {
    static func makeSampleBuffer(format: FrameFormat, frameIndex: Int) throws -> CMSampleBuffer {
        let pixelBuffer = try PixelBufferUtils.makePixelBuffer(format: format)
        draw(into: pixelBuffer, frameIndex: frameIndex)
        return try PixelBufferUtils.makeSampleBuffer(pixelBuffer: pixelBuffer)
    }

    private static func draw(into pixelBuffer: CVPixelBuffer, frameIndex: Int) {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let stripeHeight = max(8, height / 36)
        let movingRow = abs((frameIndex * 7) % (height * 2) - height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let isMovingStripe = abs(y - movingRow) < stripeHeight
                let tile = ((x / 64) + (y / 64)) % 2 == 0
                let diagonal = (x + y + frameIndex * 4) % 180 < 24
                let value: UInt8
                if isMovingStripe {
                    value = 255
                } else if diagonal {
                    value = 190
                } else {
                    value = tile ? 48 : 18
                }
                pointer[offset + 0] = value
                pointer[offset + 1] = value
                pointer[offset + 2] = value
                pointer[offset + 3] = 255
            }
        }
    }
}

