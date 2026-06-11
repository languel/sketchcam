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
    // Pooled output buffers + cached format description: per-frame
    // CVPixelBufferCreate is a fresh IOSurface allocation each time.
    // Confined to the processing queue (process() is not reentrant).
    private let outputPool = PixelBufferPool()

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: true])) {
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
        let finalImage: CIImage

        if !settings.effectsEnabled || (!settings.thresholdEnabled && !settings.outlineEnabled) {
            // Master bypass: aspect-fill only, no filters in the DAG.
            finalImage = Self.aspectFill(source, in: outputRect, mirrored: settings.mirror)
        } else {
            // The effect chain runs at the processing resolution (cost scales
            // with area); a single upscale to the output rect happens at the
            // end of the DAG.
            let processingRect = Self.processingRect(for: outputRect, quality: settings.processingQuality)
            let fitted = Self.aspectFill(source, in: processingRect, mirrored: settings.mirror)
            let mono = fitted.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.08
            ])

            let base: CIImage
            if settings.thresholdEnabled {
                base = thresholdKernel.apply(
                    extent: processingRect,
                    arguments: [mono, CGFloat(settings.threshold), settings.invert ? CGFloat(1) : CGFloat(0)]
                ) ?? mono
            } else {
                base = mono
            }

            let processed: CIImage
            if settings.outlineEnabled, settings.edgeStrength > 0.001 {
                let edges = mono
                    .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: CGFloat(1 + settings.edgeStrength * 6)])
                    .cropped(to: processingRect)
                processed = edgeBlendKernel.apply(
                    extent: processingRect,
                    arguments: [base, edges, CGFloat(settings.edgeStrength)]
                ) ?? base
            } else {
                processed = base
            }

            finalImage = Self.upscale(processed, from: processingRect, to: outputRect)
        }

        let output = try outputPool.makeBuffer(format: outputFormat)
        context.render(finalImage, to: output, bounds: outputRect, colorSpace: colorSpace)
        let sampleBuffer = try PixelBufferUtils.makeSampleBuffer(
            pixelBuffer: output,
            formatDescription: outputPool.formatDescription,
            presentationTime: timestamp
        )
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

    static func processingRect(for outputRect: CGRect, quality: ProcessingQuality) -> CGRect {
        guard let maxHeight = quality.maxHeight, CGFloat(maxHeight) < outputRect.height else {
            return outputRect
        }
        let scale = CGFloat(maxHeight) / outputRect.height
        return CGRect(
            x: 0,
            y: 0,
            width: (outputRect.width * scale).rounded(.down),
            height: CGFloat(maxHeight)
        )
    }

    static func upscale(_ image: CIImage, from processingRect: CGRect, to outputRect: CGRect) -> CIImage {
        guard processingRect.size != outputRect.size else { return image }
        let scaleX = outputRect.width / processingRect.width
        let scaleY = outputRect.height / processingRect.height
        return image
            .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .cropped(to: outputRect)
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

