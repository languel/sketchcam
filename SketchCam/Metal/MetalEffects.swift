import CoreVideo
import Foundation
import Metal
import simd
import SketchCamCore
import SketchCamShared

/// GPU effect kernels (threshold, Sobel outline, morphology, blur, composite) —
/// the Metal replacement for the CoreImage effect chain. Operates on
/// IOSurface-backed BGRA `CVPixelBuffer`s; intermediates are private textures.
final class MetalEffects {
    // Param structs — field order/types match EffectShaders.metal (vectors first).
    private struct ThresholdParams { var inSize: SIMD2<Float>; var outSize: SIMD2<Float>; var threshold: Float; var invert: UInt32; var inkOnly: UInt32 }
    private struct OutlineParams { var inSize: SIMD2<Float>; var outSize: SIMD2<Float>; var color: SIMD4<Float>; var strength: Float }
    private struct MorphParams { var radius: Int32; var dilate: UInt32 }
    private struct BlurParams { var radius: Int32 }
    private struct CompositeParams { var opacity: Float; var blendMode: UInt32 }
    private struct MaskParams { var level: Float; var mode: UInt32; var invert: UInt32 }
    private struct SilhouetteParams { var color: SIMD4<Float>; var invert: UInt32 }
    private struct OpticalFlowParams { var gain: Float }
    private struct LevelsParams { var blackPoint: Float; var whitePoint: Float; var gamma: Float }
    private struct OpticalFlowState {
        var previous: CVPixelBuffer
        var cached: CVPixelBuffer
        var lastFrameIndex: Int?
    }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let thresholdPSO: MTLComputePipelineState
    private let outlinePSO: MTLComputePipelineState
    private let morphPSO: MTLComputePipelineState
    private let blurPSO: MTLComputePipelineState
    private let compositePSO: MTLComputePipelineState
    private let compositeOpPSO: MTLComputePipelineState
    private let maskPSO: MTLComputePipelineState
    private let invertPSO: MTLComputePipelineState
    private let mirrorPSO: MTLComputePipelineState
    private let silhouettePSO: MTLComputePipelineState
    private let opticalFlowPSO: MTLComputePipelineState
    private let levelsPSO: MTLComputePipelineState
    private var opticalFlowStates: [UUID: OpticalFlowState] = [:]

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary() else { return nil }
        func pso(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: fn)
        }
        guard let t = pso("effect_threshold"), let o = pso("effect_outline"),
              let m = pso("effect_morphology"), let b = pso("effect_box_blur"),
              let c = pso("effect_composite"), let co = pso("effect_composite_op"),
              let mk = pso("effect_mask"), let iv = pso("effect_invert"),
              let mir = pso("effect_mirror"), let sil = pso("effect_silhouette"),
              let flow = pso("effect_optical_flow"), let levels = pso("effect_levels") else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.device = device
        self.queue = queue
        self.textureCache = cache
        self.thresholdPSO = t; self.outlinePSO = o; self.morphPSO = m; self.blurPSO = b
        self.compositePSO = c; self.compositeOpPSO = co; self.maskPSO = mk
        self.invertPSO = iv; self.mirrorPSO = mir; self.silhouettePSO = sil
        self.opticalFlowPSO = flow
        self.levelsPSO = levels
    }

    // MARK: - Public ops (each runs on its own command buffer, synchronous)

    func threshold(input: CVPixelBuffer, output: CVPixelBuffer, threshold: Float, invert: Bool, inkOnly: Bool) -> Bool {
        guard let inTex = texture(input), let outTex = texture(output) else { return false }
        var params = ThresholdParams(
            inSize: SIMD2(Float(inTex.width), Float(inTex.height)),
            outSize: SIMD2(Float(outTex.width), Float(outTex.height)),
            threshold: threshold, invert: invert ? 1 : 0, inkOnly: inkOnly ? 1 : 0
        )
        return run(thresholdPSO, textures: [inTex, outTex], bytes: &params, length: MemoryLayout<ThresholdParams>.stride, grid: outTex)
    }

    func outline(input: CVPixelBuffer, output: CVPixelBuffer, strength: Float, color: SIMD4<Float>) -> Bool {
        guard let inTex = texture(input), let outTex = texture(output) else { return false }
        var params = OutlineParams(
            inSize: SIMD2(Float(inTex.width), Float(inTex.height)),
            outSize: SIMD2(Float(outTex.width), Float(outTex.height)),
            color: color, strength: strength
        )
        return run(outlinePSO, textures: [inTex, outTex], bytes: &params, length: MemoryLayout<OutlineParams>.stride, grid: outTex)
    }

    func morphology(input: CVPixelBuffer, output: CVPixelBuffer, radius: Int, dilate: Bool) -> Bool {
        guard let inTex = texture(input), let outTex = texture(output) else { return false }
        var params = MorphParams(radius: Int32(radius), dilate: dilate ? 1 : 0)
        return run(morphPSO, textures: [inTex, outTex], bytes: &params, length: MemoryLayout<MorphParams>.stride, grid: outTex)
    }

    func blur(input: CVPixelBuffer, output: CVPixelBuffer, radius: Int) -> Bool {
        guard let inTex = texture(input), let outTex = texture(output) else { return false }
        var params = BlurParams(radius: Int32(radius))
        return run(blurPSO, textures: [inTex, outTex], bytes: &params, length: MemoryLayout<BlurParams>.stride, grid: outTex)
    }

    func invert(input: CVPixelBuffer, output: CVPixelBuffer) -> Bool {
        guard let inTex = texture(input), let outTex = texture(output) else { return false }
        return run(invertPSO, textures: [inTex, outTex], bytes: nil, length: 0, grid: outTex)
    }

    func mirror(input: CVPixelBuffer, output: CVPixelBuffer) -> Bool {
        guard let inTex = texture(input), let outTex = texture(output) else { return false }
        return run(mirrorPSO, textures: [inTex, outTex], bytes: nil, length: 0, grid: outTex)
    }

    /// Fill the matte region with a flat colour (silhouette); ignores `output`'s
    /// prior content. `color` is straight-alpha.
    func silhouette(matte: CVPixelBuffer, output: CVPixelBuffer, color: SIMD4<Float>, invert: Bool) -> Bool {
        guard let mTex = texture(matte), let outTex = texture(output) else { return false }
        var p = SilhouetteParams(color: color, invert: invert ? 1 : 0)
        return run(silhouettePSO, textures: [mTex, outTex], bytes: &p, length: MemoryLayout<SilhouetteParams>.stride, grid: outTex)
    }

    func composite(base: CVPixelBuffer, overlay: CVPixelBuffer, output: CVPixelBuffer) -> Bool {
        guard let baseTex = texture(base), let overlayTex = texture(overlay), let outTex = texture(output) else { return false }
        return run(compositePSO, textures: [baseTex, overlayTex, outTex], bytes: nil, length: 0, grid: outTex)
    }

    /// Source-over with a per-layer opacity (0...1) and blend mode.
    func composite(base: CVPixelBuffer, overlay: CVPixelBuffer, output: CVPixelBuffer, opacity: Float, blend: BlendMode = .normal) -> Bool {
        guard let baseTex = texture(base), let overlayTex = texture(overlay), let outTex = texture(output) else { return false }
        var p = CompositeParams(opacity: max(0, min(1, opacity)), blendMode: Self.blendCode(blend))
        return run(compositeOpPSO, textures: [baseTex, overlayTex, outTex], bytes: &p, length: MemoryLayout<CompositeParams>.stride, grid: outTex)
    }

    private static func blendCode(_ blend: BlendMode) -> UInt32 {
        switch blend {
        case .normal: return 0
        case .multiply: return 1
        case .screen: return 2
        case .add: return 3
        case .overlay: return 4
        case .darken: return 5
        case .lighten: return 6
        case .difference: return 7
        case .subtract: return 8
        case .softLight: return 9
        case .hue, .saturation, .color, .luminosity:
            return 0
        }
    }

    /// Mask `content` by a matte stream; `mode`/`level`/`invert` mirror MaskBinding.
    func mask(content: CVPixelBuffer, matte: CVPixelBuffer, output: CVPixelBuffer, mode: MaskBinding.Mode, level: Float, invert: Bool) -> Bool {
        guard let cTex = texture(content), let mTex = texture(matte), let outTex = texture(output) else { return false }
        let modeCode: UInt32 = (mode == .threshold) ? 1 : (mode == .invThreshold) ? 2 : 0
        var p = MaskParams(level: level, mode: modeCode, invert: invert ? 1 : 0)
        return run(maskPSO, textures: [cTex, mTex, outTex], bytes: &p, length: MemoryLayout<MaskParams>.stride, grid: outTex)
    }

    /// Copy (same size) — blur with radius 0 reads each pixel back unchanged.
    func copy(input: CVPixelBuffer, output: CVPixelBuffer) -> Bool {
        blur(input: input, output: output, radius: 0)
    }

    /// Apply an ordered effect chain to `input`, leaving the result in `output`.
    /// `scratch` is a same-size working buffer for ping-ponging. Unknown/disabled
    /// effects are skipped; an empty chain copies input→output.
    func applyChain(input: CVPixelBuffer, output: CVPixelBuffer, scratch: CVPixelBuffer,
                    effects: [EffectConfig], matte: CVPixelBuffer? = nil,
                    frameIndex: Int? = nil) -> Bool {
        let enabled = effects.filter { $0.enabled }
        guard !enabled.isEmpty else { return copy(input: input, output: output) }
        var src = input
        for (i, e) in enabled.enumerated() {
            let dst: CVPixelBuffer = (i % 2 == 0) ? scratch : output
            guard apply(e, input: src, output: dst, matte: matte, frameIndex: frameIndex) else { return false }
            src = dst
        }
        // If the last write landed in scratch, mirror it into output.
        if src !== output { return copy(input: src, output: output) }
        return true
    }

    private func apply(_ e: EffectConfig, input: CVPixelBuffer, output: CVPixelBuffer,
                       matte: CVPixelBuffer?, frameIndex: Int?) -> Bool {
        switch e.kind {
        case .threshold:
            return threshold(input: input, output: output, threshold: e.amount, invert: e.invert, inkOnly: e.inkOnly)
        case .outline:
            let c = SIMD4<Float>(e.color.red, e.color.green, e.color.blue, e.color.alpha)
            return outline(input: input, output: output, strength: e.amount, color: c)
        case .blur:
            return blur(input: input, output: output, radius: Int(e.amount.rounded()))
        case .invert:
            return invert(input: input, output: output)
        case .mirror:
            return mirror(input: input, output: output)
        case .personKey:
            // Key to the person matte (invert = key the person OUT). Without a
            // matte (segmentation idle), pass through rather than blanking.
            guard let matte else { return copy(input: input, output: output) }
            if e.silhouette {
                let c = SIMD4<Float>(e.color.red, e.color.green, e.color.blue, e.color.alpha)
                return silhouette(matte: matte, output: output, color: c, invert: e.invert)
            }
            return mask(content: input, matte: matte, output: output, mode: .luma, level: 0.5, invert: e.invert)
        case .opticalFlow:
            return opticalFlow(id: e.id, input: input, output: output, gain: e.amount, frameIndex: frameIndex)
        case .levels:
            guard let inTex = texture(input), let outTex = texture(output) else { return false }
            var params = LevelsParams(
                blackPoint: min(e.levelBlack, e.levelWhite - 0.001),
                whitePoint: max(e.levelWhite, e.levelBlack + 0.001),
                gamma: max(0.01, e.levelGamma)
            )
            return run(levelsPSO, textures: [inTex, outTex], bytes: &params,
                       length: MemoryLayout<LevelsParams>.stride, grid: outTex)
        }
    }

    private func opticalFlow(id: UUID, input: CVPixelBuffer, output: CVPixelBuffer,
                             gain: Float, frameIndex: Int?) -> Bool {
        if let state = opticalFlowStates[id], let frameIndex,
           state.lastFrameIndex == frameIndex {
            return copy(input: state.cached, output: output)
        }
        let width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input)
        var state = opticalFlowStates[id]
        if state == nil || CVPixelBufferGetWidth(state!.previous) != width || CVPixelBufferGetHeight(state!.previous) != height {
            let format = FrameFormat(id: "optical-flow-effect", width: width, height: height)
            guard let previous = try? PixelBufferUtils.makePixelBuffer(format: format),
                  let cached = try? PixelBufferUtils.makePixelBuffer(format: format),
                  copy(input: input, output: previous)
            else { return false }
            state = OpticalFlowState(previous: previous, cached: cached, lastFrameIndex: nil)
        }
        guard var state,
              let currentTexture = texture(input),
              let previousTexture = texture(state.previous),
              let outputTexture = texture(output)
        else { return false }
        var params = OpticalFlowParams(gain: max(0, gain))
        guard run(opticalFlowPSO, textures: [currentTexture, previousTexture, outputTexture],
                  bytes: &params, length: MemoryLayout<OpticalFlowParams>.stride, grid: outputTexture),
              copy(input: input, output: state.previous),
              copy(input: output, output: state.cached)
        else { return false }
        state.lastFrameIndex = frameIndex
        opticalFlowStates[id] = state
        return true
    }

    // MARK: - Dispatch

    private func run(_ pso: MTLComputePipelineState, textures: [MTLTexture], bytes: UnsafeRawPointer?, length: Int, grid: MTLTexture) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pso)
        for (i, tex) in textures.enumerated() { encoder.setTexture(tex, index: i) }
        if let bytes, length > 0 { encoder.setBytes(bytes, length: length, index: 0) }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: grid.width, height: grid.height, depth: 1), threadsPerThreadgroup: tg)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        // The GPU is done; let the cache release the CVMetalTextures it's holding.
        // Without a periodic flush the cache pins IOSurfaces and GPU scheduling
        // degrades over a long session (textures still referenced aren't flushed).
        CVMetalTextureCacheFlush(textureCache, 0)
        return true
    }

    private func texture(_ pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        let w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer)
        var cvTex: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvTex, let tex = CVMetalTextureGetTexture(cvTex) else { return nil }
        return tex
    }
}

#if DEBUG
import SketchCamShared

extension MetalEffects {
    /// Headless verification of the effect kernels (writes container tmp).
    static func runSelfCheck() {
        let result = MetalEffects()?.selfCheck() ?? "effects-selftest: init FAILED"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sketchcam-metal-effects-selftest.txt")
        try? (result + "\n").write(to: url, atomically: true, encoding: .utf8)
        print("SketchCamMetalEffects \(result)")
    }

    private func selfCheck() -> String {
        let n = 16
        guard let input = makeBuffer(n), let output = makeBuffer(n) else { return "effects-selftest: buffer FAILED" }
        // Left half dark, right half bright (vertical edge at x=8).
        fill(input) { x, _ in x < n / 2 ? (0, 0, 0, 255) : (255, 255, 255, 255) }

        guard threshold(input: input, output: output, threshold: 0.5, invert: false, inkOnly: false) else { return "effects-selftest: threshold run FAILED" }
        let tLeft = read(output, 4, 8), tRight = read(output, 12, 8)
        let thrOK = tLeft.r < 40 && tRight.r > 215

        guard outline(input: input, output: output, strength: 2.0, color: SIMD4(1, 1, 1, 1)) else { return "effects-selftest: outline run FAILED" }
        let edge = read(output, 8, 8), flat = read(output, 2, 8)
        let edgeOK = edge.a > 120 && flat.a < 40

        // Dilate: single white dot at center on black.
        fill(input) { x, y in (x == 8 && y == 8) ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        guard morphology(input: input, output: output, radius: 1, dilate: true) else { return "effects-selftest: morph run FAILED" }
        let neighbor = read(output, 7, 8)
        let dilOK = neighbor.r > 215

        // Effect chain: threshold then blur (radius 1) over the vertical edge.
        // The blur softens the hard threshold edge, so the column at the edge is
        // an intermediate grey rather than pure 0/255.
        guard let scratch = makeBuffer(n) else { return "effects-selftest: chain buffer FAILED" }
        fill(input) { x, _ in x < n / 2 ? (0, 0, 0, 255) : (255, 255, 255, 255) }
        guard applyChain(input: input, output: output, scratch: scratch,
                         effects: [EffectConfig(kind: .threshold, amount: 0.5),
                                   EffectConfig(kind: .blur, amount: 1)]) else { return "effects-selftest: chain run FAILED" }
        let edgeMid = read(output, 8, 8)
        let chainOK = edgeMid.r > 20 && edgeMid.r < 235      // softened, not pure B/W

        // Mask: a half-white/half-black matte keeps only the matte's white half.
        fill(input) { _, _ in (200, 100, 50, 255) }          // solid content
        guard let matte = makeBuffer(n) else { return "effects-selftest: mask buffer FAILED" }
        fill(matte) { x, _ in x < n / 2 ? (255, 255, 255, 255) : (0, 0, 0, 255) }
        guard mask(content: input, matte: matte, output: output, mode: .luma, level: 0.5, invert: false) else { return "effects-selftest: mask run FAILED" }
        let keptPix = read(output, 4, 8), droppedPix = read(output, 12, 8)
        let maskOK = keptPix.a > 215 && droppedPix.a < 40

        let verdict = (thrOK && edgeOK && dilOK && chainOK && maskOK) ? "PASS" : "FAIL"
        return "effects-selftest: \(verdict) threshold(L.r=\(tLeft.r),R.r=\(tRight.r)) outline(edge.a=\(edge.a),flat.a=\(flat.a)) dilate(neighbor.r=\(neighbor.r)) chain(edgeMid.r=\(edgeMid.r)) mask(kept.a=\(keptPix.a),dropped.a=\(droppedPix.a))"
    }

    private func makeBuffer(_ size: Int) -> CVPixelBuffer? {
        try? PixelBufferUtils.makePixelBuffer(format: FrameFormat(id: "fx-selftest", width: size, height: size))
    }

    private func fill(_ buffer: CVPixelBuffer, _ pixel: (Int, Int) -> (b: UInt8, g: UInt8, r: UInt8, a: UInt8)) {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let data = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            for x in 0..<w {
                let o = y * rowBytes + x * 4
                let p = pixel(x, y)
                data[o] = p.b; data[o + 1] = p.g; data[o + 2] = p.r; data[o + 3] = p.a
            }
        }
    }

    private func read(_ buffer: CVPixelBuffer, _ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0, 0) }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let data = base.assumingMemoryBound(to: UInt8.self)
        let o = y * rowBytes + x * 4
        return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]), Int(data[o + 3]))
    }
}
#endif
