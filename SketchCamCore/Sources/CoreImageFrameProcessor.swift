import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SketchCamShared

public final class CoreImageFrameProcessor: FrameProcessor {
    private let context: CIContext
    private let thresholdKernel: CIColorKernel
    private let edgeBlendKernel: CIColorKernel
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: false])) {
        self.context = context
        self.thresholdKernel = CIColorKernel(source:
            """
            kernel vec4 sketchcam_threshold(__sample pixel, float threshold, float invert) {
                float luminance = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));
                float value = step(threshold, luminance);
                value = mix(value, 1.0 - value, step(0.5, invert));
                return vec4(value, value, value, 1.0);
            }
            """
        )!
        self.edgeBlendKernel = CIColorKernel(source:
            """
            kernel vec4 sketchcam_edge_blend(__sample base, __sample edge, float strength) {
                float edgeValue = clamp(dot(edge.rgb, vec3(0.333, 0.333, 0.333)) * strength, 0.0, 1.0);
                float value = clamp(base.r - edgeValue, 0.0, 1.0);
                return vec4(value, value, value, 1.0);
            }
            """
        )!
    }

    public func process(pixelBuffer: CVPixelBuffer, settings: ProcessingSettings, outputFormat: FrameFormat, frameIndex: Int, timestamp: CMTime) throws -> ProcessedFrame {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let outputRect = CGRect(origin: .zero, size: outputFormat.size)
        let fitted = Self.aspectFill(source, in: outputRect, mirrored: settings.mirror)
        let mono = fitted.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0,
            kCIInputContrastKey: 1.08
        ])

        let threshold = thresholdKernel.apply(
            extent: outputRect,
            arguments: [mono, CGFloat(settings.threshold), settings.invert ? CGFloat(1) : CGFloat(0)]
        ) ?? mono

        let finalImage: CIImage
        if settings.edgeStrength > 0.001 {
            let edges = mono
                .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: CGFloat(1 + settings.edgeStrength * 6)])
                .cropped(to: outputRect)
            finalImage = edgeBlendKernel.apply(
                extent: outputRect,
                arguments: [threshold, edges, CGFloat(settings.edgeStrength)]
            ) ?? threshold
        } else {
            finalImage = threshold
        }

        let output = try PixelBufferUtils.makePixelBuffer(format: outputFormat)
        context.render(finalImage, to: output, bounds: outputRect, colorSpace: colorSpace)
        let sampleBuffer = try PixelBufferUtils.makeSampleBuffer(pixelBuffer: output, presentationTime: timestamp)
        let state = SketchCamState(
            timestamp: timestamp.seconds,
            frameIndex: frameIndex,
            inputResolution: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer)),
            outputResolution: outputFormat.size,
            threshold: settings.threshold,
            edgeStrength: settings.edgeStrength,
            invert: settings.invert,
            mirror: settings.mirror
        )
        return ProcessedFrame(pixelBuffer: output, sampleBuffer: sampleBuffer, state: state)
    }

    public static func aspectFill(_ image: CIImage, in outputRect: CGRect, mirrored: Bool) -> CIImage {
        var working = image
        let inputExtent = working.extent
        if mirrored {
            let mirror = CGAffineTransform(translationX: inputExtent.midX, y: inputExtent.midY)
                .scaledBy(x: -1, y: 1)
                .translatedBy(x: -inputExtent.midX, y: -inputExtent.midY)
            working = working.transformed(by: mirror)
        }

        let scale = max(outputRect.width / working.extent.width, outputRect.height / working.extent.height)
        working = working.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translated = working.transformed(by: CGAffineTransform(
            translationX: outputRect.midX - working.extent.midX,
            y: outputRect.midY - working.extent.midY
        ))
        return translated.cropped(to: outputRect)
    }
}

