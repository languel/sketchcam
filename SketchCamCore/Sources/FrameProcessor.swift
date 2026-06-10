import CoreMedia
import CoreVideo
import Foundation
import SketchCamShared

public struct ProcessedFrame {
    public let pixelBuffer: CVPixelBuffer
    public let sampleBuffer: CMSampleBuffer
    public let state: SketchCamState

    public init(pixelBuffer: CVPixelBuffer, sampleBuffer: CMSampleBuffer, state: SketchCamState) {
        self.pixelBuffer = pixelBuffer
        self.sampleBuffer = sampleBuffer
        self.state = state
    }
}

public protocol FrameProcessor {
    func process(pixelBuffer: CVPixelBuffer, settings: ProcessingSettings, outputFormat: FrameFormat, frameIndex: Int, timestamp: CMTime) throws -> ProcessedFrame
}

