import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import SketchCamCore
import SketchCamShared

/// Generates procedural paper once per configuration/size and reuses the
/// IOSurface-backed texture for both Ink and standalone Paper layer sources.
final class MetalPaperRenderer {
    private struct CacheKey: Hashable {
        var config: ResolvedPaperConfig
        var width: Int
        var height: Int
    }

    private struct Params {
        var resolution: SIMD2<Float>
        var padding: SIMD2<Float> = .zero
        var tint: SIMD4<Float>
        var fiber: SIMD4<Float>
        var tooth: SIMD4<Float>
        var grain: SIMD4<Float>
        var finish: SIMD4<Float>
    }

    private final class Entry {
        let pixelBuffer: CVPixelBuffer
        let cvTexture: CVMetalTexture
        let texture: MTLTexture

        init(pixelBuffer: CVPixelBuffer, cvTexture: CVMetalTexture, texture: MTLTexture) {
            self.pixelBuffer = pixelBuffer
            self.cvTexture = cvTexture
            self.texture = texture
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private var entries: [CacheKey: Entry] = [:]
    private(set) var generationCount = 0
    private(set) var cacheHitCount = 0

    init?(device suppliedDevice: MTLDevice? = nil) {
        guard let device = suppliedDevice ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "ink_generate_paper"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.textureCache = cache
    }

    func texture(config: PaperConfig, size: CGSize, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let key = CacheKey(config: config.resolved, width: width, height: height)
        if let cached = entries[key] {
            cacheHitCount += 1
            return cached.texture
        }
        guard let entry = makeEntry(width: width, height: height) else { return nil }
        encode(config: key.config, into: entry.texture, commandBuffer: commandBuffer)
        entries[key] = entry
        generationCount += 1
        trimCache(keeping: key)
        return entry.texture
    }

    func image(config: PaperConfig, rect: CGRect) -> CIImage? {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let texture = texture(config: config, size: rect.size, commandBuffer: commandBuffer)
        else { return nil }
        let key = CacheKey(config: config.resolved, width: texture.width, height: texture.height)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard let entry = entries[key] else { return nil }
        return CIImage(cvPixelBuffer: entry.pixelBuffer).cropped(to: CGRect(origin: rect.origin, size: rect.size))
    }

    func reset() {
        entries.removeAll()
        CVMetalTextureCacheFlush(textureCache, 0)
    }

    private func makeEntry(width: Int, height: Int) -> Entry? {
        guard let buffer = try? PixelBufferUtils.makePixelBuffer(
            format: FrameFormat(id: "metal-paper", width: width, height: height)
        ) else { return nil }
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        ) == kCVReturnSuccess,
        let cvTexture,
        let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return Entry(pixelBuffer: buffer, cvTexture: cvTexture, texture: texture)
    }

    private func encode(config: ResolvedPaperConfig, into texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        var params = Params(
            resolution: SIMD2(Float(texture.width), Float(texture.height)),
            tint: SIMD4(config.tintRed, config.tintGreen, config.tintBlue, config.tintAlpha),
            fiber: SIMD4(config.fiberStrength, config.fiberScaleX, config.fiberScaleY, config.fiberOrientation),
            tooth: SIMD4(config.toothStrength, config.toothScaleX, config.toothScaleY, 0),
            grain: SIMD4(config.grainStrength, config.grainScaleX, config.grainScaleY, Float(config.seed)),
            finish: SIMD4(config.contrast, config.vignetteStrength, 0, 0)
        )
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1), threadsPerThreadgroup: threads)
        encoder.endEncoding()
    }

    private func trimCache(keeping key: CacheKey) {
        guard entries.count > 16 else { return }
        entries = [key: entries[key]!]
        CVMetalTextureCacheFlush(textureCache, 0)
    }
}
