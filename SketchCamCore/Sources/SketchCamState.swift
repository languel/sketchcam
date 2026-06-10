import CoreGraphics
import Foundation

public struct SketchCamState: Equatable, Sendable {
    public var timestamp: TimeInterval
    public var frameIndex: Int
    public var inputResolution: CGSize
    public var outputResolution: CGSize
    public var threshold: Float
    public var edgeStrength: Float
    public var invert: Bool
    public var mirror: Bool
    public var fps: Double

    public init(
        timestamp: TimeInterval = Date().timeIntervalSince1970,
        frameIndex: Int = 0,
        inputResolution: CGSize = .zero,
        outputResolution: CGSize = .zero,
        threshold: Float = 0.52,
        edgeStrength: Float = 0.25,
        invert: Bool = false,
        mirror: Bool = true,
        fps: Double = 0
    ) {
        self.timestamp = timestamp
        self.frameIndex = frameIndex
        self.inputResolution = inputResolution
        self.outputResolution = outputResolution
        self.threshold = threshold
        self.edgeStrength = edgeStrength
        self.invert = invert
        self.mirror = mirror
        self.fps = fps
    }
}

