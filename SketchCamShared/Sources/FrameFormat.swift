import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

public struct FrameFormat: Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public let width: Int
    public let height: Int
    public let frameRate: Int
    public let pixelFormat: OSType

    public init(id: String, width: Int, height: Int, frameRate: Int = 30, pixelFormat: OSType = kCVPixelFormatType_32BGRA) {
        self.id = id
        self.width = width
        self.height = height
        self.frameRate = frameRate
        self.pixelFormat = pixelFormat
    }

    public var size: CGSize {
        CGSize(width: width, height: height)
    }

    public var dimensions: CMVideoDimensions {
        CMVideoDimensions(width: Int32(width), height: Int32(height))
    }

    public var frameDuration: CMTime {
        CMTime(value: 1, timescale: CMTimeScale(frameRate))
    }

    public var displayName: String {
        "\(width)x\(height) @ \(frameRate) fps"
    }
}

public enum SketchCamFormats {
    public static let low = FrameFormat(id: "360p", width: 640, height: 360)
    public static let hd = FrameFormat(id: "720p", width: 1280, height: 720)
    public static let fullHD = FrameFormat(id: "1080p", width: 1920, height: 1080)

    public static let all: [FrameFormat] = [low, hd, fullHD]
    public static let defaultFormat: FrameFormat = fullHD
}
