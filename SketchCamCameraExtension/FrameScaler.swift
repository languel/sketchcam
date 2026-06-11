import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SketchCamShared

/// Rescales host frames to the consumer-negotiated stream format when the
/// sizes differ (aspect-fill). Timer-queue confined; the CIContext and the
/// pooled output buffers are only touched on size mismatch — the common
/// matched path passes the original sample buffer through untouched.
final class FrameScaler {
    private lazy var context = CIContext(options: [.cacheIntermediates: true])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let pool = PixelBufferPool()

    func scaleIfNeeded(_ sampleBuffer: CMSampleBuffer, to format: FrameFormat) throws -> CMSampleBuffer {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return sampleBuffer
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width != format.width || height != format.height else {
            return sampleBuffer
        }

        let outputRect = CGRect(x: 0, y: 0, width: format.width, height: format.height)
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = max(outputRect.width / source.extent.width, outputRect.height / source.extent.height)
        let scaled = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let centered = scaled
            .transformed(by: CGAffineTransform(
                translationX: outputRect.midX - scaled.extent.midX,
                y: outputRect.midY - scaled.extent.midY
            ))
            .cropped(to: outputRect)

        let output = try pool.makeBuffer(format: format)
        context.render(centered, to: output, bounds: outputRect, colorSpace: colorSpace)
        return try PixelBufferUtils.makeSampleBuffer(
            pixelBuffer: output,
            formatDescription: pool.formatDescription,
            presentationTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        )
    }
}
