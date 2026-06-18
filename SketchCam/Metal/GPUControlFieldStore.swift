import Foundation
import Metal
import SketchCamCore

struct GPUControlField {
    let kind: ControlFieldKind
    let texture: MTLTexture
    let revision: UInt64
}

/// GPU-only registry for named control fields. Missing fields resolve to a
/// cached zero texture, so consumers never need optional shader bindings.
final class GPUControlFieldStore {
    private struct PublishedKey: Hashable {
        var provider: UUID
        var output: ControlFieldOutputID
    }

    private struct ZeroKey: Hashable {
        var kind: ControlFieldKind
        var width: Int
        var height: Int
    }

    private struct ResampleKey: Hashable {
        var source: ControlFieldReference
        var revision: UInt64
        var width: Int
        var height: Int
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let clearScalarPSO: MTLComputePipelineState
    private let clearVectorPSO: MTLComputePipelineState
    private let resampleScalarPSO: MTLComputePipelineState
    private let resampleVectorPSO: MTLComputePipelineState
    private var published: [PublishedKey: GPUControlField] = [:]
    private var zeros: [ZeroKey: GPUControlField] = [:]
    private var resampled: [ResampleKey: GPUControlField] = [:]

    private(set) var zeroAllocationCount = 0
    private(set) var resampleCount = 0

    init?(device: MTLDevice) {
        guard let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let clearScalar = Self.pipeline("control_clear_scalar", library: library, device: device),
              let clearVector = Self.pipeline("control_clear_vector", library: library, device: device),
              let resampleScalar = Self.pipeline("control_resample_scalar", library: library, device: device),
              let resampleVector = Self.pipeline("control_resample_vector", library: library, device: device)
        else { return nil }
        self.device = device
        self.queue = queue
        self.clearScalarPSO = clearScalar
        self.clearVectorPSO = clearVector
        self.resampleScalarPSO = resampleScalar
        self.resampleVectorPSO = resampleVector
        #if DEBUG
        runSelfCheck()
        #endif
    }

    func publish(_ field: GPUControlField, provider: UUID, output: ControlFieldOutputID) {
        guard field.kind == output.kind else {
            assertionFailure("Control field kind does not match named output")
            return
        }
        let key = PublishedKey(provider: provider, output: output)
        if let previous = published[key], previous.revision > field.revision { return }
        published[key] = field
        resampled = resampled.filter { $0.key.source.provider != provider || $0.key.source.output != output }
    }

    func resolve(_ reference: ControlFieldReference, width: Int, height: Int) -> GPUControlField {
        let width = max(1, width)
        let height = max(1, height)
        let key = PublishedKey(provider: reference.provider, output: reference.output)
        guard let field = published[key] else {
            return zero(kind: reference.output.kind, width: width, height: height)
        }
        guard field.texture.width != width || field.texture.height != height else { return field }

        let resampleKey = ResampleKey(source: reference, revision: field.revision, width: width, height: height)
        if let cached = resampled[resampleKey] { return cached }
        guard let texture = makeTexture(kind: field.kind, width: width, height: height),
              encode(
                pipeline: field.kind == .scalar ? resampleScalarPSO : resampleVectorPSO,
                textures: [field.texture, texture],
                grid: texture
              ) else {
            return zero(kind: field.kind, width: width, height: height)
        }
        let result = GPUControlField(kind: field.kind, texture: texture, revision: field.revision)
        resampled[resampleKey] = result
        resampleCount += 1
        return result
    }

    func zero(kind: ControlFieldKind, width: Int, height: Int) -> GPUControlField {
        let key = ZeroKey(kind: kind, width: max(1, width), height: max(1, height))
        if let cached = zeros[key] { return cached }
        guard let texture = makeTexture(kind: kind, width: key.width, height: key.height),
              encode(
                pipeline: kind == .scalar ? clearScalarPSO : clearVectorPSO,
                textures: [texture],
                grid: texture
              ) else {
            preconditionFailure("Unable to allocate required zero control field")
        }
        let result = GPUControlField(kind: kind, texture: texture, revision: 0)
        zeros[key] = result
        zeroAllocationCount += 1
        return result
    }

    func remove(provider: UUID) {
        published = published.filter { $0.key.provider != provider }
        resampled = resampled.filter { $0.key.source.provider != provider }
    }

    func reset() {
        published.removeAll()
        zeros.removeAll()
        resampled.removeAll()
        zeroAllocationCount = 0
        resampleCount = 0
    }

    #if DEBUG
    func runSelfCheck() {
        let missingScalar = ControlFieldReference(provider: UUID(), output: .paperDrag)
        let a = resolve(missingScalar, width: 7, height: 5)
        let b = resolve(missingScalar, width: 7, height: 5)
        assert(a.kind == .scalar && a.texture.pixelFormat == .r16Float)
        assert(a.texture === b.texture && zeroAllocationCount == 1)

        let missingVector = ControlFieldReference(provider: UUID(), output: .motionVector)
        let vector = resolve(missingVector, width: 7, height: 5)
        assert(vector.kind == .vector && vector.texture.pixelFormat == .rg16Float)
        assert(zeroAllocationCount == 2)

        let provider = UUID()
        let reference = ControlFieldReference(provider: provider, output: .paperDrag)
        guard let oldTexture = makeTexture(kind: .scalar, width: 3, height: 2),
              let newTexture = makeTexture(kind: .scalar, width: 3, height: 2) else {
            assertionFailure("Unable to allocate control-field self-check textures")
            return
        }
        publish(GPUControlField(kind: .scalar, texture: newTexture, revision: 2), provider: provider, output: .paperDrag)
        publish(GPUControlField(kind: .scalar, texture: oldTexture, revision: 1), provider: provider, output: .paperDrag)
        assert(resolve(reference, width: 3, height: 2).texture === newTexture)
        remove(provider: provider)
        assert(resolve(reference, width: 3, height: 2).revision == 0)
    }
    #endif

    private static func pipeline(
        _ name: String,
        library: MTLLibrary,
        device: MTLDevice
    ) -> MTLComputePipelineState? {
        guard let function = library.makeFunction(name: name) else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }

    private func makeTexture(kind: ControlFieldKind, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: kind == .scalar ? .r16Float : .rg16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    @discardableResult
    private func encode(
        pipeline: MTLComputePipelineState,
        textures: [MTLTexture],
        grid: MTLTexture
    ) -> Bool {
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        encoder.dispatchThreads(
            MTLSize(width: grid.width, height: grid.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }
}
