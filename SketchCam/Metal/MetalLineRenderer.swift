import CoreVideo
import Foundation
import Metal
import SketchCamCore
import simd

/// GPU renderer for LineWalk-style strokes. Tessellates strokes to triangles
/// (`StrokeTessellator`) and rasterizes them with Metal into an IOSurface-backed
/// `CVPixelBuffer`, replacing the CPU `CGContext` stroke pass that dominated the
/// overlay cost (~54 ms → sub-millisecond on the GPU).
///
/// Coordinate convention: stroke points are canvas PIXELS, origin top-left,
/// y-down (the shader maps to NDC). The output buffer is premultiplied BGRA with
/// a transparent (clear) background, ready to composite over the frame.
final class MetalLineRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let sampleCount = 4

    // MSAA target cached per output size.
    private var msaaTexture: MTLTexture?
    private var msaaSize = (width: 0, height: 0)

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let vertexFunction = library.makeFunction(name: "line_vertex"),
              let fragmentFunction = library.makeFunction(name: "line_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.rasterSampleCount = sampleCount
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one                // premultiplied source
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.textureCache = cache
    }

    /// Renders `strokes` into `pixelBuffer` (must be IOSurface- + Metal-compatible
    /// BGRA). Clears to transparent first. Returns false on GPU/wrap failure.
    @discardableResult
    func render(strokes: [StrokeTessellator.Stroke], ribbon: Bool = true, into pixelBuffer: CVPixelBuffer) -> Bool {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0, let target = makeTexture(from: pixelBuffer, width: width, height: height) else {
            return false
        }
        let msaa = makeMSAATexture(width: width, height: height)

        let pass = MTLRenderPassDescriptor()
        let color = pass.colorAttachments[0]!
        color.texture = msaa
        color.resolveTexture = target
        color.loadAction = .clear
        color.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        color.storeAction = .multisampleResolve

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return false }

        let verts = StrokeTessellator.tessellate(strokes, ribbon: ribbon)
        let vertexCount = verts.count / StrokeTessellator.floatsPerVertex
        if vertexCount > 0, let vertexBuffer = device.makeBuffer(bytes: verts, length: verts.count * MemoryLayout<Float>.stride, options: .storageModeShared) {
            var viewport = SIMD2<Float>(Float(width), Float(height))
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewport, length: MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertexCount)
        }
        // Even with no geometry, ending the pass clears the target to transparent.
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return true
    }

    // MARK: - Textures

    private func makeTexture(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, width, height, 0, &cvTexture
        )
        guard status == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return texture
    }

    private func makeMSAATexture(width: Int, height: Int) -> MTLTexture {
        if let msaaTexture, msaaSize == (width, height) { return msaaTexture }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type2DMultisample
        descriptor.pixelFormat = .bgra8Unorm
        descriptor.width = width
        descriptor.height = height
        descriptor.sampleCount = sampleCount
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        let texture = device.makeTexture(descriptor: descriptor)!
        msaaTexture = texture
        msaaSize = (width, height)
        return texture
    }
}

#if DEBUG
import CoreGraphics
import SketchCamShared

extension MetalLineRenderer {
    /// Headless smoke check: render a thick red horizontal line on a 64×64
    /// transparent buffer and read back pixels. Verifies pipeline creation,
    /// orientation, premultiplied blending, and IOSurface readback end-to-end.
    /// Result string is appended to the container tmp so it can be inspected
    /// after launch (no app test target exists for the Metal code).
    static func runSelfCheck() {
        let result = selfCheck()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sketchcam-metal-selftest.txt")
        try? (result + "\n").write(to: url, atomically: true, encoding: .utf8)
        print("SketchCamMetal \(result)")
    }

    private static func selfCheck() -> String {
        guard let renderer = MetalLineRenderer() else { return "selftest: renderer init FAILED (no Metal device/library/pipeline)" }
        guard let buffer = try? PixelBufferUtils.makePixelBuffer(format: FrameFormat(id: "metal-selftest", width: 64, height: 64)) else {
            return "selftest: pixel buffer alloc FAILED"
        }
        // Horizontal line at HIGH canvas y (56 of 64). y-up ⇒ it must land near
        // the TOP of the buffer (low row index ≈ 64-56 = 8), NOT the bottom.
        let stroke = StrokeTessellator.Stroke(
            points: [CGPoint(x: 4, y: 56), CGPoint(x: 60, y: 56)],
            color: RGBAColor(red: 1, green: 0, blue: 0, alpha: 1),
            baseWidth: 12
        )
        guard renderer.render(strokes: [stroke], into: buffer) else { return "selftest: render FAILED" }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return "selftest: base addr FAILED" }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let data = base.assumingMemoryBound(to: UInt8.self)
        func pixel(_ x: Int, _ y: Int) -> (b: Int, g: Int, r: Int, a: Int) {
            let o = y * rowBytes + x * 4
            return (Int(data[o]), Int(data[o + 1]), Int(data[o + 2]), Int(data[o + 3]))
        }
        let top = pixel(32, 8)      // where the high-y line should be → red, opaque
        let bottom = pixel(32, 56)  // opposite end → transparent (confirms y-up)
        let topOK = top.a > 200 && top.r > 200 && top.g < 60 && top.b < 60
        let bottomOK = bottom.a < 20
        let verdict = (topOK && bottomOK) ? "PASS" : "FAIL"

        let perf = perfLine(renderer: renderer)
        return "selftest: \(verdict) (y-up) top-row8(b,g,r,a)=\(top) bottom-row56(b,g,r,a)=\(bottom)\n\(perf)"
    }

    /// Times a representative overlay render at the typical 1280×720 canvas with
    /// a busy LineWalk-like stroke set, for direct comparison to the ~54 ms CPU
    /// CGContext overlay this replaces.
    private static func perfLine(renderer: MetalLineRenderer) -> String {
        guard let buffer = try? PixelBufferUtils.makePixelBuffer(format: FrameFormat(id: "metal-perf", width: 1280, height: 720)) else {
            return "perf: buffer alloc FAILED"
        }
        // 8 wavy strokes of ~200 points each (~1600 points total) — comparable
        // to a dense multi-feature LineWalk frame.
        var strokes: [StrokeTessellator.Stroke] = []
        for s in 0..<8 {
            let pts = (0..<200).map { i -> CGPoint in
                let t = Double(i)
                return CGPoint(x: 40 + t * 6, y: 360 + sin(t * 0.18 + Double(s)) * (120 + Double(s) * 8))
            }
            strokes.append(StrokeTessellator.Stroke(
                points: pts,
                color: RGBAColor(red: 0.9, green: 0.4, blue: 0.3, alpha: 0.95),
                baseWidth: 6, widthVariation: 0.5, seed: s
            ))
        }
        for _ in 0..<10 { _ = renderer.render(strokes: strokes, into: buffer) }  // warm up
        let iterations = 100
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations { _ = renderer.render(strokes: strokes, into: buffer) }
        let perCall = (CFAbsoluteTimeGetCurrent() - start) / Double(iterations) * 1_000
        return String(format: "perf: GPU overlay render (1280x720, ~1600 pts, MSAA, sync) = %.3f ms/frame (CPU CGContext was ~54 ms)", perCall)
    }
}
#endif
