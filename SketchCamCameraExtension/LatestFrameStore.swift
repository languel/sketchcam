import CoreMedia
import CoreVideo
import Foundation
import SketchCamShared

final class LatestFrameStore {
    private let lock = NSLock()
    private var sampleBuffer: CMSampleBuffer?
    private var sequenceNumber: UInt64 = 0
    private var updateTime = Date.distantPast

    func update(sampleBuffer: CMSampleBuffer, sequenceNumber: UInt64) {
        lock.lock()
        self.sampleBuffer = sampleBuffer
        self.sequenceNumber = sequenceNumber
        self.updateTime = Date()
        lock.unlock()
    }

    func latest(format: FrameFormat, maxAge: TimeInterval) -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(updateTime) <= maxAge,
              let sampleBuffer,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetWidth(pixelBuffer) == format.width,
              CVPixelBufferGetHeight(pixelBuffer) == format.height else {
            return nil
        }
        return sampleBuffer
    }

    func latestSequenceNumber() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return sequenceNumber
    }
}

