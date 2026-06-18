import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal
import SketchCamCore
import SketchCamShared

struct PaperTextureSet {
    let visible: MTLTexture
    let absorbency: MTLTexture
    let drag: MTLTexture
    let resist: MTLTexture
    let materialRevision: UInt64
}

/// Generates procedural paper once per configuration/size and reuses the
/// IOSurface-backed texture for both Ink and standalone Paper layer sources.
final class MetalPaperRenderer {
    static let shared: MetalPaperRenderer? = MetalPaperRenderer()

    private struct VisibleKey: Hashable {
        var config: ResolvedPaperConfig
        var width: Int
        var height: Int
    }

    /// Excludes color finishing so appearance-only edits reuse physical fields.
    private struct MaterialKey: Hashable {
        var fiberScaleX: Float
        var fiberScaleY: Float
        var fiberOrientation: Float
        var toothScaleX: Float
        var toothScaleY: Float
        var grainScaleX: Float
        var grainScaleY: Float
        var seed: Int
        var response: Float
        var variation: Float
        var absorbency: Float
        var drag: Float
        var resist: Float
        var resistThreshold: Float
        var resistSoftness: Float
        var width: Int
        var height: Int

        init(config: ResolvedPaperConfig, width: Int, height: Int) {
            fiberScaleX = config.fiberScaleX
            fiberScaleY = config.fiberScaleY
            fiberOrientation = config.fiberOrientation
            toothScaleX = config.toothScaleX
            toothScaleY = config.toothScaleY
            grainScaleX = config.grainScaleX
            grainScaleY = config.grainScaleY
            seed = config.seed
            response = config.response
            variation = config.variation
            absorbency = config.absorbency
            drag = config.drag
            resist = config.resist
            resistThreshold = config.resistThreshold
            resistSoftness = config.resistSoftness
            self.width = width
            self.height = height
        }
    }

    private struct Params {
        var resolution: SIMD2<Float>
        var padding: SIMD2<Float> = .zero
        var tint: SIMD4<Float>
        var fiber: SIMD4<Float>
        var tooth: SIMD4<Float>
        var grain: SIMD4<Float>
        var finish: SIMD4<Float>
        var physicalA: SIMD4<Float>
        var physicalB: SIMD4<Float>
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

    private struct MaterialEntry {
        let absorbency: MTLTexture
        let drag: MTLTexture
        let resist: MTLTexture
        let revision: UInt64
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let visiblePipeline: MTLComputePipelineState
    private let materialPipeline: MTLComputePipelineState
    private let textureCache: CVMetalTextureCache
    private var visibleEntries: [VisibleKey: Entry] = [:]
    private var materialEntries: [MaterialKey: MaterialEntry] = [:]
    private var nextMaterialRevision: UInt64 = 1
    private(set) var materialGenerationCount = 0
    private(set) var visibleGenerationCount = 0
    var generationCount: Int { materialGenerationCount }
    private(set) var cacheHitCount = 0

    init?(device suppliedDevice: MTLDevice? = nil) {
        guard let device = suppliedDevice ?? MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let visibleFunction = library.makeFunction(name: "ink_generate_paper"),
              let materialFunction = library.makeFunction(name: "ink_generate_paper_material"),
              let visiblePipeline = try? device.makeComputePipelineState(function: visibleFunction),
              let materialPipeline = try? device.makeComputePipelineState(function: materialFunction)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.queue = queue
        self.visiblePipeline = visiblePipeline
        self.materialPipeline = materialPipeline
        self.textureCache = cache
        #if DEBUG
        runCacheSelfCheck()
        #endif
    }

    #if DEBUG
    private func runCacheSelfCheck() {
        guard let firstBuffer = queue.makeCommandBuffer(),
              let first = textures(config: .metalDefault, size: CGSize(width: 17, height: 13), commandBuffer: firstBuffer)
        else { assertionFailure("Paper material self-check could not generate fields"); return }
        firstBuffer.commit()
        firstBuffer.waitUntilCompleted()
        let firstGeneration = materialGenerationCount

        guard let repeatBuffer = queue.makeCommandBuffer(),
              let repeatSet = textures(config: .metalDefault, size: CGSize(width: 17, height: 13), commandBuffer: repeatBuffer)
        else { assertionFailure("Paper material self-check could not reuse fields"); return }
        assert(repeatSet.absorbency === first.absorbency)
        assert(repeatSet.drag === first.drag)
        assert(repeatSet.resist === first.resist)
        assert(materialGenerationCount == firstGeneration)

        var appearance = PaperConfig.metalDefault
        appearance.tint = RGBAColor(red: 0.7, green: 0.8, blue: 0.9, alpha: 1)
        appearance.contrast = 1.8
        appearance.saturation = 0.2
        guard let appearanceBuffer = queue.makeCommandBuffer(),
              let appearanceSet = textures(config: appearance, size: CGSize(width: 17, height: 13), commandBuffer: appearanceBuffer)
        else { assertionFailure("Paper material self-check could not vary appearance"); return }
        appearanceBuffer.commit()
        appearanceBuffer.waitUntilCompleted()
        assert(appearanceSet.absorbency === first.absorbency)
        assert(materialGenerationCount == firstGeneration)

        var physical = PaperConfig.metalDefault
        physical.response = 0.5
        guard let physicalBuffer = queue.makeCommandBuffer(),
              let physicalSet = textures(config: physical, size: CGSize(width: 17, height: 13), commandBuffer: physicalBuffer)
        else { assertionFailure("Paper material self-check could not vary response"); return }
        physicalBuffer.commit()
        physicalBuffer.waitUntilCompleted()
        assert(physicalSet.absorbency !== first.absorbency)
        assert(materialGenerationCount == firstGeneration + 1)
        reset()
    }
    #endif

    func texture(config: PaperConfig, size: CGSize, commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        textures(config: config, size: size, commandBuffer: commandBuffer)?.visible
    }

    func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    func textures(config: PaperConfig, size: CGSize, commandBuffer: MTLCommandBuffer) -> PaperTextureSet? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        let resolved = config.resolved
        let visibleKey = VisibleKey(config: resolved, width: width, height: height)
        let materialKey = MaterialKey(config: resolved, width: width, height: height)

        let visible: Entry
        if let cached = visibleEntries[visibleKey] {
            cacheHitCount += 1
            visible = cached
        } else {
            guard let entry = makeEntry(width: width, height: height) else { return nil }
            encodeVisible(config: resolved, into: entry.texture, commandBuffer: commandBuffer)
            visibleEntries[visibleKey] = entry
            visibleGenerationCount += 1
            visible = entry
        }

        let material: MaterialEntry
        if let cached = materialEntries[materialKey] {
            cacheHitCount += 1
            material = cached
        } else {
            guard let absorbency = makeMaterialTexture(width: width, height: height),
                  let drag = makeMaterialTexture(width: width, height: height),
                  let resist = makeMaterialTexture(width: width, height: height) else { return nil }
            encodeMaterial(
                config: resolved,
                absorbency: absorbency,
                drag: drag,
                resist: resist,
                commandBuffer: commandBuffer
            )
            material = MaterialEntry(
                absorbency: absorbency,
                drag: drag,
                resist: resist,
                revision: nextMaterialRevision
            )
            nextMaterialRevision &+= 1
            materialEntries[materialKey] = material
            materialGenerationCount += 1
        }
        trimCaches(visibleKey: visibleKey, materialKey: materialKey)
        return PaperTextureSet(
            visible: visible.texture,
            absorbency: material.absorbency,
            drag: material.drag,
            resist: material.resist,
            materialRevision: material.revision
        )
    }

    func image(config: PaperConfig, rect: CGRect) -> CIImage? {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let texture = texture(config: config, size: rect.size, commandBuffer: commandBuffer)
        else { return nil }
        let key = VisibleKey(config: config.resolved, width: texture.width, height: texture.height)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard let entry = visibleEntries[key] else { return nil }
        return CIImage(cvPixelBuffer: entry.pixelBuffer).cropped(to: CGRect(origin: rect.origin, size: rect.size))
    }

    func reset() {
        visibleEntries.removeAll()
        materialEntries.removeAll()
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

    private func makeMaterialTexture(width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private func params(for config: ResolvedPaperConfig, width: Int, height: Int) -> Params {
        Params(
            resolution: SIMD2(Float(width), Float(height)),
            tint: SIMD4(config.tintRed, config.tintGreen, config.tintBlue, config.tintAlpha),
            fiber: SIMD4(config.fiberStrength, config.fiberScaleX, config.fiberScaleY, config.fiberOrientation),
            tooth: SIMD4(config.toothStrength, config.toothScaleX, config.toothScaleY, 0),
            grain: SIMD4(config.grainStrength, config.grainScaleX, config.grainScaleY, Float(config.seed)),
            finish: SIMD4(config.contrast, config.vignetteStrength, config.saturation, 0),
            physicalA: SIMD4(config.response, config.variation, config.absorbency, config.drag),
            physicalB: SIMD4(config.resist, config.resistThreshold, config.resistSoftness, 0)
        )
    }

    private func encodeVisible(config: ResolvedPaperConfig, into texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        var params = params(for: config, width: texture.width, height: texture.height)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(visiblePipeline)
        encoder.setTexture(texture, index: 0)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: texture.width, height: texture.height, depth: 1), threadsPerThreadgroup: threads)
        encoder.endEncoding()
    }

    private func encodeMaterial(
        config: ResolvedPaperConfig,
        absorbency: MTLTexture,
        drag: MTLTexture,
        resist: MTLTexture,
        commandBuffer: MTLCommandBuffer
    ) {
        var params = params(for: config, width: absorbency.width, height: absorbency.height)
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(materialPipeline)
        encoder.setTexture(absorbency, index: 0)
        encoder.setTexture(drag, index: 1)
        encoder.setTexture(resist, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        let threads = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(
            MTLSize(width: absorbency.width, height: absorbency.height, depth: 1),
            threadsPerThreadgroup: threads
        )
        encoder.endEncoding()
    }

    private func trimCaches(visibleKey: VisibleKey, materialKey: MaterialKey) {
        if visibleEntries.count > 16 {
            visibleEntries = [visibleKey: visibleEntries[visibleKey]!]
            CVMetalTextureCacheFlush(textureCache, 0)
        }
        if materialEntries.count > 16 {
            materialEntries = [materialKey: materialEntries[materialKey]!]
        }
    }
}
