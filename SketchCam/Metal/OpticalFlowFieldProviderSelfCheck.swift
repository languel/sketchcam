#if DEBUG
import CoreVideo
import Metal

extension OpticalFlowFieldProvider {
    static func runSyntheticTranslationSelfCheck(device: MTLDevice) {
        guard let previous = makeSquareBuffer(offsetX: 72),
              let current = makeSquareBuffer(offsetX: 80),
              let medians = debugMedianFlow(previous: previous, current: current, quality: .low)
        else {
            assertionFailure("Unable to run optical-flow translation self-check")
            return
        }
        assert(medians.x > 0.5)
        assert(abs(medians.y) < max(0.5, medians.x * 0.2))
        assert(thresholdedMagnitude(SIMD2<Float>(0.01, 0), threshold: 0.03) == 0)
        assert(thresholdedMagnitude(SIMD2<Float>(0.04, 0), threshold: 0.03) > 0)
    }

    private static func makeSquareBuffer(offsetX: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            256,
            256,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        memset(base, 0, rowBytes * 256)
        for y in 96..<160 {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
            for x in offsetX..<(offsetX + 64) {
                row[x * 4 + 0] = 255
                row[x * 4 + 1] = 255
                row[x * 4 + 2] = 255
                row[x * 4 + 3] = 255
            }
        }
        return buffer
    }
}
#endif
