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

    /// Returns the most recent host frame regardless of its dimensions —
    /// the provider rescales to the consumer-negotiated format when needed.
    /// (Rejecting mismatched sizes here is what caused the fallback stripes
    /// whenever the app's output resolution differed from what the consumer
    /// negotiated.)
    func latest(maxAge: TimeInterval) -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        guard Date().timeIntervalSince(updateTime) <= maxAge,
              let sampleBuffer,
              CMSampleBufferGetImageBuffer(sampleBuffer) != nil else {
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

