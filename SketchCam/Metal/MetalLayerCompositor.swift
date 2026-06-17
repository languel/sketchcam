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
    private var accumA, accumB, content, masked, fxScratch, matteBuf: CVPixelBuffer?

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
        guard let accumA, let accumB, let content, let masked, let fxScratch, let matteBuf else { return nil }

        // Start from a transparent canvas.
        rasterize(CIImage(color: .clear).cropped(to: rect), into: accumA)
        var cur = accumA, other = accumB

        for layer in graph.layers where layer.visible && layer.opacity > 0.001 {
            guard let node = graph.node(layer.node), let img = streams.image(node) else { continue }
            rasterize(img, into: content)

            // Per-layer effect chain (content → masked).
            guard effects.applyChain(input: content, output: masked, scratch: fxScratch, effects: layer.effects) else { return nil }

            // Mask (masked → content, reusing content as the masked output).
            var layerBuf = masked
            if let mask = layer.mask, let matteImg = matte(for: mask.source, graph: graph, streams: streams) {
                rasterize(matteImg, into: matteBuf)
                if effects.mask(content: masked, matte: matteBuf, output: content,
                                mode: mask.mode, level: mask.level, invert: mask.invert) {
                    layerBuf = content
                }
            }

            // Composite onto the accumulator with the layer opacity.
            guard effects.composite(base: cur, overlay: layerBuf, output: other, opacity: layer.opacity) else { return nil }
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

    // MARK: - Helpers

    private func matte(for source: PortBinding, graph: LayerGraph, streams: Streams) -> CIImage? {
        switch source {
        case .none: return nil
        case .source(let s): return s == .personMatte ? streams.personMatte : nil
        case .node(let id): return graph.node(id).flatMap { streams.image($0) }
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
              let m = make(), let s = make(), let mt = make() else { return false }
        accumA = a; accumB = b; content = c; masked = m; fxScratch = s; matteBuf = mt
        size = format.size
        return true
    }
}
