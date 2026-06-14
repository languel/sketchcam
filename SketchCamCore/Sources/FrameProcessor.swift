import CoreImage
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
    /// `overlay`: optional pre-rendered transparent layer (e.g. the landmark
    /// doodle) composited over the processed frame inside the same GPU
    /// render — callers cache it across frames and re-render it only at
    /// detection cadence.
    /// `matte`: optional person-segmentation matte; the foreground stack is
    /// keyed by it over the configured background.
    /// `webLayer`: optional pre-snapshotted web page composited relative to the
    /// drawing overlay per `webAboveDrawing` (both above the video/effects).
    /// `inkLayer`: optional full-canvas inkwash feedback layer, composited
    /// according to the ink layer placement setting.
    func process(pixelBuffer: CVPixelBuffer, settings: ProcessingSettings, outputFormat: FrameFormat, frameIndex: Int, timestamp: CMTime, overlay: CIImage?, matte: CIImage?, webLayer: CIImage?, inkLayer: CIImage?, webAboveDrawing: Bool) throws -> ProcessedFrame
}

public extension FrameProcessor {
    func process(pixelBuffer: CVPixelBuffer, settings: ProcessingSettings, outputFormat: FrameFormat, frameIndex: Int, timestamp: CMTime) throws -> ProcessedFrame {
        try process(pixelBuffer: pixelBuffer, settings: settings, outputFormat: outputFormat, frameIndex: frameIndex, timestamp: timestamp, overlay: nil, matte: nil, webLayer: nil, inkLayer: nil, webAboveDrawing: true)
    }

    func process(pixelBuffer: CVPixelBuffer, settings: ProcessingSettings, outputFormat: FrameFormat, frameIndex: Int, timestamp: CMTime, overlay: CIImage?) throws -> ProcessedFrame {
        try process(pixelBuffer: pixelBuffer, settings: settings, outputFormat: outputFormat, frameIndex: frameIndex, timestamp: timestamp, overlay: overlay, matte: nil, webLayer: nil, inkLayer: nil, webAboveDrawing: true)
    }

    func process(pixelBuffer: CVPixelBuffer, settings: ProcessingSettings, outputFormat: FrameFormat, frameIndex: Int, timestamp: CMTime, overlay: CIImage?, matte: CIImage?) throws -> ProcessedFrame {
        try process(pixelBuffer: pixelBuffer, settings: settings, outputFormat: outputFormat, frameIndex: frameIndex, timestamp: timestamp, overlay: overlay, matte: matte, webLayer: nil, inkLayer: nil, webAboveDrawing: true)
    }
}
