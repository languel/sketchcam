import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SketchCamCore
import SketchCamShared

/// v2 GPU compositor: walks the layer graph bottom→top and composites each
/// visible layer's *stream* on the GPU — per-layer Metal effect chain + mask +
/// opacity — with no hardcoded base. Stream pixels arrive as output-sized
/// CIImages (camera/solid/paper/drawing/ink/web/personMatte) which are
/// rasterized into IOSurface buffers and fed to `MetalEffects`.
///
/// This is the experimental path behind `ProcessingSettings.useGPUCompositor`;
/// the CoreImage `process(...)` stays the default until this reaches parity.
final class MetalLayerCompositor {
    /// Resolves a graph node (or the built-in person-matte source) to its
    /// output-sized stream pixels. Returns nil for a node with no pixels yet.
    struct Streams {
        var image: (Node) -> CIImage?
        var imageMaterial: (WorkspaceImageConfig) -> CIImage? = { _ in nil }
        var personMatte: CIImage?
    }

    private let effects: MetalEffects
    private let ciContext: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let pool = PixelBufferPool()       // persistent working buffers
    private let outPool = PixelBufferPool()    // per-frame published output

    // Persistent working buffers, reallocated on size change. Holding all of
    // them alive at once keeps the pool vending distinct IOSurfaces.
    private var size: CGSize = .zero
    private var accumA, accumB, content, masked, fxScratch, matteBuf, sourceFx: CVPixelBuffer?
    private var routeSize: CGSize = .zero
    private var routeInput, routeOutput, routeScratch, routeMatte: CVPixelBuffer?

    init?(ciContext: CIContext) {
        guard let fx = MetalEffects() else { return nil }
        self.effects = fx
        self.ciContext = ciContext
    }

    /// Composite the graph into a fresh output frame, or nil on failure (caller
    /// falls back to the CoreImage path).
    func composite(graph: LayerGraph, streams: Streams, outputFormat: FrameFormat,
                   workspace: CollageWorkspace? = nil,
                   frameIndex: Int, timestamp: CMTime, mirror: Bool) -> ProcessedFrame? {
        guard ensureBuffers(for: outputFormat) else { return nil }
        let rect = CGRect(origin: .zero, size: outputFormat.size)
        guard let accumA, let accumB, let content, let masked, let fxScratch, let matteBuf, let sourceFx else { return nil }

        // Start from a transparent canvas.
        rasterize(CIImage(color: .clear).cropped(to: rect), into: accumA)
        var cur = accumA, other = accumB

        let items = renderItems(graph: graph, streams: streams, workspace: workspace, outputFormat: outputFormat)
        for item in items where item.opacity > 0.001 {
            guard let img = item.image else { continue }
            clear(content)
            rasterize(img, into: content)

            // Layer masks clip the raw source first. Effect-chain Person Key still
            // lives in the chain below, so it affects the chain at its own position.
            var chainInput = content
            var chainOutput = masked
            if let mask = item.mask {
                if case .source(.personMatte) = mask.source, let personMatte = streams.personMatte {
                    rasterize(personMatte, into: matteBuf)
                    let invert = mask.personKeyInvert != mask.invert
                    if mask.personKeySilhouette {
                        let c = SIMD4<Float>(mask.personKeyColor.red, mask.personKeyColor.green,
                                             mask.personKeyColor.blue, mask.personKeyColor.alpha)
                        guard effects.silhouette(matte: matteBuf, output: masked, color: c, invert: invert) else { return nil }
                        if mask.mode != .luma {
                            guard effects.mask(content: masked, matte: matteBuf, output: content,
                                               mode: mask.mode, level: mask.level, invert: invert) else { return nil }
                            chainInput = content
                            chainOutput = masked
                        } else {
                            chainInput = masked
                            chainOutput = content
                        }
                    } else {
                        guard effects.mask(content: content, matte: matteBuf, output: masked,
                                           mode: mask.mode, level: mask.level, invert: invert) else { return nil }
                        chainInput = masked
                        chainOutput = content
                    }
                } else if let matte = maskBuffer(for: mask.source, graph: graph, streams: streams,
                                                 raw: matteBuf, processed: fxScratch, scratch: masked,
                                                 personMatteScratch: sourceFx, frameIndex: frameIndex) {
                    guard effects.mask(content: content, matte: matte, output: masked,
                                       mode: mask.mode, level: mask.level, invert: mask.invert) else { return nil }
                    chainInput = masked
                    chainOutput = content
                }
            }

            // A personKey (or other matte-using) effect needs the person matte
            // rasterized into a buffer for the chain.
            var chainMatte: CVPixelBuffer? = nil
            if item.effects.contains(where: { $0.enabled && $0.kind.needsPersonMatte }), let pm = streams.personMatte {
                rasterize(pm, into: matteBuf)
                chainMatte = matteBuf
            }

            // Per-layer effect chain after source masking.
            guard effects.applyChain(input: chainInput, output: chainOutput, scratch: fxScratch,
                                     effects: item.effects, matte: chainMatte, frameIndex: frameIndex) else { return nil }

            // Composite onto the accumulator with the layer opacity/blend mode.
            guard effects.composite(base: cur, overlay: chainOutput, output: other,
                                    opacity: item.opacity, blend: item.blend) else { return nil }
            swap(&cur, &other)
        }

        // `cur` holds the result; hand back a copy from the pool so the working
        // buffers stay ours for the next frame.
        guard let output = try? outPool.makeBuffer(format: outputFormat),
              effects.copy(input: cur, output: output) else { return nil }
        guard let sampleBuffer = try? PixelBufferUtils.makeSampleBuffer(
            pixelBuffer: output, formatDescription: outPool.formatDescription, presentationTime: timestamp) else { return nil }

        let state = SketchCamState(
            timestamp: timestamp.seconds, frameIndex: frameIndex,
            inputResolution: outputFormat.size, outputResolution: outputFormat.size,
            threshold: 0, edgeStrength: 0, invert: false, mirror: mirror)
        return ProcessedFrame(pixelBuffer: output, sampleBuffer: sampleBuffer, state: state)
    }

    private struct RenderItem {
        var image: CIImage?
        var effects: [EffectConfig]
        var mask: MaskBinding?
        var opacity: Float
        var blend: BlendMode
    }

    private func renderItems(
        graph: LayerGraph,
        streams: Streams,
        workspace: CollageWorkspace?,
        outputFormat: FrameFormat
    ) -> [RenderItem] {
        guard let workspace else {
            return graph.layers.compactMap { layer in
                guard layer.visible,
                      let node = graph.node(layer.node) else { return nil }
                return RenderItem(
                    image: streams.image(node),
                    effects: layer.effects,
                    mask: layer.mask,
                    opacity: layer.opacity,
                    blend: layer.blend
                )
            }
        }

        let viewport = workspace.outputViewport.frame
        return workspace.visibleOutputFrames().compactMap { frame in
            guard let resolved = resolveFrame(frame, graph: graph, streams: streams, viewport: viewport, outputFormat: outputFormat) else {
                return nil
            }
            return resolved
        }
    }

    private func resolveFrame(
        _ frame: WorkspaceFrame,
        graph: LayerGraph,
        streams: Streams,
        viewport: CGRect,
        outputFormat: FrameFormat
    ) -> RenderItem? {
        let image: CIImage?
        let layer: Layer?
        switch frame.material {
        case .layer(let layerID):
            layer = graph.layers.first { $0.id == layerID }
            guard let layer, let node = graph.node(layer.node) else { return nil }
            image = streams.image(node)
        case .node(let nodeID):
            layer = graph.layers.first { $0.node == nodeID }
            guard let node = graph.node(nodeID) else { return nil }
            image = streams.image(node)
        case .image(let config):
            layer = nil
            image = streams.imageMaterial(config)
        case .outputViewport:
            layer = nil
            image = nil
        }
        guard let transformed = image.flatMap({ transform($0, for: frame, viewport: viewport, outputFormat: outputFormat) }) else {
            return nil
        }
        return RenderItem(
            image: transformed,
            effects: layer?.effects ?? [],
            mask: frame.mask ?? layer?.mask,
            opacity: max(0, min(1, frame.opacity)),
            blend: frame.blend
        )
    }

    private func transform(
        _ image: CIImage,
        for frame: WorkspaceFrame,
        viewport: CGRect,
        outputFormat: FrameFormat
    ) -> CIImage? {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0,
              frame.localBounds.width > 0, frame.localBounds.height > 0 else { return nil }
        let cropUnit = frame.cropRect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard cropUnit.width > 0, cropUnit.height > 0 else { return nil }
        let crop = CGRect(
            x: extent.minX + cropUnit.minX * extent.width,
            y: extent.minY + cropUnit.minY * extent.height,
            width: cropUnit.width * extent.width,
            height: cropUnit.height * extent.height
        )
        guard crop.width > 0, crop.height > 0 else { return nil }

        var result = image.cropped(to: crop)
        result = result.transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))

        let target = frame.localBounds.insetBy(dx: -frame.bleed, dy: -frame.bleed)
        let scaleX: CGFloat
        let scaleY: CGFloat
        let offsetX: CGFloat
        let offsetY: CGFloat
        switch frame.contentFit {
        case .stretch:
            scaleX = target.width / crop.width
            scaleY = target.height / crop.height
            offsetX = target.minX
            offsetY = target.minY
        case .fit, .fill:
            let uniform = frame.contentFit == .fit
                ? min(target.width / crop.width, target.height / crop.height)
                : max(target.width / crop.width, target.height / crop.height)
            scaleX = uniform
            scaleY = uniform
            offsetX = target.minX + (target.width - crop.width * uniform) * 0.5
            offsetY = target.minY + (target.height - crop.height * uniform) * 0.5
        }
        result = result.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        result = result.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        result = result.transformed(by: frame.transform.cgAffineTransform)
        result = result.transformed(by: CGAffineTransform(translationX: -viewport.minX, y: -viewport.minY))
        return result.cropped(to: CGRect(origin: .zero, size: outputFormat.size))
    }

    /// Materialize a layer's post-effect pixels for downstream node routing.
    /// This deliberately uses dedicated buffers: the returned CIImage remains
    /// valid while the main compositor reuses its own working set later in the frame.
    func layerOutput(nodeID: UUID, graph: LayerGraph, streams: Streams,
                     outputFormat: FrameFormat, frameIndex: Int) -> CIImage? {
        guard let node = graph.node(nodeID),
              let raw = streams.image(node),
              let layer = graph.layers.first(where: { $0.node == nodeID })
        else { return nil }
        let enabledEffects = layer.effects.filter(\.enabled)
        guard !enabledEffects.isEmpty || layer.mask != nil || layer.opacity < 0.999 else { return raw }
        guard ensureRouteBuffers(for: outputFormat),
              let routeInput, let routeOutput, let routeScratch, let routeMatte else { return raw }
        rasterize(raw, into: routeInput)
        var chainInput = routeInput
        var chainOutput = routeOutput
        if let mask = layer.mask {
            let matteImage: CIImage?
            switch mask.source {
            case .source(.personMatte): matteImage = streams.personMatte
            case .node(let id): matteImage = graph.node(id).flatMap(streams.image)
            default: matteImage = nil
            }
            if let matteImage {
                rasterize(matteImage, into: routeMatte)
                let invert = mask.source == .source(.personMatte)
                    ? mask.personKeyInvert != mask.invert
                    : mask.invert
                guard effects.mask(content: routeInput, matte: routeMatte, output: routeOutput,
                                   mode: mask.mode, level: mask.level, invert: invert) else { return raw }
                chainInput = routeOutput
                chainOutput = routeInput
            }
        }
        var effectMatte: CVPixelBuffer? = nil
        if enabledEffects.contains(where: { $0.kind.needsPersonMatte }),
           let personMatte = streams.personMatte {
            rasterize(personMatte, into: routeMatte)
            effectMatte = routeMatte
        }
        guard effects.applyChain(input: chainInput, output: chainOutput, scratch: routeScratch,
                                 effects: enabledEffects, matte: effectMatte, frameIndex: frameIndex) else { return raw }
        var image = CIImage(cvPixelBuffer: chainOutput).cropped(to: CGRect(origin: .zero, size: outputFormat.size))
        if layer.opacity < 0.999 {
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(max(0, layer.opacity)))
            ])
        }
        return image
    }

    // MARK: - Helpers

    private func maskBuffer(for source: PortBinding, graph: LayerGraph, streams: Streams,
                            raw: CVPixelBuffer, processed: CVPixelBuffer, scratch: CVPixelBuffer,
                            personMatteScratch: CVPixelBuffer, frameIndex: Int) -> CVPixelBuffer? {
        switch source {
        case .none:
            return nil
        case .source(let s):
            guard s == .personMatte, let personMatte = streams.personMatte else { return nil }
            rasterize(personMatte, into: raw)
            return raw
        case .node(let id):
            guard let node = graph.node(id), let image = streams.image(node) else { return nil }
            rasterize(image, into: raw)
            guard let layer = graph.layers.first(where: { $0.node == id }),
                  layer.effects.contains(where: { $0.enabled }) else {
                return raw
            }
            var chainMatte: CVPixelBuffer? = nil
            if layer.effects.contains(where: { $0.enabled && $0.kind.needsPersonMatte }),
               let personMatte = streams.personMatte {
                rasterize(personMatte, into: personMatteScratch)
                chainMatte = personMatteScratch
            }
            guard effects.applyChain(input: raw, output: processed, scratch: scratch,
                                     effects: layer.effects, matte: chainMatte, frameIndex: frameIndex) else { return nil }
            return processed
        }
    }

    private func rasterize(_ image: CIImage, into buffer: CVPixelBuffer) {
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        ciContext.render(image, to: buffer, bounds: rect, colorSpace: colorSpace)
    }

    private func clear(_ buffer: CVPixelBuffer) {
        let rect = CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        ciContext.render(CIImage(color: .clear).cropped(to: rect), to: buffer, bounds: rect, colorSpace: colorSpace)
    }

    private func ensureBuffers(for format: FrameFormat) -> Bool {
        if size == format.size, accumA != nil { return true }
        func make() -> CVPixelBuffer? { try? pool.makeBuffer(format: format) }
        guard let a = make(), let b = make(), let c = make(),
              let m = make(), let s = make(), let mt = make(), let sf = make() else { return false }
        accumA = a; accumB = b; content = c; masked = m; fxScratch = s; matteBuf = mt; sourceFx = sf
        size = format.size
        return true
    }


    private func ensureRouteBuffers(for format: FrameFormat) -> Bool {
        if routeSize == format.size, routeInput != nil { return true }
        func make() -> CVPixelBuffer? { try? pool.makeBuffer(format: format) }
        guard let input = make(), let output = make(), let scratch = make(), let matte = make() else { return false }
        routeInput = input; routeOutput = output; routeScratch = scratch; routeMatte = matte
        routeSize = format.size
        return true
    }
}
