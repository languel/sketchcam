import CoreMedia
import CoreVideo
import Foundation
import SketchCamShared

public struct TestPatternFrame {
    public let pixelBuffer: CVPixelBuffer
    public let sampleBuffer: CMSampleBuffer
}

public enum TestPatternGenerator {
    public static func makeFrame(format: FrameFormat, frameIndex: Int, timestamp: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) throws -> TestPatternFrame {
        let pixelBuffer = try PixelBufferUtils.makePixelBuffer(format: format)
        try draw(into: pixelBuffer, frameIndex: frameIndex)
        let sampleBuffer = try PixelBufferUtils.makeSampleBuffer(pixelBuffer: pixelBuffer, presentationTime: timestamp)
        return TestPatternFrame(pixelBuffer: pixelBuffer, sampleBuffer: sampleBuffer)
    }

    public static func draw(into pixelBuffer: CVPixelBuffer, frameIndex: Int) throws {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pointer = baseAddress.assumingMemoryBound(to: UInt8.self)
        let circleX = Int((sin(Double(frameIndex) * 0.045) * 0.35 + 0.5) * Double(width))
        let circleY = Int((cos(Double(frameIndex) * 0.037) * 0.28 + 0.5) * Double(height))
        let radius = max(24, min(width, height) / 10)
        let radiusSquared = radius * radius

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * 4
                let stripe = (x / max(1, width / 8)) % 2 == 0
                let checker = ((x / 48) + (y / 48)) % 2 == 0
                let dx = x - circleX
                let dy = y - circleY
                let insideCircle = dx * dx + dy * dy < radiusSquared
                let ramp = UInt8((Double(x) / Double(max(1, width - 1))) * 180)
                let base: UInt8 = stripe ? 38 : 210
                let value: UInt8
                if insideCircle {
                    value = 255
                } else if checker {
                    value = UInt8(min(255, Int(base) + Int(ramp / 3)))
                } else {
                    value = UInt8(max(0, Int(base) - 28))
                }
                pointer[offset + 0] = value
                pointer[offset + 1] = value
                pointer[offset + 2] = value
                pointer[offset + 3] = 255
            }
        }
    }
}

