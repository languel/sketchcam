import CoreVideo
import Foundation
import Metal
import simd

/// GPU effect kernels (threshold, Sobel outline, morphology, blur, composite) —
/// the Metal replacement for the CoreImage effect chain. Operates on
/// IOSurface-backed BGRA `CVPixelBuffer`s; intermediates are private textures.
final class MetalEffects {
    // Param structs — field order/types match EffectShaders.metal (vectors first).
    private struct ThresholdParams { var inSize: SIMD2<Float>; var outSize: SIMD2<Float>; var threshold: Float; var invert: UInt32; var inkOnly: UInt32 }
    private struct OutlineParams { var inSize: SIMD2<Float>; var outSize: SIMD2<Float>; var color: SIMD4<Float>; var strength: Float }
    private struct MorphParams { var radius: Int32; var dilate: UInt32 }
    private struct BlurParams { var radius: Int32 }

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let thresholdPSO: MTLComputePipelineState
    private let outlinePSO: MTLComputePipelineState
    private let morphPSO: MTLComputePipelineState
    private let blurPSO: MTLComputePipelineState
    private let compositePSO: MTLComputePipelineState

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
              let c = pso("effect_composite") else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess, let cache else { return nil }
        self.device = device
        self.queue = queue
        self.textureCache = cache
        self.thresholdPSO = t; self.outlinePSO = o; self.morphPSO = m; self.blurPSO = b; self.compositePSO = c
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

    func composite(base: CVPixelBuffer, overlay: CVPixelBuffer, output: CVPixelBuffer) -> Bool {
        guard let baseTex = texture(base), let overlayTex = texture(overlay), let outTex = texture(output) else { return false }
        return run(compositePSO, textures: [baseTex, overlayTex, outTex], bytes: nil, length: 0, grid: outTex)
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

        let verdict = (thrOK && edgeOK && dilOK) ? "PASS" : "FAIL"
        return "effects-selftest: \(verdict) threshold(L.r=\(tLeft.r),R.r=\(tRight.r)) outline(edge.a=\(edge.a),flat.a=\(flat.a)) dilate(neighbor.r=\(neighbor.r))"
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
