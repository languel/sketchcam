import CoreGraphics
import Foundation
import SketchCamShared

struct DebugStats {
    var cameraResolution: CGSize = .zero
    var outputFormat: FrameFormat = SketchCamFormats.defaultFormat
    var fps: Double = 0
    var frameIndex: Int = 0
    var virtualCameraStatus: String = "Disconnected"
    var stageMillis: [(stage: PipelineStage, millis: Double)] = []

    var cameraResolutionText: String {
        guard cameraResolution != .zero else { return "Test pattern" }
        return "\(Int(cameraResolution.width))x\(Int(cameraResolution.height))"
    }
}

