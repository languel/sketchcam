import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import Metal
import SketchCamCore
import Vision

final class OpticalFlowFieldProvider: GPUControlFieldProvider {
    private struct PendingFlow {
        let pixelBuffer: CVPixelBuffer
        let elapsed: Double
    }

    private struct FilterParams {
        var inputSize: SIMD2<Float>
        var elapsed: Float
        var sensitivity: Float
        var threshold: Float
        var smoothing: Float
        var decay: Float
        var maximumForce: Float
        var hasFlow: UInt32
    }

    let id: UUID
    let outputs: Set<ControlFieldOutputID> = [.motionMagnitude, .motionVector]

    private let config: MotionControlConfig
    private let quality: ControlFieldUpdateQuality
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let visionQueue = DispatchQueue(label: "io.github.languel.sketchcam.optical-flow", qos: .userInitiated)
    private let lock = NSLock()
    private let ciContext: CIContext
    private let filterPSO: MTLComputePipelineState
    private let clearVectorPSO: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache

    private var previousFrame: CVPixelBuffer?
    private var previousTimestamp: CMTime?
    private var requestInFlight = false
    private var pendingFlow: PendingFlow?
    private var generation: UInt64 = 0
    private var inputAvailable = false
    private var vectorPing: MTLTexture?
    private var vectorPong: MTLTexture?
    private var magnitude: MTLTexture?
    private var zeroFlow: MTLTexture?
    private var revision: UInt64 = 0
    #if DEBUG
    private(set) var debugScheduledRequestCount = 0
    #endif

    init?(settings: ControlFieldProvider, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard settings.kind == .opticalFlow,
              let device,
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let filter = Self.pipeline("control_filter_optical_flow", library: library, device: device),
              let clearVector = Self.pipeline("control_clear_vector", library: library, device: device)
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        id = settings.id
        config = settings.resolvedMotionConfig
        quality = settings.quality
        self.device = device
        self.queue = queue
        ciContext = CIContext(mtlDevice: device)
        filterPSO = filter
        clearVectorPSO = clearVector
        textureCache = cache
    }

    func update(_ context: ControlFieldFrameContext, store: GPUControlFieldStore) {
        let selected = selectedInput(context)
        if let selected { inputAvailable = true; scheduleIfIdle(selected, timestamp: context.timestamp) }
        else { clearInputHistory() }

        let pending = lock.withLock { () -> PendingFlow? in
            defer { pendingFlow = nil }
            return pendingFlow
        }
        let size = fieldSize(for: context, pending: pending)
        guard ensureTextures(width: size.width, height: size.height),
              let previous = vectorPing, let output = vectorPong,
              let magnitude, let zeroFlow,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder()
        else { return }

        var retainedCVTexture: CVMetalTexture?
        let rawTexture: MTLTexture
        if let pending,
           let wrapped = makeFlowTexture(from: pending.pixelBuffer) {
            retainedCVTexture = wrapped.cvTexture
            rawTexture = wrapped.texture
        } else {
            rawTexture = zeroFlow
        }
        var params = FilterParams(
            inputSize: SIMD2(Float(rawTexture.width), Float(rawTexture.height)),
            elapsed: Float(pending?.elapsed ?? (1.0 / 30.0)),
            sensitivity: config.sensitivity,
            threshold: config.threshold,
            smoothing: config.smoothing,
            decay: config.decay,
            maximumForce: config.maximumForce,
            hasFlow: pending == nil ? 0 : 1
        )
        encoder.setComputePipelineState(filterPSO)
        encoder.setTexture(rawTexture, index: 0)
        encoder.setTexture(previous, index: 1)
        encoder.setTexture(output, index: 2)
        encoder.setTexture(magnitude, index: 3)
        encoder.setBytes(&params, length: MemoryLayout<FilterParams>.stride, index: 0)
        dispatch(texture: output, encoder: encoder)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        _ = retainedCVTexture
        guard commandBuffer.status == .completed else { return }

        vectorPing = output
        vectorPong = previous
        revision &+= 1
        store.publish(GPUControlField(kind: .vector, texture: output, revision: revision), provider: id, output: .motionVector)
        store.publish(GPUControlField(kind: .scalar, texture: magnitude, revision: revision), provider: id, output: .motionMagnitude)
    }

    func reset(store: GPUControlFieldStore) {
        lock.withLock {
            generation &+= 1
            previousFrame = nil
            previousTimestamp = nil
            pendingFlow = nil
        }
        vectorPing = nil
        vectorPong = nil
        magnitude = nil
        zeroFlow = nil
        revision = 0
        CVMetalTextureCacheFlush(textureCache, 0)
        store.remove(provider: id)
    }

    static func thresholdedMagnitude(_ vector: SIMD2<Float>, threshold: Float) -> Float {
        let magnitude = sqrt(vector.x * vector.x + vector.y * vector.y)
        return magnitude >= max(0, threshold) ? magnitude : 0
    }

    #if DEBUG
    static func debugMedianFlow(
        previous: CVPixelBuffer,
        current: CVPixelBuffer,
        quality: ControlFieldUpdateQuality
    ) -> SIMD2<Float>? {
        // Vision reports flow from the handler image toward the targeted image.
        // Use previous -> current so the field matches cursor/solver velocity.
        let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: current, options: [:])
        request.computationAccuracy = quality == .high ? .medium : .low
        request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
        request.keepNetworkOutput = false
        let handler = VNImageRequestHandler(cvPixelBuffer: previous, options: [:])
        guard (try? handler.perform([request])) != nil,
              let flow = request.results?.first?.pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(flow, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(flow, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(flow) else { return nil }
        let width = CVPixelBufferGetWidth(flow)
        let height = CVPixelBufferGetHeight(flow)
        let rowBytes = CVPixelBufferGetBytesPerRow(flow)
        var xs: [Float] = []
        var ys: [Float] = []
        for y in stride(from: 0, to: height, by: 2) {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
            for x in stride(from: 0, to: width, by: 2) {
                let vx = Float(Float16(bitPattern: row[x * 2]))
                let vy = Float(Float16(bitPattern: row[x * 2 + 1]))
                if vx.isFinite, vy.isFinite, abs(vx) + abs(vy) > 0.05 {
                    xs.append(vx)
                    ys.append(vy)
                }
            }
        }
        guard !xs.isEmpty else { return nil }
        xs.sort(); ys.sort()
        return SIMD2(xs[xs.count / 2], ys[ys.count / 2])
    }
    #endif

    private func selectedInput(_ context: ControlFieldFrameContext) -> CVPixelBuffer? {
        switch config.input {
        case .camera: return context.cameraPixelBuffer
        case .movie: return context.moviePixelBuffer
        case .inkTexture: return context.inkTexturePixelBuffer
        }
    }

    private func scheduleIfIdle(_ source: CVPixelBuffer, timestamp: CMTime) {
        guard let current = downsample(source) else { return }
        let work: (previous: CVPixelBuffer, current: CVPixelBuffer, elapsed: Double, generation: UInt64)? = lock.withLock {
            guard !requestInFlight else { return nil }
            guard let previousFrame else {
                self.previousFrame = current
                previousTimestamp = timestamp
                return nil
            }
            guard CVPixelBufferGetWidth(previousFrame) == CVPixelBufferGetWidth(current),
                  CVPixelBufferGetHeight(previousFrame) == CVPixelBufferGetHeight(current) else {
                self.previousFrame = current
                previousTimestamp = timestamp
                return nil
            }
            let seconds = previousTimestamp.map { CMTimeGetSeconds(timestamp - $0) } ?? (1.0 / 30.0)
            requestInFlight = true
            self.previousFrame = current
            previousTimestamp = timestamp
            #if DEBUG
            debugScheduledRequestCount += 1
            #endif
            return (previousFrame, current, seconds.isFinite && seconds > 0 ? seconds : 1.0 / 30.0, generation)
        }
        guard let work else { return }
        let accuracy: VNGenerateOpticalFlowRequest.ComputationAccuracy = quality == .high ? .medium : .low
        visionQueue.async { [weak self] in
            guard let self else { return }
            // Generate forward temporal flow (previous -> current). Reversing
            // these frames makes physical advection move opposite the subject.
            let request = VNGenerateOpticalFlowRequest(targetedCVPixelBuffer: work.current, options: [:])
            request.computationAccuracy = accuracy
            request.outputPixelFormat = kCVPixelFormatType_TwoComponent16Half
            request.keepNetworkOutput = false
            let handler = VNImageRequestHandler(cvPixelBuffer: work.previous, options: [:])
            let result: CVPixelBuffer? = (try? handler.perform([request])).flatMap { request.results?.first?.pixelBuffer }
            self.lock.withLock {
                self.requestInFlight = false
                guard work.generation == self.generation else { return }
                if let result { self.pendingFlow = PendingFlow(pixelBuffer: result, elapsed: work.elapsed) }
            }
        }
    }

    private func clearInputHistory() {
        lock.withLock {
            if inputAvailable {
                generation &+= 1
                pendingFlow = nil
                inputAvailable = false
            }
            previousFrame = nil
            previousTimestamp = nil
        }
    }

    private func downsample(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sourceWidth = CVPixelBufferGetWidth(source)
        let sourceHeight = CVPixelBufferGetHeight(source)
        let limit: Int
        switch quality {
        case .low: limit = 256
        case .medium: limit = 384
        case .high: limit = 512
        }
        let scale = min(1, Double(limit) / Double(max(sourceWidth, sourceHeight)))
        let width = max(1, Int((Double(sourceWidth) * scale).rounded()))
        let height = max(1, Int((Double(sourceHeight) * scale).rounded()))
        guard let output = makePixelBuffer(width: width, height: height) else { return nil }
        let image = CIImage(cvPixelBuffer: source).transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / CGFloat(sourceWidth),
            y: CGFloat(height) / CGFloat(sourceHeight)
        ))
        ciContext.render(image, to: output, bounds: CGRect(x: 0, y: 0, width: width, height: height), colorSpace: nil)
        return output
    }

    private func makePixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:],
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess else { return nil }
        return buffer
    }

    private func fieldSize(for context: ControlFieldFrameContext, pending: PendingFlow?) -> (width: Int, height: Int) {
        if let pending {
            return (CVPixelBufferGetWidth(pending.pixelBuffer), CVPixelBufferGetHeight(pending.pixelBuffer))
        }
        if let vectorPing { return (vectorPing.width, vectorPing.height) }
        let limit: CGFloat = quality == .low ? 256 : (quality == .medium ? 384 : 512)
        let scale = min(1, limit / max(max(context.outputSize.width, context.outputSize.height), 1))
        return (max(1, Int(context.outputSize.width * scale)), max(1, Int(context.outputSize.height * scale)))
    }

    private func ensureTextures(width: Int, height: Int) -> Bool {
        if vectorPing?.width == width, vectorPing?.height == height { return true }
        vectorPing = makeTexture(format: .rg16Float, width: width, height: height)
        vectorPong = makeTexture(format: .rg16Float, width: width, height: height)
        magnitude = makeTexture(format: .r16Float, width: width, height: height)
        zeroFlow = makeTexture(format: .rg16Float, width: width, height: height)
        guard let vectorPing, let vectorPong, let zeroFlow,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        for texture in [vectorPing, vectorPong, zeroFlow] {
            encoder.setComputePipelineState(clearVectorPSO)
            encoder.setTexture(texture, index: 0)
            dispatch(texture: texture, encoder: encoder)
        }
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed && magnitude != nil
    }

    private func makeTexture(format: MTLPixelFormat, width: Int, height: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        return device.makeTexture(descriptor: descriptor)
    }

    private func makeFlowTexture(from buffer: CVPixelBuffer) -> (cvTexture: CVMetalTexture, texture: MTLTexture)? {
        var cvTexture: CVMetalTexture?
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, buffer, nil, .rg16Float, width, height, 0, &cvTexture
        ) == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return (cvTexture, texture)
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
