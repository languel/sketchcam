import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import SketchCamShared

final class PreviewRenderer {
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func makeImage(from pixelBuffer: CVPixelBuffer) -> CGImage? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return context.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: colorSpace)
    }

    func makeSplitImage(original: CVPixelBuffer, processed: CVPixelBuffer, outputFormat: FrameFormat) -> CGImage? {
        let outputRect = CGRect(origin: .zero, size: outputFormat.size)
        let originalImage = CIImage(cvPixelBuffer: original)
        let processedImage = CIImage(cvPixelBuffer: processed)
        let fittedOriginal = fit(originalImage, in: outputRect)
        let fittedProcessed = fit(processedImage, in: outputRect)
        let left = fittedOriginal.cropped(to: CGRect(x: 0, y: 0, width: outputRect.width / 2, height: outputRect.height))
        let right = fittedProcessed.cropped(to: CGRect(x: outputRect.width / 2, y: 0, width: outputRect.width / 2, height: outputRect.height))
        let combined = right.composited(over: left).cropped(to: outputRect)
        return context.createCGImage(combined, from: outputRect, format: .BGRA8, colorSpace: colorSpace)
    }

    private func fit(_ image: CIImage, in outputRect: CGRect) -> CIImage {
        let scale = max(outputRect.width / image.extent.width, outputRect.height / image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return scaled
            .transformed(by: CGAffineTransform(translationX: outputRect.midX - scaled.extent.midX, y: outputRect.midY - scaled.extent.midY))
            .cropped(to: outputRect)
    }
}

