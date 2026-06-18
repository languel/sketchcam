import Foundation
import Metal
import SketchCamCore

final class CombinedMotionFieldProvider: GPUControlFieldProvider {
    private struct Params { var maximumForce: Float }

    let id: UUID
    let outputs: Set<ControlFieldOutputID> = [.motionMagnitude, .motionVector]

    private let inputs: [ControlFieldReference]
    private let config: MotionControlConfig
    private let quality: ControlFieldUpdateQuality
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var vector: MTLTexture?
    private var magnitude: MTLTexture?
    private var revision: UInt64 = 0

    init?(settings: ControlFieldProvider, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard settings.kind == .combinedMotion,
              settings.inputs.count >= 2,
              let device,
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "control_combine_motion"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }
        id = settings.id
        inputs = settings.inputs
        config = settings.resolvedMotionConfig
        quality = settings.quality
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    func update(_ context: ControlFieldFrameContext, store: GPUControlFieldStore) {
        let size = fieldSize(context)
        guard ensureTextures(width: size.width, height: size.height),
              let vector, let magnitude,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        let trackedReference = ControlFieldReference(provider: inputs[0].provider, output: .motionVector)
        let trackedMagnitudeReference = ControlFieldReference(provider: inputs[0].provider, output: .motionMagnitude)
        let denseReference = ControlFieldReference(provider: inputs[1].provider, output: .motionVector)
        let tracked = store.resolve(trackedReference, width: size.width, height: size.height)
        let trackedMagnitude = store.resolve(trackedMagnitudeReference, width: size.width, height: size.height)
        let dense = store.resolve(denseReference, width: size.width, height: size.height)
        var params = Params(maximumForce: max(0, config.maximumForce))
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(tracked.texture, index: 0)
        encoder.setTexture(trackedMagnitude.texture, index: 1)
        encoder.setTexture(dense.texture, index: 2)
        encoder.setTexture(vector, index: 3)
        encoder.setTexture(magnitude, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: size.width, height: size.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return }
        revision &+= 1
        store.publish(GPUControlField(kind: .vector, texture: vector, revision: revision), provider: id, output: .motionVector)
        store.publish(GPUControlField(kind: .scalar, texture: magnitude, revision: revision), provider: id, output: .motionMagnitude)
    }

    func reset(store: GPUControlFieldStore) {
        vector = nil
        magnitude = nil
        revision = 0
        store.remove(provider: id)
    }

    private func fieldSize(_ context: ControlFieldFrameContext) -> (width: Int, height: Int) {
        let limit: CGFloat = quality == .low ? 256 : (quality == .medium ? 384 : 512)
        let scale = min(1, limit / max(max(context.outputSize.width, context.outputSize.height), 1))
        return (max(1, Int(context.outputSize.width * scale)), max(1, Int(context.outputSize.height * scale)))
    }

    private func ensureTextures(width: Int, height: Int) -> Bool {
        if vector?.width == width, vector?.height == height { return true }
        vector = makeTexture(format: .rg16Float, width: width, height: height)
        magnitude = makeTexture(format: .r16Float, width: width, height: height)
        return vector != nil && magnitude != nil
    }

    private func makeTexture(format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }
}
