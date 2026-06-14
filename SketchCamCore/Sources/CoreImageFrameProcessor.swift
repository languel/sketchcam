import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SketchCamShared

public final class CoreImageFrameProcessor: FrameProcessor {
    private let context: CIContext
    private let thresholdKernel: CIColorKernel
    private let edgeMaskKernel: CIColorKernel
    private let edgeColorKernel: CIColorKernel
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    // Pooled output buffers + cached format description: per-frame
    // CVPixelBufferCreate is a fresh IOSurface allocation each time.
    // Confined to the processing queue (process() is not reentrant).
    private let outputPool = PixelBufferPool()

    public init(context: CIContext = CIContext(options: [.cacheIntermediates: true])) {
        self.context = context
        self.thresholdKernel = CIColorKernel(source:
            """
            kernel vec4 sketchcam_threshold(__sample pixel, float threshold, float invert, float inkOnly) {
                float luminance = dot(pixel.rgb, vec3(0.299, 0.587, 0.114));
                float value = step(threshold, luminance);
                value = mix(value, 1.0 - value, step(0.5, invert));
                // normal: opaque paper+ink; inkOnly: black ink on transparent paper
                vec4 opaque = vec4(value, value, value, 1.0);
                vec4 inked = vec4(0.0, 0.0, 0.0, 1.0 - value);
                return mix(opaque, inked, step(0.5, inkOnly));
            }
            """
        )!
        // Binarize the raw edge response BEFORE dilation: any edge above the
        // sensitivity cutoff becomes a solid stroke (narrow smoothstep band
        // for antialiasing). Without this, stroke opacity tracks edge
        // intensity and soft edges render as a washy translucent blur.
        self.edgeMaskKernel = CIColorKernel(source:
            """
            kernel vec4 sketchcam_edge_mask(__sample edge, float cutoff) {
                float luminance = dot(edge.rgb, vec3(0.333, 0.333, 0.333));
                float v = smoothstep(cutoff - 0.04, cutoff + 0.04, luminance);
                return vec4(v, v, v, 1.0);
            }
            """
        )!
        self.edgeColorKernel = CIColorKernel(source:
            """
            kernel vec4 sketchcam_edge_color(__sample mask, vec4 strokeColor) {
                float a = clamp(dot(mask.rgb, vec3(0.333, 0.333, 0.333)), 0.0, 1.0) * strokeColor.a;
                return vec4(strokeColor.rgb * a, a);
            }
            """
        )!
    }

    public func process(pixelBuffer: CVPixelBuffer, settings: ProcessingSettings, outputFormat: FrameFormat, frameIndex: Int, timestamp: CMTime, overlay: CIImage?, matte: CIImage?, webLayer: CIImage?, webAboveDrawing: Bool) throws -> ProcessedFrame {
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        let outputRect = CGRect(origin: .zero, size: outputFormat.size)
        var finalImage: CIImage

        let effectsActive = settings.effectsEnabled && (settings.thresholdEnabled || settings.outlineEnabled)
        let plainPassthrough = !effectsActive
            && settings.inputLayerEnabled
            && settings.backgroundMode == .live
            && matte == nil

        if plainPassthrough {
            // Master bypass: aspect-fill only, no filters in the DAG.
            finalImage = Self.aspectFill(source, in: outputRect, mirrored: settings.mirror)
        } else {
            // The layer stack runs at the processing resolution (cost scales
            // with area); a single upscale to the output rect happens at the
            // end of the DAG. Layers, bottom to top:
            //   background (live video / solid color / transparent)
            //   video layer (thresholded or raw), optionally keyed by matte
            //   outline strokes (colored, dilated), keyed with the video layer
            let processingRect = Self.processingRect(for: outputRect, quality: settings.processingQuality)
            let fitted = Self.aspectFill(source, in: processingRect, mirrored: settings.mirror)
            let mono = fitted.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0,
                kCIInputContrastKey: 1.08
            ])

            let background: CIImage
            switch settings.backgroundMode {
            case .live:
                background = fitted
            case .solid:
                background = CIImage(color: CIColor(
                    red: CGFloat(settings.backgroundColor.red),
                    green: CGFloat(settings.backgroundColor.green),
                    blue: CGFloat(settings.backgroundColor.blue),
                    alpha: CGFloat(settings.backgroundColor.alpha)
                )).cropped(to: processingRect)
            case .transparent:
                background = CIImage(color: .clear).cropped(to: processingRect)
            }

            // Foreground stack: video layer + outline strokes.
            var foreground: CIImage?
            if matte != nil, settings.segmentation.mode == .silhouette {
                // Silhouette mode: the person becomes a flat color fill
                // (the matte itself is the visual); outline strokes still
                // composite on top below, masked with the rest.
                foreground = CIImage(color: CIColor(
                    red: CGFloat(settings.segmentation.silhouetteColor.red),
                    green: CGFloat(settings.segmentation.silhouetteColor.green),
                    blue: CGFloat(settings.segmentation.silhouetteColor.blue),
                    alpha: CGFloat(settings.segmentation.silhouetteColor.alpha)
                )).cropped(to: processingRect)
            } else if settings.inputLayerEnabled {
                if effectsActive, settings.thresholdEnabled {
                    foreground = thresholdKernel.apply(
                        extent: processingRect,
                        arguments: [
                            mono,
                            CGFloat(settings.threshold),
                            settings.invert ? CGFloat(1) : CGFloat(0),
                            settings.thresholdInkOnly ? CGFloat(1) : CGFloat(0)
                        ]
                    ) ?? mono
                } else {
                    foreground = fitted
                }
            }

            var strokes: CIImage?
            if effectsActive, settings.outlineEnabled, settings.edgeStrength > 0.001 {
                let edges = mono
                    .applyingFilter("CIEdges", parameters: [kCIInputIntensityKey: CGFloat(1 + settings.edgeStrength * 6)])
                    .cropped(to: processingRect)
                // Strength = edge sensitivity: low keeps only strong
                // contours, high picks up fine detail. The cutoff binarizes
                // the response so strokes are solid color, then dilation
                // thickens the solid mask.
                let cutoff = CGFloat(0.55 - 0.5 * min(1, max(0, settings.edgeStrength)))
                let mask = edgeMaskKernel.apply(
                    extent: processingRect,
                    arguments: [edges, cutoff]
                ) ?? edges
                let thickened = Self.thicken(mask, radius: settings.outlineThickness)
                strokes = edgeColorKernel.apply(
                    extent: processingRect,
                    arguments: [
                        thickened,
                        CIVector(
                            x: CGFloat(settings.outlineColor.red),
                            y: CGFloat(settings.outlineColor.green),
                            z: CGFloat(settings.outlineColor.blue),
                            w: CGFloat(settings.outlineColor.alpha)
                        )
                    ]
                )
            }
            // Without a matte the strokes are just the top of the
            // foreground stack. With a matte they stay separate: the
            // outline belongs to the SUBJECT, so it is masked by the
            // person matte (never inverted) and composited on top after
            // the key — inverting the key must not move the outline to
            // the background region.
            if matte == nil, let strokes {
                foreground = foreground.map { strokes.composited(over: $0) } ?? strokes
            }

            let composed: CIImage
            if let matte {
                // Vision mattes come back at their own (often square)
                // resolution — stretch to the source frame's geometry
                // FIRST so the subsequent aspect-fill matches the video
                // exactly; aspect-filling the raw matte misaligns it.
                let matteInSourceSpace = matte.transformed(by: CGAffineTransform(
                    scaleX: source.extent.width / max(1, matte.extent.width),
                    y: source.extent.height / max(1, matte.extent.height)
                ))
                let personMatte = Self.aspectFill(matteInSourceSpace, in: processingRect, mirrored: settings.mirror)
                let keyMatte: CIImage
                if settings.segmentation.inverted {
                    keyMatte = personMatte
                        .applyingFilter("CIColorInvert")
                        .cropped(to: personMatte.extent)
                } else {
                    keyMatte = personMatte
                }

                // Person key: foreground only where the (possibly inverted)
                // key matte allows; background everywhere else.
                var keyed = (foreground ?? CIImage(color: .clear).cropped(to: processingRect))
                    .cropped(to: processingRect)
                    .applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: background,
                        kCIInputMaskImageKey: keyMatte
                    ])
                    .cropped(to: processingRect)

                if let strokes {
                    let subjectStrokes = strokes.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: processingRect),
                        kCIInputMaskImageKey: personMatte
                    ]).cropped(to: processingRect)
                    keyed = subjectStrokes.composited(over: keyed).cropped(to: processingRect)
                }
                composed = keyed
            } else if let foreground {
                // The video layer is opaque (raw video, or threshold in
                // paper mode) — skip the composite. Ink-only threshold
                // has real alpha and must blend over the background.
                let videoLayerOpaque = settings.inputLayerEnabled
                    && !(effectsActive && settings.thresholdEnabled && settings.thresholdInkOnly)
                if videoLayerOpaque {
                    composed = foreground.cropped(to: processingRect)
                } else {
                    composed = foreground.composited(over: background).cropped(to: processingRect)
                }
            } else {
                composed = background
            }

            finalImage = Self.upscale(composed, from: processingRect, to: outputRect)
        }

        // Layer order (above the video/effects): web-behind → drawing → web-above.
        if let webLayer, !webAboveDrawing {
            finalImage = webLayer.composited(over: finalImage).cropped(to: outputRect)
        }
        if let overlay {
            finalImage = overlay.composited(over: finalImage).cropped(to: outputRect)
        }
        if let webLayer, webAboveDrawing {
            finalImage = webLayer.composited(over: finalImage).cropped(to: outputRect)
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

    static func thicken(_ edges: CIImage, radius: Float) -> CIImage {
        let clamped = min(24, max(0, radius))
        guard clamped > 1.05 else { return edges }
        return edges.applyingFilter("CIMorphologyMaximum", parameters: [
            kCIInputRadiusKey: CGFloat(clamped)
        ])
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

