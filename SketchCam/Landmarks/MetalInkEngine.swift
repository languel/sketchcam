import CoreImage
import CoreVideo
import Foundation
import Metal
import SketchCamCore
import SketchCamShared
import simd

final class MetalInkEngine {
    private static let dyeBase = 2048
    private static let simBase = 256
    private static let pressureIterations = 22
    private static let inkAbs = SIMD3<Float>(1.00, 0.97, 0.88)

    private struct RebuildKey: Equatable {
        var outputWidth: Int
        var outputHeight: Int
    }

    /// Display-affecting settings; when unchanged (and the sim is idle) the
    /// engine reuses the cached image instead of re-rendering.
    private struct RenderSignature: Equatable {
        var paperOn: Bool
        var grain: Float
        var opacity: Float
        var colorSep: Float
    }

    private struct LivePointerState {
        var bx: Float
        var by: Float
        var speed: Float
        var simPressure: Float
        var stirPhase: Float
    }

    private struct SplatParams {
        var targetSize: SIMD2<Float>
        var origin: SIMD2<UInt32>
        var aspect: Float
        var pad0: Float = 0
        var point: SIMD2<Float>
        var radiusSq: Float
        var blendMode: UInt32
        var color: SIMD4<Float>
    }

    private struct CapsuleParams {
        var targetSize: SIMD2<Float>
        var origin: SIMD2<UInt32>
        var aspect: Float
        var edge: Float
        var a: SIMD2<Float>
        var b: SIMD2<Float>
        var ra: Float
        var rb: Float
        var blendMode: UInt32
        var pad0: Float = 0
        var color: SIMD4<Float>
    }

    private struct CopyParams { var value: Float }
    private struct AdvectVelocityParams { var texel: SIMD2<Float>; var dt: Float; var dissipation: Float }
    private struct VorticityParams { var texel: SIMD2<Float>; var curlAmount: Float; var dt: Float }
    private struct AdvectWetParams {
        var velTexel: SIMD2<Float>
        var wetTexel: SIMD2<Float>
        var dt: Float
        var decay: Float
        var spread: Float
        var pad0: Float = 0
    }
    private struct AdvectInkParams {
        var velTexel: SIMD2<Float>
        var inkTexel: SIMD2<Float>
        var dt: Float
        var bleed: Float
        var aspect: Float
        var pad0: Float = 0
        var chroma: SIMD4<Float>
        var brush: SIMD4<Float>
    }
    private struct ExchangeParams {
        var settle: Float
        var dt: Float
        var aspect: Float
        var mode: Float
        var brush: SIMD4<Float>
    }
    private struct DisplayParams {
        var texel: SIMD2<Float>
        var res: SIMD2<Float>
        var inkStrength: Float
        var edge: Float
        var grain: Float
        var whiteTint: Float
        var opacity: Float
        var paperOn: Float
    }

    private final class DoubleTexture {
        var read: MTLTexture
        var write: MTLTexture

        init(read: MTLTexture, write: MTLTexture) {
            self.read = read
            self.write = write
        }

        func swap() {
            Swift.swap(&read, &write)
        }
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let textureCache: CVMetalTextureCache
    private let clearPSO: MTLComputePipelineState
    private let copyPSO: MTLComputePipelineState
    private let splatPSO: MTLComputePipelineState
    private let capsulePSO: MTLComputePipelineState
    private let advectVelocityPSO: MTLComputePipelineState
    private let curlPSO: MTLComputePipelineState
    private let vorticityPSO: MTLComputePipelineState
    private let divergencePSO: MTLComputePipelineState
    private let pressurePSO: MTLComputePipelineState
    private let gradientSubtractPSO: MTLComputePipelineState
    private let advectWetPSO: MTLComputePipelineState
    private let advectInkPSO: MTLComputePipelineState
    private let exchangePSO: MTLComputePipelineState
    private let displayPSO: MTLComputePipelineState

    private var velocity: DoubleTexture?
    private var pressure: DoubleTexture?
    private var ink: DoubleTexture?
    private var fixed: DoubleTexture?
    private var wet: DoubleTexture?
    private var divergence: MTLTexture?
    private var curl: MTLTexture?
    private var outputBuffer: CVPixelBuffer?
    private var outputTexture: MTLTexture?
    private var dyeSize = SIMD2<Int32>(0, 0)
    private var simSize = SIMD2<Int32>(0, 0)
    private var outputSize = SIMD2<Int32>(0, 0)
    private var rebuildKey: RebuildKey?
    private var lastFrameIndex: Int?
    private var lastFixRevision = 0
    private var lastRebuildRevision = 0
    private var lastStepTime: CFAbsoluteTime = 0
    private var fixTimer: Float = 0
    private var brushNow = SIMD3<Float>(0, 0, 0)
    /// Destructive lift under the brush (immediate wash re-mobilizes dried ink);
    /// 0 = additive wash. Rides in the exchange brush.w.
    private var brushLift: Float = 0
    private var activeFramesRemaining = 0
    private var replayedPaths: [InkEditorPath] = []
    private var livePointerStates: [UUID: LivePointerState] = [:]
    /// Strokes whose ink was injected live (already on the canvas); the
    /// committed path with the same id must NOT be replayed (avoids the double
    /// mark). Cleared on full rebuild/replay.
    private var bakedLiveIDs: Set<UUID> = []
    private var lastRenderSig: RenderSignature?
    private var cachedImage: CIImage?

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary()
        else { return nil }
        func pso(_ name: String) -> MTLComputePipelineState? {
            guard let fn = library.makeFunction(name: name) else { return nil }
            return try? device.makeComputePipelineState(function: fn)
        }
        guard let clear = pso("ink_clear"),
              let copy = pso("ink_copy"),
              let splat = pso("ink_splat"),
              let capsule = pso("ink_splat_capsule"),
              let advectVelocity = pso("ink_advect_velocity"),
              let curl = pso("ink_curl"),
              let vorticity = pso("ink_vorticity"),
              let divergence = pso("ink_divergence"),
              let pressure = pso("ink_pressure"),
              let gradientSubtract = pso("ink_gradient_subtract"),
              let advectWet = pso("ink_advect_wet"),
              let advectInk = pso("ink_advect_ink"),
              let exchange = pso("ink_exchange"),
              let display = pso("ink_display")
        else { return nil }
        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.device = device
        self.queue = queue
        self.textureCache = cache
        self.clearPSO = clear
        self.copyPSO = copy
        self.splatPSO = splat
        self.capsulePSO = capsule
        self.advectVelocityPSO = advectVelocity
        self.curlPSO = curl
        self.vorticityPSO = vorticity
        self.divergencePSO = divergence
        self.pressurePSO = pressure
        self.gradientSubtractPSO = gradientSubtract
        self.advectWetPSO = advectWet
        self.advectInkPSO = advectInk
        self.exchangePSO = exchange
        self.displayPSO = display
    }

    func reset() {
        velocity = nil
        pressure = nil
        ink = nil
        fixed = nil
        wet = nil
        divergence = nil
        curl = nil
        outputBuffer = nil
        outputTexture = nil
        dyeSize = SIMD2(0, 0)
        simSize = SIMD2(0, 0)
        outputSize = SIMD2(0, 0)
        rebuildKey = nil
        lastFrameIndex = nil
        lastFixRevision = 0
        lastRebuildRevision = 0
        lastStepTime = 0
        fixTimer = 0
        brushNow = SIMD3(0, 0, 0)
        brushLift = 0
        activeFramesRemaining = 0
        replayedPaths = []
        livePointerStates = [:]
        bakedLiveIDs = []
        lastRenderSig = nil
        cachedImage = nil
    }

    func layer(settings: ProcessingSettings, live: InkLiveStrokeSample?, livePoints: [CGPoint], endedLiveID: UUID?, outputSize requested: CGSize, frameIndex: Int) -> CIImage? {
        let l = settings.landmarks
        let width = max(1, Int(requested.width.rounded()))
        let height = max(1, Int(requested.height.rounded()))
        let replayablePaths = l.inkPaths.filter { $0.points.count > 1 }

        let key = RebuildKey(outputWidth: width, outputHeight: height)
        let rebuildRevision = l.inkRebuildRevision
        let forceRebuild = rebuildRevision != lastRebuildRevision
        let needRebuild = key != rebuildKey || outputBuffer == nil || forceRebuild
        if forceRebuild { lastRebuildRevision = rebuildRevision }
        let pathsChanged = replayablePaths != replayedPaths
        let fixRevision = l.inkFixRevision ?? 0
        let fixRequested = fixRevision != lastFixRevision
        let renderSig = RenderSignature(
            paperOn: l.inkPaperEnabled,
            grain: clamp01(l.inkPaperGrain),
            opacity: clamp01(l.inkOpacity),
            colorSep: clamp01(l.inkColorSeparation ?? 0.5)
        )
        let sigChanged = renderSig != lastRenderSig
        let evolving = activeFramesRemaining > 0 || fixTimer > 0 || live != nil || endedLiveID != nil

        // Nothing to draw at all → blank.
        if !l.inkPaperEnabled, replayablePaths.isEmpty, live == nil, !evolving, !needRebuild {
            cachedImage = nil
            return nil
        }
        // Idle and already rendered → reuse the cached image (no GPU work, no
        // synchronous wait). This is the steady state once ink has dried.
        if !needRebuild, !pathsChanged, !fixRequested, !sigChanged, !evolving, let cachedImage {
            return cachedImage
        }

        guard let commandBuffer = queue.makeCommandBuffer() else { return cachedImage }

        // A finished stroke's wet ink is already on the canvas (drawn live). On
        // a reconcile (not a full rebuild) mark it baked BEFORE reconciling so
        // the committed path with the same id is skipped — avoids the double
        // mark. On a full rebuild the path is redrawn by replay instead.
        if let endedLiveID, !needRebuild {
            bakedLiveIDs.insert(endedLiveID)
        }

        if needRebuild {
            guard configure(width: width, height: height) else { return cachedImage }
            clearAll(commandBuffer)
            bakedLiveIDs = []
            replay(paths: replayablePaths, settings: settings, commandBuffer: commandBuffer)
            replayedPaths = replayablePaths
            livePointerStates = [:]
            rebuildKey = key
            lastFrameIndex = nil
            activeFramesRemaining = replayablePaths.isEmpty ? 0 : 180
        } else if pathsChanged {
            reconcileCommittedPaths(replayablePaths, settings: settings, commandBuffer: commandBuffer)
        }

        // Dry the just-finished stroke into the fixed paper layer.
        if endedLiveID != nil {
            fixTimer = max(fixTimer, 1.2)
            activeFramesRemaining = max(activeFramesRemaining, 90)
        }
        if fixRequested {
            fixTimer = 1.2
            lastFixRevision = fixRevision
            activeFramesRemaining = max(activeFramesRemaining, 90)
        }

        if lastFrameIndex != frameIndex {
            // Real elapsed time, clamped, instead of a fixed 1/60 — so stroke
            // speed/pressure and the fluid step stay correct when the frame rate
            // is irregular (notably right after the app is tabbed out and back).
            let now = CFAbsoluteTimeGetCurrent()
            let dt: Float = lastStepTime > 0 ? Float(min(1.0 / 20.0, max(1.0 / 120.0, now - lastStepTime))) : 1.0 / 60.0
            lastStepTime = now
            let liveActive = updateLiveStroke(live, points: livePoints, settings: settings, dt: dt, commandBuffer: commandBuffer)
            if liveActive {
                activeFramesRemaining = max(activeFramesRemaining, 120)
            }
            if activeFramesRemaining > 0 || liveActive {
                step(settings: settings, dt: dt, commandBuffer: commandBuffer)
                activeFramesRemaining = max(0, activeFramesRemaining - 1)
            }
            lastFrameIndex = frameIndex
        }
        render(settings: settings, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        lastRenderSig = renderSig

        guard let outputBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: outputBuffer).cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        cachedImage = image
        return image
    }

    private func configure(width: Int, height: Int) -> Bool {
        let out = SIMD2(Int32(width), Int32(height))
        if outputSize == out, outputBuffer != nil, outputTexture != nil { return true }
        outputSize = out
        let shortSide = max(1, min(width, height))
        let dyeScale = Float(min(Self.dyeBase, shortSide)) / Float(shortSide)
        let simScale = Float(Self.simBase) / Float(shortSide)
        let dyeW = max(1, Int((Float(width) * dyeScale).rounded()))
        let dyeH = max(1, Int((Float(height) * dyeScale).rounded()))
        let simW = max(1, Int((Float(width) * simScale).rounded()))
        let simH = max(1, Int((Float(height) * simScale).rounded()))
        dyeSize = SIMD2(Int32(dyeW), Int32(dyeH))
        simSize = SIMD2(Int32(simW), Int32(simH))

        velocity = makeDouble(width: simW, height: simH, format: .rg16Float)
        pressure = makeDouble(width: simW, height: simH, format: .r16Float)
        divergence = makeTexture(width: simW, height: simH, format: .r16Float)
        curl = makeTexture(width: simW, height: simH, format: .r16Float)
        ink = makeDouble(width: dyeW, height: dyeH, format: .rgba16Float)
        fixed = makeDouble(width: dyeW, height: dyeH, format: .rgba16Float)
        wet = makeDouble(width: dyeW, height: dyeH, format: .r16Float)
        guard velocity != nil, pressure != nil, divergence != nil, curl != nil,
              ink != nil, fixed != nil, wet != nil else { return false }

        guard let buffer = try? PixelBufferUtils.makePixelBuffer(format: FrameFormat(id: "metal-ink-layer", width: width, height: height)) else {
            return false
        }
        outputBuffer = buffer
        outputTexture = makeTexture(from: buffer, width: width, height: height)
        return outputTexture != nil
    }

    private func makeDouble(width: Int, height: Int, format: MTLPixelFormat) -> DoubleTexture? {
        guard let a = makeTexture(width: width, height: height, format: format),
              let b = makeTexture(width: width, height: height, format: format) else { return nil }
        return DoubleTexture(read: a, write: b)
    }

    private func makeTexture(width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return device.makeTexture(descriptor: descriptor)
    }

    private func makeTexture(from pixelBuffer: CVPixelBuffer, width: Int, height: Int) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
        ) == kCVReturnSuccess, let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }
        return texture
    }

    private func clearAll(_ commandBuffer: MTLCommandBuffer) {
        ([velocity?.read, velocity?.write, pressure?.read, pressure?.write, ink?.read, ink?.write, fixed?.read, fixed?.write, wet?.read, wet?.write, divergence, curl] as [MTLTexture?])
            .compactMap { $0 }
            .forEach { encodeClear($0, commandBuffer: commandBuffer) }
    }

    private func replay(paths: [InkEditorPath], settings: ProcessingSettings, commandBuffer: MTLCommandBuffer) {
        guard !paths.isEmpty else { return }
        brushLift = 0   // replayed/committed wash is additive, not destructive
        for (index, path) in paths.enumerated() {
            replay(path: path, index: index, settings: settings, commandBuffer: commandBuffer)
        }
        for _ in 0..<6 {
            step(settings: settings, dt: 1.0 / 60.0, commandBuffer: commandBuffer)
        }
    }

    private func reconcileCommittedPaths(_ paths: [InkEditorPath], settings: ProcessingSettings, commandBuffer: MTLCommandBuffer) {
        guard paths != replayedPaths else { return }
        if replayedPaths.isEmpty || isAppendOnly(previous: replayedPaths, next: paths) {
            let appended = paths.dropFirst(replayedPaths.count)
            for path in appended where path.points.count > 1 {
                // Skip strokes already drawn live (baked) — replaying would
                // double the mark. Replay only programmatic / loaded paths.
                if bakedLiveIDs.contains(path.id) { continue }
                replay(path: path, index: replayedPaths.count, settings: settings, commandBuffer: commandBuffer)
                activeFramesRemaining = max(activeFramesRemaining, 90)
            }
            replayedPaths = paths
            return
        }
        clearAll(commandBuffer)
        bakedLiveIDs = []
        replay(paths: paths, settings: settings, commandBuffer: commandBuffer)
        replayedPaths = paths
        livePointerStates = [:]
        activeFramesRemaining = paths.isEmpty ? 0 : 180
    }

    private func isAppendOnly(previous: [InkEditorPath], next: [InkEditorPath]) -> Bool {
        guard next.count >= previous.count else { return false }
        for (a, b) in zip(previous, next) where a != b {
            return false
        }
        return true
    }

    private func replay(path: InkEditorPath, index: Int, settings: ProcessingSettings, commandBuffer: MTLCommandBuffer) {
        guard let ink, let wet, let velocity else { return }
        let mode = path.brushMode ?? settings.landmarks.inkBrushMode ?? .pen
        let kind = path.inkKind ?? settings.landmarks.inkKind ?? .black
        let size = normalizedSize(path.width ?? settings.landmarks.inkWidth)
        let flow = clamp01(path.flow ?? settings.landmarks.inkFlow)
        let brushInk = clamp01(path.brushInk ?? settings.landmarks.inkBrushInk ?? 0)
        let color = path.color ?? settings.landmarks.inkColor
        let points = smoothed(points: path.points, fit: settings.landmarks.inkCurveFit)
            .map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        guard points.count > 1 else { return }

        var previous = points[0]
        var brushStepCounter = 0
        for point in points.dropFirst() {
            let delta = point - previous
            let dist = simd_length(delta)
            if dist <= 0.0001 {
                previous = point
                continue
            }
            let pressure: Float = 0.45
            let speed = min(dist * 60.0, 3.0)
            if mode == .pen {
                let radius = penRadius(pressure: pressure, speed: speed, size: size)
                let density = (0.55 + 1.05 * pressure) * min(max(1.25 - speed * 0.45, 0.6), 1.25)
                let steps = min(max(1, Int(ceil(dist / max(radius * 0.6, 0.0008)))), 80)
                for i in 1...steps {
                    let t = Float(i) / Float(steps)
                    let p = previous + delta * t
                    splat(texture: ink.read, point: p, radius: radius, color: inkColor(kind: kind, base: color, density: density), blend: .add, commandBuffer: commandBuffer)
                    if i % 2 == 0 || steps == 1 {
                        splat(texture: wet.read, point: p, radius: radius * 2.8, color: SIMD4<Float>(0.16, 0, 0, 0), blend: .max, commandBuffer: commandBuffer)
                    }
                }
            } else {
                let radius = brushRadius(pressure: pressure, speed: speed, size: size)
                brushNow = SIMD3<Float>(point.x, point.y, radius)
                let wetAmount = 0.5 + 0.5 * pressure
                let force = 15 + flow * 95
                var vel = delta * 60.0 * force
                let vm = simd_length(vel)
                if vm > 240 { vel *= 240 / vm }
                let loadedDensity = brushInk * 0.10 * (0.4 + 0.6 * pressure)
                let steps = min(max(1, Int(ceil(dist / max(radius * 0.7, 0.001)))), 24)
                for i in 1...steps {
                    let t = Float(i) / Float(steps)
                    let p = previous + delta * t
                    splat(texture: wet.read, point: p, radius: radius, color: SIMD4<Float>(wetAmount, 0, 0, 0), blend: .max, commandBuffer: commandBuffer)
                    splat(texture: velocity.read, point: p, radius: radius * 1.15, color: SIMD4<Float>(vel.x, vel.y, 0, 0), blend: .add, commandBuffer: commandBuffer)
                    if loadedDensity > 0 {
                        splat(texture: ink.read, point: p, radius: radius * 0.8, color: inkColor(kind: kind, base: color, density: loadedDensity), blend: .add, commandBuffer: commandBuffer)
                    }
                }
                brushStepCounter += 1
                if brushStepCounter.isMultiple(of: 8) {
                    step(settings: settings, dt: 1.0 / 60.0, commandBuffer: commandBuffer)
                }
            }
            previous = point
        }
        brushNow = SIMD3(0, 0, 0)
    }

    @discardableResult
    private func updateLiveStroke(_ sample: InkLiveStrokeSample?, points: [CGPoint], settings: ProcessingSettings, dt: Float, commandBuffer: MTLCommandBuffer) -> Bool {
        guard let sample else {
            livePointerStates = [:]
            brushNow = SIMD3(0, 0, 0)
            brushLift = 0
            return false
        }
        guard let ink, let wet, let velocity else { return false }
        // Mark this stroke baked-live as soon as it starts drawing (many frames
        // before it commits to inkPaths), so the committed path is never
        // replayed on top — race-free, unlike relying on the end signal.
        bakedLiveIDs.insert(sample.id)
        let mode = sample.brushMode
        let kind = sample.inkKind
        let size = normalizedSize(sample.width)
        let flow = clamp01(sample.flow)
        let brushInk = clamp01(sample.brushInk)
        let color = sample.color

        // All cursor points captured since the last frame (dense), so fast
        // drags don't get connected by long straight segments. If none arrived
        // (cursor held still), settle/stir toward the last point.
        // Immediate wash is destructive: it re-mobilizes dried ink under the
        // brush so the velocity field pushes it. Pen and additive (committed)
        // wash leave it at 0. Strength (slider) + charge (hold-before-drag)
        // scale how much lifts per frame and how hard it's pushed — so a normal
        // drag moves ink without rubbing, and a charged drag hits hard.
        let destructiveWash = mode == .brush && sample.destructive
        let smear = clamp01(settings.landmarks.inkSmearStrength)
        let chargeMul: Float = 1 + clamp01(sample.charge) * 2
        brushLift = destructiveWash ? min(1.0, (0.45 + 0.55 * smear) * chargeMul) : 0
        let forceBoost: Float = destructiveWash ? (1 + smear * 1.5) * chargeMul : 1
        let velCap: Float = destructiveWash ? 240 * chargeMul : 240

        let rawPoints = points.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let fallback = SIMD2<Float>(Float(sample.point.x), Float(sample.point.y))

        var state = livePointerStates[sample.id] ?? LivePointerState(
            bx: rawPoints.first?.x ?? fallback.x,
            by: rawPoints.first?.y ?? fallback.y,
            speed: 0,
            simPressure: 0.35,
            stirPhase: Float(sample.id.hashValue & 0x3ff) * 0.0061359
        )

        let smoothing = clamp01(max(settings.landmarks.inkSmoothing, sample.smoothBoost ? 0.85 : 0))
        let followRate: Float = 6 + (1 - smoothing) * 32
        let force = (15 + flow * 95) * forceBoost

        // WASH (brush) is a fluid IMPULSE, not a geometric mark. Drive it from the
        // RAW cursor samples this frame (~a handful), injecting the true local
        // instantaneous velocity (delta/subDt · force) at each — this is the
        // original accumulative smear: many small directional impulses with local
        // speed variation per frame. (Two failure modes to avoid: the maxGap
        // subdivision the pen uses explodes the substep count and over-drives the
        // field into vorticity turbulence; collapsing to one frame-averaged
        // impulse per frame makes the smear bland. Raw samples are the sweet spot.)
        // dt is real elapsed time, so velocity magnitude (≈ speed·force) is
        // frame-rate independent.
        if mode == .brush {
            var washTargets = rawPoints
            if washTargets.isEmpty { washTargets = [fallback] }
            let subDtW = dt / Float(washTargets.count)
            let kW = 1 - exp(-subDtW * followRate)
            for target in washTargets {
                let previous = SIMD2<Float>(state.bx, state.by)
                state.bx += (target.x - state.bx) * kW
                state.by += (target.y - state.by) * kW
                let current = SIMD2<Float>(state.bx, state.by)
                let delta = current - previous
                let dist = simd_length(delta)
                let inst = dist / max(subDtW, 0.0001)
                state.speed += (inst - state.speed) * (1 - exp(-subDtW * 10))
                let targetP = min(max(1.18 - state.speed * 0.95, 0.12), 1.0)
                state.simPressure += (targetP - state.simPressure) * (1 - exp(-subDtW * 6))
                let pressure = state.simPressure
                let speed = state.speed
                let radius = brushRadius(pressure: pressure, speed: speed, size: size)
                brushNow = SIMD3<Float>(current.x, current.y, radius)
                let wetAmount = 0.5 + 0.5 * pressure
                let loadedDensity = brushInk * 0.10 * (0.4 + 0.6 * pressure)
                var vel = delta / max(subDtW, 0.0001) * force
                let vm = simd_length(vel)
                if vm > velCap { vel *= velCap / vm }
                if dist < radius * 0.25 {
                    splat(texture: wet.read, point: current, radius: radius, color: SIMD4<Float>(wetAmount, 0, 0, 0), blend: .max, commandBuffer: commandBuffer)
                    state.stirPhase += 2.399963
                    let stir = (6 + 26 * flow) * pressure
                    let jitter = SIMD2<Float>(cos(state.stirPhase) * stir, sin(state.stirPhase) * stir)
                    splat(texture: velocity.read, point: current, radius: radius * 0.9, color: SIMD4<Float>(jitter.x, jitter.y, 0, 0), blend: .add, commandBuffer: commandBuffer)
                    if loadedDensity > 0 {
                        splat(texture: ink.read, point: current, radius: radius * 0.8, color: inkColor(kind: kind, base: color, density: loadedDensity * subDtW * 5), blend: .add, commandBuffer: commandBuffer)
                    }
                } else {
                    let spacing = radius * 0.7
                    let steps = min(max(1, Int(ceil(dist / max(spacing, 0.001)))), 12)
                    for i in 1...steps {
                        let t = Float(i) / Float(steps)
                        let p = previous + delta * t
                        splat(texture: wet.read, point: p, radius: radius, color: SIMD4<Float>(wetAmount, 0, 0, 0), blend: .max, commandBuffer: commandBuffer)
                        splat(texture: velocity.read, point: p, radius: radius * 1.15, color: SIMD4<Float>(vel.x, vel.y, 0, 0), blend: .add, commandBuffer: commandBuffer)
                        if loadedDensity > 0 {
                            splat(texture: ink.read, point: p, radius: radius * 0.8, color: inkColor(kind: kind, base: color, density: loadedDensity), blend: .add, commandBuffer: commandBuffer)
                        }
                    }
                }
            }
            livePointerStates = [sample.id: state]
            return true
        }

        // --- PEN ---
        // Build the trajectory to follow this frame: start at the brush's current
        // (smoothed) position, then pass through every cursor sample. Seeding from
        // the previous position is what keeps strokes smooth when frames are slow
        // or irregular (over a session, or right after tab-in): a large gap
        // between where the brush is and the new samples gets densely subdivided
        // and smoothly followed, instead of collapsing to one long straight chord
        // → polygonal, "choppy" strokes.
        var anchors: [SIMD2<Float>] = [SIMD2<Float>(state.bx, state.by)]
        anchors.append(contentsOf: rawPoints.isEmpty ? [fallback] : rawPoints)

        let maxGap: Float = 0.01
        var targets: [SIMD2<Float>] = []
        targets.reserveCapacity(anchors.count * 2)
        for i in 1..<anchors.count {
            let a = anchors[i - 1], b = anchors[i]
            let seg = simd_length(b - a)
            let n = max(1, min(64, Int(ceil(seg / maxGap))))
            for j in 1...n { targets.append(a + (b - a) * (Float(j) / Float(n))) }
        }
        if targets.isEmpty { targets = [anchors[0]] }

        let subDt = dt / Float(targets.count)
        let k = 1 - exp(-subDt * followRate)

        // Width / pressure are updated PER SUBSTEP along the (densely subdivided,
        // seeded-from-the-brush) smoothed trajectory. Because the substeps span the
        // whole frame's motion, per-substep speed equals the true cursor speed
        // regardless of substep count or frame rate — and updating per substep
        // keeps the stroke width CONTINUOUS. (Computing it once per frame makes the
        // width step in visible lumps where the value jumps between frames.)
        let speedAlpha = 1 - exp(-subDt * 10)
        let pressureAlpha = 1 - exp(-subDt * 6)
        brushNow = SIMD3(0, 0, 0)
        var prevInkRadius: Float = -1

        for target in targets {
            let previous = SIMD2<Float>(state.bx, state.by)
            state.bx += (target.x - state.bx) * k
            state.by += (target.y - state.by) * k
            let current = SIMD2<Float>(state.bx, state.by)
            let delta = current - previous
            let dist = simd_length(delta)

            let inst = dist / max(subDt, 0.0001)
            state.speed += (inst - state.speed) * speedAlpha
            let targetPressure = min(max(1.18 - state.speed * 0.95, 0.12), 1.0)
            state.simPressure += (targetPressure - state.simPressure) * pressureAlpha
            let pressure = state.simPressure
            let speed = state.speed
            let radius = penRadius(pressure: pressure, speed: speed, size: size)

            let penDensity = (0.55 + 1.05 * pressure) * min(max(1.25 - speed * 0.45, 0.6), 1.25)
            // Lay the stroke as a ribbon: one variable-width capsule per centerline
            // step, max-blended so the union is smooth (no bead/"salami" from
            // overlapping additive discs). The first step has no prior radius.
            let rPrev = prevInkRadius < 0 ? radius : prevInkRadius
            splatCapsule(texture: ink.read, a: previous, b: current, ra: rPrev, rb: radius, color: inkColor(kind: kind, base: color, density: penDensity), blend: .max, commandBuffer: commandBuffer)
            splatCapsule(texture: wet.read, a: previous, b: current, ra: rPrev * 2.8, rb: radius * 2.8, color: SIMD4<Float>(0.16, 0, 0, 0), blend: .max, commandBuffer: commandBuffer)
            prevInkRadius = radius
        }

        livePointerStates = [sample.id: state]
        return true
    }

    private enum BlendMode: UInt32 { case add = 0, max = 1 }

    private func splat(texture: MTLTexture, point: SIMD2<Float>, radius: Float, color: SIMD4<Float>, blend: BlendMode, commandBuffer: MTLCommandBuffer) {
        let r = max(radius, 0.0005)
        let extent = Int(ceil(r * 4.5 * Float(texture.height))) + 2
        let cx = Int(round(point.x * Float(texture.width)))
        let cy = Int(round(point.y * Float(texture.height)))
        let ox = max(cx - extent, 0)
        let oy = max(cy - extent, 0)
        let maxX = min(cx + extent, texture.width - 1)
        let maxY = min(cy + extent, texture.height - 1)
        guard maxX >= ox, maxY >= oy else { return }
        var params = SplatParams(
            targetSize: SIMD2(Float(texture.width), Float(texture.height)),
            origin: SIMD2(UInt32(ox), UInt32(oy)),
            aspect: aspect,
            point: point,
            radiusSq: r * r,
            blendMode: blend.rawValue,
            color: color
        )
        encode(splatPSO, textures: [texture], bytes: &params, length: MemoryLayout<SplatParams>.stride,
               width: maxX - ox + 1, height: maxY - oy + 1, commandBuffer: commandBuffer)
    }

    /// Stamp a variable-width rounded segment (capsule). One per centerline step
    /// + max blend yields a smooth ribbon (no beading), unlike overlapping discs.
    private func splatCapsule(texture: MTLTexture, a: SIMD2<Float>, b: SIMD2<Float>, ra: Float, rb: Float, color: SIMD4<Float>, blend: BlendMode, commandBuffer: MTLCommandBuffer) {
        let w = texture.width, h = texture.height
        let rA = max(ra, 0.0005), rB = max(rb, 0.0005)
        // Half-widths are in y-uv units (the splat metric), so a pixel margin of
        // r * height bounds the swept region on both axes.
        let ext = Int(ceil(max(rA, rB) * 1.4 * Float(h))) + 3
        let ox = max(Int(floor(Double(min(a.x, b.x)) * Double(w))) - ext, 0)
        let oy = max(Int(floor(Double(min(a.y, b.y)) * Double(h))) - ext, 0)
        let mx = min(Int(ceil(Double(max(a.x, b.x)) * Double(w))) + ext, w - 1)
        let my = min(Int(ceil(Double(max(a.y, b.y)) * Double(h))) + ext, h - 1)
        guard mx >= ox, my >= oy else { return }
        var params = CapsuleParams(
            targetSize: SIMD2(Float(w), Float(h)),
            origin: SIMD2(UInt32(ox), UInt32(oy)),
            aspect: aspect,
            edge: 1.4 / Float(h),
            a: a, b: b, ra: rA, rb: rB,
            blendMode: blend.rawValue,
            color: color
        )
        encode(capsulePSO, textures: [texture], bytes: &params, length: MemoryLayout<CapsuleParams>.stride,
               width: mx - ox + 1, height: my - oy + 1, commandBuffer: commandBuffer)
    }

    private func step(settings: ProcessingSettings, dt: Float, commandBuffer: MTLCommandBuffer) {
        guard let velocity, let pressure, let divergence, let curl, let wet, let ink, let fixed else { return }
        let l = settings.landmarks
        let flow = clamp01(l.inkFlow)
        let dry = clamp01(l.inkDry)
        let bleed = clamp01(l.inkBleed)
        let washStrength = clamp01(l.inkWashStrength)
        let fixing = fixTimer > 0
        if fixing { fixTimer = max(0, fixTimer - dt) }
        let simTexel = SIMD2<Float>(1 / Float(velocity.read.width), 1 / Float(velocity.read.height))
        let dyeTexel = SIMD2<Float>(1 / Float(ink.read.width), 1 / Float(ink.read.height))
        var advVel = AdvectVelocityParams(
            texel: simTexel,
            dt: dt,
            dissipation: exp(-dt * (3.0 - flow * 2.4 + dry * 5.0)) * (fixing ? exp(-dt * 7) : 1)
        )
        encode(advectVelocityPSO, textures: [velocity.read, wet.read, velocity.write], bytes: &advVel, length: MemoryLayout<AdvectVelocityParams>.stride, grid: velocity.write, commandBuffer: commandBuffer)
        velocity.swap()

        encode(curlPSO, textures: [velocity.read, curl], bytes: &advVel, length: MemoryLayout<AdvectVelocityParams>.stride, grid: curl, commandBuffer: commandBuffer)

        var vort = VorticityParams(texel: simTexel, curlAmount: 4 + flow * 22, dt: dt)
        encode(vorticityPSO, textures: [velocity.read, curl, velocity.write], bytes: &vort, length: MemoryLayout<VorticityParams>.stride, grid: velocity.write, commandBuffer: commandBuffer)
        velocity.swap()

        encode(divergencePSO, textures: [velocity.read, divergence], bytes: &advVel, length: MemoryLayout<AdvectVelocityParams>.stride, grid: divergence, commandBuffer: commandBuffer)

        var copy = CopyParams(value: 0.8)
        encode(copyPSO, textures: [pressure.read, pressure.write], bytes: &copy, length: MemoryLayout<CopyParams>.stride, grid: pressure.write, commandBuffer: commandBuffer)
        pressure.swap()

        for _ in 0..<Self.pressureIterations {
            encode(pressurePSO, textures: [pressure.read, divergence, pressure.write], bytes: &advVel, length: MemoryLayout<AdvectVelocityParams>.stride, grid: pressure.write, commandBuffer: commandBuffer)
            pressure.swap()
        }

        encode(gradientSubtractPSO, textures: [pressure.read, velocity.read, velocity.write], bytes: &advVel, length: MemoryLayout<AdvectVelocityParams>.stride, grid: velocity.write, commandBuffer: commandBuffer)
        velocity.swap()

        let dryTau: Float = fixing ? 0.22 : 0.12 + pow(1 - dry, 2.2) * 26
        let spread: Float = 0.18 * (1 - dry * 0.78)
        var advWet = AdvectWetParams(velTexel: simTexel, wetTexel: dyeTexel, dt: dt, decay: exp(-dt / dryTau), spread: spread)
        encode(advectWetPSO, textures: [velocity.read, wet.read, wet.write], bytes: &advWet, length: MemoryLayout<AdvectWetParams>.stride, grid: wet.write, commandBuffer: commandBuffer)
        wet.swap()

        let colorAmount = clamp01(l.inkColorSeparation ?? 0.5)
        let chroma = SIMD3<Float>(1.0 + 0.85 * colorAmount, 1.0 + 0.15 * colorAmount, max(0.25, 1.0 - 0.65 * colorAmount))
        var advInk = AdvectInkParams(
            velTexel: simTexel,
            inkTexel: dyeTexel,
            dt: dt,
            bleed: bleed * washStrength,
            aspect: aspect,
            chroma: SIMD4(chroma.x, chroma.y, chroma.z, 0),
            brush: SIMD4(brushNow.x, brushNow.y, brushNow.z, 0)
        )
        encode(advectInkPSO, textures: [velocity.read, ink.read, wet.read, ink.write], bytes: &advInk, length: MemoryLayout<AdvectInkParams>.stride, grid: ink.write, commandBuffer: commandBuffer)
        ink.swap()

        let settle: Float = fixing ? 1 - exp(-dt * 5) : 0
        var exch = ExchangeParams(settle: settle, dt: dt, aspect: aspect, mode: 0, brush: SIMD4(brushNow.x, brushNow.y, brushNow.z, brushLift))
        encode(exchangePSO, textures: [fixed.read, ink.read, wet.read, fixed.write], bytes: &exch, length: MemoryLayout<ExchangeParams>.stride, grid: fixed.write, commandBuffer: commandBuffer)
        exch.mode = 1
        encode(exchangePSO, textures: [fixed.read, ink.read, wet.read, ink.write], bytes: &exch, length: MemoryLayout<ExchangeParams>.stride, grid: ink.write, commandBuffer: commandBuffer)
        fixed.swap()
        ink.swap()
    }

    private func render(settings: ProcessingSettings, commandBuffer: MTLCommandBuffer) {
        guard let ink, let fixed, let wet, let outputTexture else { return }
        let l = settings.landmarks
        let texel = SIMD2<Float>(1 / Float(ink.read.width), 1 / Float(ink.read.height))
        var params = DisplayParams(
            texel: texel,
            res: SIMD2(Float(outputTexture.width), Float(outputTexture.height)),
            inkStrength: 1.9,
            edge: 1.35,
            grain: max(0, clamp01(l.inkPaperGrain)),
            whiteTint: clamp01(l.inkColorSeparation ?? 0.5) * 0.35,
            opacity: clamp01(l.inkOpacity),
            paperOn: l.inkPaperEnabled ? 1 : 0
        )
        encode(displayPSO, textures: [ink.read, fixed.read, wet.read, outputTexture], bytes: &params, length: MemoryLayout<DisplayParams>.stride, grid: outputTexture, commandBuffer: commandBuffer)
    }

    private func encodeClear(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
        encode(clearPSO, textures: [texture], bytes: nil, length: 0, grid: texture, commandBuffer: commandBuffer)
    }

    private func encode(_ pso: MTLComputePipelineState, textures: [MTLTexture], bytes: UnsafeRawPointer?, length: Int, grid: MTLTexture, commandBuffer: MTLCommandBuffer) {
        encode(pso, textures: textures, bytes: bytes, length: length, width: grid.width, height: grid.height, commandBuffer: commandBuffer)
    }

    private func encode(_ pso: MTLComputePipelineState, textures: [MTLTexture], bytes: UnsafeRawPointer?, length: Int, width: Int, height: Int, commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pso)
        for (index, texture) in textures.enumerated() {
            encoder.setTexture(texture, index: index)
        }
        if let bytes, length > 0 {
            encoder.setBytes(bytes, length: length, index: 0)
        }
        let tg = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1), threadsPerThreadgroup: tg)
        encoder.endEncoding()
    }

    private func smoothed(points: [CGPoint], fit: CurveFit) -> [CGPoint] {
        guard points.count > 2 else { return points }
        return DrawingSupport.curvePoints(points, fit: fit, samplesPerSegment: 6)
    }

    private var aspect: Float {
        guard outputSize.y > 0 else { return 1 }
        return Float(outputSize.x) / Float(outputSize.y)
    }

    private func normalizedSize(_ value: Float) -> Float {
        if value <= 1 { return clamp01(value) }
        return clamp01((value - 0.5) / 27.5)
    }

    private func sizeMult(_ size: Float) -> Float {
        pow(3, (clamp01(size) - 0.5) * 2)
    }

    private func penRadius(pressure: Float, speed: Float, size: Float) -> Float {
        (0.0016 + 0.0042 * pressure) * min(max(1.12 - speed * 0.3, 0.55), 1.12) * sizeMult(size)
    }

    private func brushRadius(pressure: Float, speed: Float, size: Float) -> Float {
        (0.014 + 0.060 * pressure) * (1 + min(speed, 2.5) * 0.28) * sizeMult(size)
    }

    private func inkColor(kind: InkKind, base: RGBAColor, density: Float) -> SIMD4<Float> {
        if kind == .white {
            return SIMD4<Float>(0, 0, 0, density)
        }
        let abs = absorption(for: base)
        return SIMD4<Float>(abs.x * density, abs.y * density, abs.z * density, 0)
    }

    private func absorption(for color: RGBAColor) -> SIMD3<Float> {
        let rgb = SIMD3<Float>(color.red, color.green, color.blue)
        if max(rgb.x, max(rgb.y, rgb.z)) < 0.16 { return Self.inkAbs }
        let clamped = SIMD3<Float>(max(rgb.x, 0.02), max(rgb.y, 0.02), max(rgb.z, 0.02))
        let a = SIMD3<Float>(-log(clamped.x), -log(clamped.y), -log(clamped.z))
        let m = max(max(a.x, a.y), max(a.z, 0.25))
        return a / m
    }

    private func clamp01(_ v: Float) -> Float {
        min(1, max(0, v))
    }
}

#if DEBUG
extension MetalInkEngine {
    static func runSelfCheck() {
        let result = selfCheck()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sketchcam-metal-ink-selftest.txt")
        try? (result + "\n").write(to: url, atomically: true, encoding: .utf8)
        print("SketchCamMetalInk \(result)")
    }

    private static func selfCheck() -> String {
        guard let engine = MetalInkEngine() else { return "ink-selftest: init FAILED" }
        var settings = ProcessingSettings()
        settings.landmarks.inkEnabled = true
        settings.landmarks.inkPaperEnabled = true
        settings.landmarks.inkWidth = 0.75
        settings.landmarks.inkFlow = 0.8
        settings.landmarks.inkBleed = 0.8
        settings.landmarks.inkDry = 0.25
        settings.landmarks.inkColorSeparation = 0.8
        settings.landmarks.inkBrushInk = 0.25
        settings.landmarks.inkPaths = [
            InkEditorPath(points: [CGPoint(x: 0.12, y: 0.50), CGPoint(x: 0.88, y: 0.50)], brushMode: .pen, inkKind: .black, width: 0.75, flow: 1.0),
            InkEditorPath(points: [CGPoint(x: 0.46, y: 0.34), CGPoint(x: 0.54, y: 0.66)], brushMode: .brush, inkKind: .black, width: 0.75, flow: 0.9, brushInk: 0.25)
        ]
        for frame in 0..<10 {
            _ = engine.layer(settings: settings, live: nil, livePoints: [], endedLiveID: nil, outputSize: CGSize(width: 192, height: 128), frameIndex: frame)
        }
        guard let early = snapshot(engine.outputBuffer) else { return "ink-selftest: early snapshot FAILED" }
        for frame in 10..<70 {
            _ = engine.layer(settings: settings, live: nil, livePoints: [], endedLiveID: nil, outputSize: CGSize(width: 192, height: 128), frameIndex: frame)
        }
        guard let wetMoved = snapshot(engine.outputBuffer) else { return "ink-selftest: wet snapshot FAILED" }
        settings.landmarks.inkFixRevision = 1
        for frame in 70..<130 {
            _ = engine.layer(settings: settings, live: nil, livePoints: [], endedLiveID: nil, outputSize: CGSize(width: 192, height: 128), frameIndex: frame)
        }
        guard let fixed = snapshot(engine.outputBuffer) else { return "ink-selftest: fixed snapshot FAILED" }
        let blackCenter = fixed.centerLum
        settings.landmarks.inkPaths.append(InkEditorPath(
            points: [CGPoint(x: 0.22, y: 0.50), CGPoint(x: 0.78, y: 0.50)],
            brushMode: .pen,
            inkKind: .white,
            width: 0.9,
            flow: 1.0
        ))
        settings.landmarks.inkFixRevision = 2
        for frame in 130..<180 {
            _ = engine.layer(settings: settings, live: nil, livePoints: [], endedLiveID: nil, outputSize: CGSize(width: 192, height: 128), frameIndex: frame)
        }
        guard let white = snapshot(engine.outputBuffer) else { return "ink-selftest: white snapshot FAILED" }

        let nonblank = fixed.darkPixels > 16 && fixed.minLum < fixed.maxLum - 25
        let movement = early.checksum != wetMoved.checksum
        let fixOK = fixed.darkPixels > 16 && fixed.alphaMin > 200
        let whiteOK = white.centerLum > blackCenter + 18 || white.darkPixels < fixed.darkPixels
        let pass = nonblank && movement && fixOK && whiteOK
        return "ink-selftest: \(pass ? "PASS" : "FAIL") nonblank=\(nonblank) movement=\(movement) fix=\(fixOK) white=\(whiteOK) early=\(early.summary) wet=\(wetMoved.summary) fixed=\(fixed.summary) whiteFrame=\(white.summary)"
    }

    private struct Snapshot {
        var minLum: Int
        var maxLum: Int
        var centerLum: Int
        var darkPixels: Int
        var alphaMin: Int
        var checksum: UInt64

        var summary: String {
            "min=\(minLum) max=\(maxLum) center=\(centerLum) dark=\(darkPixels) alphaMin=\(alphaMin) hash=\(checksum)"
        }
    }

    private static func snapshot(_ buffer: CVPixelBuffer?) -> Snapshot? {
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let data = base.assumingMemoryBound(to: UInt8.self)
        var minLum = Int.max
        var maxLum = 0
        var darkPixels = 0
        var alphaMin = 255
        var checksum: UInt64 = 14_695_981_039_346_656_037
        var centerLum = 0
        for y in 0..<height {
            for x in 0..<width {
                let o = y * rowBytes + x * 4
                let b = Int(data[o])
                let g = Int(data[o + 1])
                let r = Int(data[o + 2])
                let a = Int(data[o + 3])
                let lum = r + g + b
                minLum = min(minLum, lum)
                maxLum = max(maxLum, lum)
                alphaMin = min(alphaMin, a)
                if lum < 620 { darkPixels += 1 }
                if x == width / 2, y == height / 2 { centerLum = lum }
                checksum = (checksum ^ UInt64(lum + a * 257 + x * 31 + y * 17)) &* 1_099_511_628_211
            }
        }
        return Snapshot(minLum: minLum, maxLum: maxLum, centerLum: centerLum, darkPixels: darkPixels, alphaMin: alphaMin, checksum: checksum)
    }
}
#endif
