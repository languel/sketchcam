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
                   frameIndex: Int, timestamp: CMTime, mirror: Bool) -> ProcessedFrame? {
        guard ensureBuffers(for: outputFormat) else { return nil }
        let rect = CGRect(origin: .zero, size: outputFormat.size)
        guard let accumA, let accumB, let content, let masked, let fxScratch, let matteBuf, let sourceFx else { return nil }

        // Start from a transparent canvas.
        rasterize(CIImage(color: .clear).cropped(to: rect), into: accumA)
        var cur = accumA, other = accumB

        for layer in graph.layers where layer.visible && layer.opacity > 0.001 {
            guard let node = graph.node(layer.node), let img = streams.image(node) else { continue }
            rasterize(img, into: content)

            // Layer masks clip the raw source first. Effect-chain Person Key still
            // lives in the chain below, so it affects the chain at its own position.
            var chainInput = content
            var chainOutput = masked
            if let mask = layer.mask {
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
            if layer.effects.contains(where: { $0.enabled && $0.kind.needsPersonMatte }), let pm = streams.personMatte {
                rasterize(pm, into: matteBuf)
                chainMatte = matteBuf
            }

            // Per-layer effect chain after source masking.
            guard effects.applyChain(input: chainInput, output: chainOutput, scratch: fxScratch,
                                     effects: layer.effects, matte: chainMatte, frameIndex: frameIndex) else { return nil }

            // Composite onto the accumulator with the layer opacity/blend mode.
            guard effects.composite(base: cur, overlay: chainOutput, output: other,
                                    opacity: layer.opacity, blend: layer.blend) else { return nil }
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
