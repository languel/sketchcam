import CoreGraphics
import CoreMedia
import Foundation
import Metal
import SketchCamCore

struct TrackedMotionSample {
    let position: SIMD2<Float>
    let velocity: SIMD2<Float>
}

final class TrackedMotionFieldProvider: GPUControlFieldProvider {
    private struct SplatParams {
        var resolution: SIMD2<Float>
        var origin: SIMD2<UInt32>
        var center: SIMD2<Float>
        var radiusSq: Float
        var padding: Float = 0
        var velocity: SIMD2<Float>
    }

    private struct NormalizeParams {
        var smoothing: Float
        var decay: Float
        var maximumForce: Float
        var threshold: Float
    }

    let id: UUID
    let outputs: Set<ControlFieldOutputID> = [.motionMagnitude, .motionVector]

    private let config: MotionControlConfig
    private let quality: ControlFieldUpdateQuality
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let clearScalarPSO: MTLComputePipelineState
    private let clearVectorPSO: MTLComputePipelineState
    private let splatPSO: MTLComputePipelineState
    private let normalizePSO: MTLComputePipelineState

    private var vectorSum: MTLTexture?
    private var weightSum: MTLTexture?
    private var vectorPing: MTLTexture?
    private var vectorPong: MTLTexture?
    private var magnitude: MTLTexture?
    private var previousDetection: LandmarkDetection?
    private var previousTimestamp: CMTime?
    private var lastDetectionID: UInt64?
    private var revision: UInt64 = 0
    #if DEBUG
    private(set) var debugLastDecay: Float = 0
    var debugRevision: UInt64 { revision }
    #endif

    init?(settings: ControlFieldProvider, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard settings.kind == .trackedMotion,
              let device,
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let clearScalar = Self.pipeline("control_clear_scalar", library: library, device: device),
              let clearVector = Self.pipeline("control_clear_vector", library: library, device: device),
              let splat = Self.pipeline("control_splat_tracked_motion", library: library, device: device),
              let normalize = Self.pipeline("control_normalize_tracked_motion", library: library, device: device)
        else { return nil }
        id = settings.id
        config = settings.resolvedMotionConfig
        quality = settings.quality
        self.device = device
        self.queue = queue
        clearScalarPSO = clearScalar
        clearVectorPSO = clearVector
        splatPSO = splat
        normalizePSO = normalize
    }

    func update(_ context: ControlFieldFrameContext, store: GPUControlFieldStore) {
        let size = fieldSize(for: context)
        guard ensureTextures(width: size.width, height: size.height),
              let vectorSum, let weightSum, let previous = vectorPing,
              let output = vectorPong, let magnitude,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        let isNewDetection = context.detection.map { $0.detectionID != lastDetectionID } ?? false
        let elapsed = elapsedTime(to: context.timestamp)
        let samples: [TrackedMotionSample]
        if isNewDetection, let previousDetection, let current = context.detection {
            samples = Self.matchedSamples(
                previous: previousDetection,
                current: current,
                elapsed: elapsed,
                config: config
            )
        } else {
            samples = []
        }

        encodeClear(vectorSum, pipeline: clearVectorPSO, encoder: encoder)
        encodeClear(weightSum, pipeline: clearScalarPSO, encoder: encoder)
        encoder.memoryBarrier(resources: [vectorSum, weightSum])
        for sample in samples {
            encode(sample: sample, target: vectorSum, weight: weightSum, encoder: encoder)
            encoder.memoryBarrier(resources: [vectorSum, weightSum])
        }
        var normalize = NormalizeParams(
            smoothing: config.smoothing,
            decay: config.decay,
            maximumForce: max(0, config.maximumForce),
            threshold: max(0, config.threshold)
        )
        encoder.setComputePipelineState(normalizePSO)
        encoder.setTexture(vectorSum, index: 0)
        encoder.setTexture(weightSum, index: 1)
        encoder.setTexture(previous, index: 2)
        encoder.setTexture(output, index: 3)
        encoder.setTexture(magnitude, index: 4)
        encoder.setBytes(&normalize, length: MemoryLayout<NormalizeParams>.stride, index: 0)
        dispatch(texture: output, encoder: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return }

        vectorPing = output
        vectorPong = previous
        revision &+= 1
        store.publish(GPUControlField(kind: .vector, texture: output, revision: revision), provider: id, output: .motionVector)
        store.publish(GPUControlField(kind: .scalar, texture: magnitude, revision: revision), provider: id, output: .motionMagnitude)

        if isNewDetection, let detection = context.detection {
            previousDetection = detection
            previousTimestamp = context.timestamp
            lastDetectionID = detection.detectionID
        }
        #if DEBUG
        debugLastDecay = samples.isEmpty ? config.decay : 1
        #endif
    }

    func reset(store: GPUControlFieldStore) {
        vectorSum = nil
        weightSum = nil
        vectorPing = nil
        vectorPong = nil
        magnitude = nil
        previousDetection = nil
        previousTimestamp = nil
        lastDetectionID = nil
        revision = 0
        store.remove(provider: id)
    }

    static func matchedSamples(
        previous: LandmarkDetection,
        current: LandmarkDetection,
        elapsed: Double,
        config: MotionControlConfig
    ) -> [TrackedMotionSample] {
        let dt = Float(max(elapsed, 1.0 / 240.0))
        let confidenceFloor: Float = 0.2
        var oldPoints: [String: CGPoint] = [:]
        for group in previous.groups {
            for point in group.points where point.confidence >= confidenceFloor {
                guard let label = point.label else { continue }
                oldPoints["\(group.region.rawValue):\(label)"] = point.point
            }
        }
        var result: [TrackedMotionSample] = []
        for group in current.groups {
            for point in group.points where point.confidence >= confidenceFloor {
                guard let label = point.label,
                      let old = oldPoints["\(group.region.rawValue):\(label)"] else { continue }
                var velocity = SIMD2<Float>(
                    Float(point.point.x - old.x) / dt,
                    Float(point.point.y - old.y) / dt
                ) * max(0, config.sensitivity)
                let speed = sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
                let limit = max(0, config.maximumForce)
                if speed > limit, speed > 0 { velocity *= limit / speed }
                guard sqrt(velocity.x * velocity.x + velocity.y * velocity.y) >= max(0, config.threshold) else { continue }
                result.append(TrackedMotionSample(
                    position: SIMD2(Float(point.point.x), Float(point.point.y)),
                    velocity: velocity
                ))
            }
        }
        return result
    }

    private func elapsedTime(to timestamp: CMTime) -> Double {
        guard let previousTimestamp else { return 1.0 / 30.0 }
        let seconds = CMTimeGetSeconds(timestamp - previousTimestamp)
        return seconds.isFinite && seconds > 0 ? seconds : 1.0 / 30.0
    }

    private func fieldSize(for context: ControlFieldFrameContext) -> (width: Int, height: Int) {
        let limit: CGFloat
        switch quality {
        case .low: limit = 128
        case .medium: limit = 256
        case .high: limit = 512
        }
        let scale = min(1, limit / max(context.outputSize.width, context.outputSize.height, 1))
        return (
            max(1, Int((context.outputSize.width * scale).rounded())),
            max(1, Int((context.outputSize.height * scale).rounded()))
        )
    }

    private func ensureTextures(width: Int, height: Int) -> Bool {
        if vectorPing?.width == width, vectorPing?.height == height { return true }
        vectorSum = makeTexture(format: .rg16Float, width: width, height: height)
        weightSum = makeTexture(format: .r16Float, width: width, height: height)
        vectorPing = makeTexture(format: .rg16Float, width: width, height: height)
        vectorPong = makeTexture(format: .rg16Float, width: width, height: height)
        magnitude = makeTexture(format: .r16Float, width: width, height: height)
        guard let vectorPing, let vectorPong,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encodeClear(vectorPing, pipeline: clearVectorPSO, encoder: encoder)
        encodeClear(vectorPong, pipeline: clearVectorPSO, encoder: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed && vectorSum != nil && weightSum != nil && magnitude != nil
    }

    private func makeTexture(format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private func encodeClear(_ texture: MTLTexture, pipeline: MTLComputePipelineState, encoder: MTLComputeCommandEncoder) {
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        dispatch(texture: texture, encoder: encoder)
    }

    private func encode(
        sample: TrackedMotionSample,
        target: MTLTexture,
        weight: MTLTexture,
        encoder: MTLComputeCommandEncoder
    ) {
        let radius = max(0.005, 0.06 * max(0.05, config.spatialScale))
        let pixelRadiusX = Int(ceil(radius * 3 * Float(target.width)))
        let pixelRadiusY = Int(ceil(radius * 3 * Float(target.height)))
        let centerX = Int(sample.position.x * Float(target.width))
        let centerY = Int(sample.position.y * Float(target.height))
        let minX = max(0, centerX - pixelRadiusX)
        let minY = max(0, centerY - pixelRadiusY)
        let maxX = min(target.width, centerX + pixelRadiusX + 1)
        let maxY = min(target.height, centerY + pixelRadiusY + 1)
        guard maxX > minX, maxY > minY else { return }
        var params = SplatParams(
            resolution: SIMD2(Float(target.width), Float(target.height)),
            origin: SIMD2(UInt32(minX), UInt32(minY)),
            center: sample.position,
            radiusSq: radius * radius,
            velocity: sample.velocity
        )
        encoder.setComputePipelineState(splatPSO)
        encoder.setTexture(target, index: 0)
        encoder.setTexture(weight, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<SplatParams>.stride, index: 0)
        encoder.dispatchThreads(
            MTLSize(width: maxX - minX, height: maxY - minY, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
    }

    private func dispatch(texture: MTLTexture, encoder: MTLComputeCommandEncoder) {
        encoder.dispatchThreads(
            MTLSize(width: texture.width, height: texture.height, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1)
        )
    }

    private static func pipeline(_ name: String, library: MTLLibrary, device: MTLDevice) -> MTLComputePipelineState? {
        guard let function = library.makeFunction(name: name) else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }
}
