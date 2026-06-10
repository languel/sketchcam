import CoreMedia
import CoreVideo
import Foundation

public enum PixelBufferUtils {
    public enum PixelBufferError: Error, LocalizedError {
        case allocationFailed(OSStatus)
        case formatDescriptionFailed(OSStatus)
        case sampleBufferFailed(OSStatus)

        public var errorDescription: String? {
            switch self {
            case let .allocationFailed(status):
                return "Could not allocate pixel buffer: \(status)"
            case let .formatDescriptionFailed(status):
                return "Could not create video format description: \(status)"
            case let .sampleBufferFailed(status):
                return "Could not create sample buffer: \(status)"
            }
        }
    }

    public static func makePixelBuffer(format: FrameFormat) throws -> CVPixelBuffer {
        let attributes: [CFString: Any] = [
            kCVPixelBufferWidthKey: format.width,
            kCVPixelBufferHeightKey: format.height,
            kCVPixelBufferPixelFormatTypeKey: format.pixelFormat,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]

        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, format.width, format.height, format.pixelFormat, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw PixelBufferError.allocationFailed(status)
        }
        return pixelBuffer
    }

    public static func makeFormatDescription(format: FrameFormat) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: format.pixelFormat,
            width: Int32(format.width),
            height: Int32(format.height),
            extensions: nil,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw PixelBufferError.formatDescriptionFailed(status)
        }
        return description
    }

    public static func makeFormatDescription(pixelBuffer: CVPixelBuffer) throws -> CMVideoFormatDescription {
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        )
        guard status == noErr, let description else {
            throw PixelBufferError.formatDescriptionFailed(status)
        }
        return description
    }

    public static func makeSampleBuffer(pixelBuffer: CVPixelBuffer, formatDescription: CMVideoFormatDescription? = nil, presentationTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) throws -> CMSampleBuffer {
        let description = try formatDescription ?? makeFormatDescription(pixelBuffer: pixelBuffer)
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw PixelBufferError.sampleBufferFailed(status)
        }
        return sampleBuffer
    }

    public static func hostTimeNanoseconds(for time: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) -> UInt64 {
        UInt64(max(0, time.seconds) * Double(NSEC_PER_SEC))
    }
}

