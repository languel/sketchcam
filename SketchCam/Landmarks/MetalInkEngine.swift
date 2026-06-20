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
        var paperOpacity: Float
        var paper: ResolvedPaperConfig
        var opacity: Float
        var colorSep: Float
        var washTint: SIMD4<Float>
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
        var control: SIMD4<Float>
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
        var control: SIMD4<Float>
    }

    private struct CopyParams { var value: Float }
    private struct WetInjectParams {
        var amount: Float
        var threshold: Float
        var invert: UInt32
        var fullCanvas: UInt32
    }
    private struct AdvectVelocityParams { var texel: SIMD2<Float>; var dt: Float; var dissipation: Float; var control: SIMD4<Float> }
    private struct ControlForceParams { var dt: Float; var force: Float; var maximumForce: Float; var pad0: Float = 0 }
    private struct VorticityParams { var texel: SIMD2<Float>; var curlAmount: Float; var dt: Float }
    private struct AdvectWetParams {
        var velTexel: SIMD2<Float>
        var wetTexel: SIMD2<Float>
        var dt: Float
        var decay: Float
        var spread: Float
        var pad0: Float = 0
        var control: SIMD4<Float>
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
        var control: SIMD4<Float>
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
        var inkFade: Float
        var washTint: SIMD4<Float>
        var grainScaleSeed: SIMD4<Float>
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
    private let injectWetPSO: MTLComputePipelineState
    private let splatPSO: MTLComputePipelineState
    private let capsulePSO: MTLComputePipelineState
    private let accumulatePSO: MTLComputePipelineState
    private let advectVelocityPSO: MTLComputePipelineState
    private let controlForcePSO: MTLComputePipelineState
    private let curlPSO: MTLComputePipelineState
    private let vorticityPSO: MTLComputePipelineState
    private let divergencePSO: MTLComputePipelineState
    private let pressurePSO: MTLComputePipelineState
    private let gradientSubtractPSO: MTLComputePipelineState
    private let advectWetPSO: MTLComputePipelineState
    private let advectInkPSO: MTLComputePipelineState
    private let exchangePSO: MTLComputePipelineState
    private let displayPSO: MTLComputePipelineState
    private let paperRenderer: MetalPaperRenderer

    private var velocity: DoubleTexture?
    private var pressure: DoubleTexture?
    private var ink: DoubleTexture?
    private var fixed: DoubleTexture?
    private var wet: DoubleTexture?
    /// Pigment baked permanent by Fix — displayed but never re-mobilized by the
    /// wash lift, so a fixed drawing can't be washed/displaced.
    private var locked: MTLTexture?
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
    private var lastUnfixRevision = 0
    private var lastWetCanvasRevision = 0
    private var lastDryCanvasRevision = 0
    private var lastRebuildRevision = 0
    private var lastStepTime: CFAbsoluteTime = 0
    private var fixTimer: Float = 0
    private var brushNow = SIMD3<Float>(0, 0, 0)
    /// Destructive lift under the brush (immediate wash re-mobilizes dried ink);
    /// 0 = additive wash. Rides in the exchange brush.w.
    private var brushLift: Float = 0
    private var activeFramesRemaining = 0
    // Clear fade-out: when triggered, the layer fades to transparent over the
    // fade duration, then the textures are wiped (instead of an instant clear).
    private var clearFade: Float = 1
    private var clearFadeActive = false
    private var lastClearFadeRevision = 0
    private var replayedPaths: [InkEditorPath] = []
    private var livePointerStates: [UUID: LivePointerState] = [:]
    /// Strokes whose ink was injected live (already on the canvas); the
    /// committed path with the same id must NOT be replayed (avoids the double
    /// mark). Cleared on full rebuild/replay.
    private var bakedLiveIDs: Set<UUID> = []
    private var lastRenderSig: RenderSignature?
    private var cachedImage: CIImage?
    private var controlFields: ResolvedControlFields = .empty
    private var currentSettings = ProcessingSettings()
    private var zeroScalar: MTLTexture!
    private var zeroVector: MTLTexture!

    private static func makeZeroTexture(device: MTLDevice, format: MTLPixelFormat) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: 1, height: 1, mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared
        return device.makeTexture(descriptor: descriptor)
    }

    private func control(_ input: ControlFieldInputID, fallback: MTLTexture) -> (MTLTexture, Float) {
        guard let resolved = controlFields.field(for: .ink, input: input) else { return (fallback, 1) }
        return (resolved.field.texture, max(0, resolved.strength))
    }

    private func injectMotionWetness(amount: Float, commandBuffer: MTLCommandBuffer) {
        guard let resolved = controlFields.field(for: .ink, input: .wetness) else { return }
        injectWet(
            mask: resolved.field.texture,
            amount: max(0, amount) * max(0, resolved.strength),
            threshold: resolved.threshold,
            invert: resolved.invert,
            commandBuffer: commandBuffer
        )
    }

    private func injectWet(
        mask: MTLTexture?,
        amount: Float,
        threshold: Float = 0,
        invert: Bool = false,
        commandBuffer: MTLCommandBuffer
    ) {
        guard let wet else { return }
        var params = WetInjectParams(
            amount: max(0, amount),
            threshold: min(1, max(0, threshold)),
            invert: invert ? 1 : 0,
            fullCanvas: mask == nil ? 1 : 0
        )
        encode(injectWetPSO, textures: [wet.read, mask ?? zeroScalar], bytes: &params,
               length: MemoryLayout<WetInjectParams>.stride, grid: wet.read,
               commandBuffer: commandBuffer)
    }

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
              let injectWet = pso("ink_inject_wet"),
              let splat = pso("ink_splat"),
              let capsule = pso("ink_splat_capsule"),
              let accumulate = pso("ink_accumulate"),
              let advectVelocity = pso("ink_advect_velocity"),
              let controlForce = pso("ink_add_control_force"),
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
        self.injectWetPSO = injectWet
        self.splatPSO = splat
        self.capsulePSO = capsule
        self.accumulatePSO = accumulate
        self.advectVelocityPSO = advectVelocity
        self.controlForcePSO = controlForce
        self.curlPSO = curl
        self.vorticityPSO = vorticity
        self.divergencePSO = divergence
        self.pressurePSO = pressure
        self.gradientSubtractPSO = gradientSubtract
        self.advectWetPSO = advectWet
        self.advectInkPSO = advectInk
        self.exchangePSO = exchange
        self.displayPSO = display
        guard let paperRenderer = MetalPaperRenderer.shared else { return nil }
        self.paperRenderer = paperRenderer
        self.zeroScalar = Self.makeZeroTexture(device: device, format: .r16Float)
        self.zeroVector = Self.makeZeroTexture(device: device, format: .rg16Float)
    }

    func reset() {
        velocity = nil
        pressure = nil
        ink = nil
        fixed = nil
        wet = nil
        locked = nil
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
        lastUnfixRevision = 0
        lastWetCanvasRevision = 0
        lastDryCanvasRevision = 0
        lastRebuildRevision = 0
        lastStepTime = 0
        fixTimer = 0
        brushNow = SIMD3(0, 0, 0)
        brushLift = 0
        activeFramesRemaining = 0
        clearFade = 1
        clearFadeActive = false
        lastClearFadeRevision = 0
        replayedPaths = []
        livePointerStates = [:]
        bakedLiveIDs = []
        lastRenderSig = nil
        cachedImage = nil
    }

    func layer(settings: ProcessingSettings, live: InkLiveStrokeSample?, livePoints: [CGPoint], endedLiveID: UUID?, outputSize requested: CGSize, frameIndex: Int, controlFields: ResolvedControlFields = .empty) -> CIImage? {
        self.controlFields = controlFields
        self.currentSettings = settings
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
        let unfixRevision = l.inkUnfixRevision ?? 0
        let unfixRequested = unfixRevision != lastUnfixRevision
        let wetCanvasRevision = l.inkWetCanvasRevision ?? 0
        let wetCanvasRequested = wetCanvasRevision != lastWetCanvasRevision
        let dryCanvasRevision = l.inkDryCanvasRevision ?? 0
        let dryCanvasRequested = dryCanvasRevision != lastDryCanvasRevision
        let fadeDuration = max(0.15, l.inkFadeDuration ?? 1.2)
        let clearFadeRev = l.inkClearFadeRevision ?? 0
        let clearFadeRequested = clearFadeRev != lastClearFadeRevision && !needRebuild
        let paperOpacity = l.inkPaperEnabled ? clamp01(l.inkPaperOpacity ?? 1) : 0
        var paperConfig = l.inkPaperConfig ?? .metalDefault
        if l.inkPaperConfig == nil {
            paperConfig.tint = l.inkPaperColor
            paperConfig.grain = l.inkPaperGrain
        }
        let renderSig = RenderSignature(
            paperOpacity: paperOpacity,
            paper: paperConfig.resolved,
            opacity: clamp01(l.inkOpacity),
            colorSep: clamp01(l.inkColorSeparation ?? 0.5),
            washTint: Self.washTint(l.inkWashColor)
        )
        let sigChanged = renderSig != lastRenderSig
        // A routed motion field is an ongoing physical input, just like a held
        // wash brush. Keep simulating while it is enabled; otherwise the normal
        // post-stroke frame budget freezes the canvas even though the source is
        // still moving.
        let motionDriven = l.resolvedInkMotionForce > 0 && controlFields.field(for: .ink, input: .motionVector) != nil
        let motionWetDriven = l.resolvedInkMotionWetness > 0 && controlFields.field(for: .ink, input: .wetness) != nil
        let evolving = motionDriven || motionWetDriven || wetCanvasRequested || unfixRequested || dryCanvasRequested || activeFramesRemaining > 0 || fixTimer > 0 || live != nil || endedLiveID != nil || clearFadeActive || clearFadeRequested

        // Nothing to draw at all → blank. Immediate strokes are not replayable
        // paths, but they leave pigment in the Metal textures; once the sim goes
        // idle, keep serving the last rendered image instead of declaring the
        // layer empty.
        if paperOpacity <= 0.001, replayablePaths.isEmpty, live == nil, !evolving, !needRebuild {
            return cachedImage
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
        } else if pathsChanged && !clearFadeRequested && !clearFadeActive {
            reconcileCommittedPaths(replayablePaths, settings: settings, commandBuffer: commandBuffer)
        }

        // Clear via fade: keep the current textures, fade the layer to
        // transparent over the fade duration, THEN wipe — instead of an instant
        // clear. The UI empties inkPaths at the same time; adopt that as the
        // replayed set so the emptied paths don't trigger an instant reconcile.
        if clearFadeRequested {
            lastClearFadeRevision = clearFadeRev
            clearFadeActive = true
            clearFade = 1
            replayedPaths = replayablePaths
            activeFramesRemaining = max(activeFramesRemaining, Int(fadeDuration * 60) + 30)
        }

        // Dry the just-finished stroke into the fixed paper layer. The settle
        // window length is the Fade duration (longer = the wash keeps drifting
        // and settling longer before it locks in).
        let fadeFrames = Int(fadeDuration * 60) + 30
        if endedLiveID != nil {
            fixTimer = max(fixTimer, fadeDuration)
            activeFramesRemaining = max(activeFramesRemaining, fadeFrames)
        }
        if fixRequested {
            lastFixRevision = fixRevision
            // Lock the current pigment into the permanent layer so the wash can no
            // longer displace it (the wash lift only re-mobilizes `fixed`). New
            // strokes drawn after Fix stay washable.
            if let ink, let fixed, let locked {
                encode(accumulatePSO, textures: [locked, fixed.read], bytes: nil, length: 0, grid: locked, commandBuffer: commandBuffer)
                encode(accumulatePSO, textures: [locked, ink.read], bytes: nil, length: 0, grid: locked, commandBuffer: commandBuffer)
                encodeClear(ink.read, commandBuffer: commandBuffer)
                encodeClear(ink.write, commandBuffer: commandBuffer)
                encodeClear(fixed.read, commandBuffer: commandBuffer)
                encodeClear(fixed.write, commandBuffer: commandBuffer)
            }
            activeFramesRemaining = max(activeFramesRemaining, 2)
        }
        if unfixRequested {
            lastUnfixRevision = unfixRevision
            // Return the permanent pigment to the normal dried layer. Copying
            // through the other ping-pong texture avoids reviving stale data.
            if let fixed, let locked {
                var copy = CopyParams(value: 1)
                encode(copyPSO, textures: [fixed.read, fixed.write], bytes: &copy,
                       length: MemoryLayout<CopyParams>.stride, grid: fixed.write,
                       commandBuffer: commandBuffer)
                encode(accumulatePSO, textures: [fixed.write, locked], bytes: nil,
                       length: 0, grid: fixed.write, commandBuffer: commandBuffer)
                fixed.swap()
                encodeClear(locked, commandBuffer: commandBuffer)
            }
            activeFramesRemaining = max(activeFramesRemaining, 2)
        }
        if wetCanvasRequested {
            lastWetCanvasRevision = wetCanvasRevision
            injectWet(mask: nil, amount: 1, commandBuffer: commandBuffer)
            activeFramesRemaining = max(activeFramesRemaining, 120)
        }
        if dryCanvasRequested {
            lastDryCanvasRevision = dryCanvasRevision
            // Evaporate the canvas immediately and discard fluid momentum, but
            // leave mobile, dried, and fixed pigment exactly where they are.
            ([wet?.read, wet?.write, velocity?.read, velocity?.write,
              pressure?.read, pressure?.write, divergence, curl] as [MTLTexture?])
                .compactMap { $0 }
                .forEach { encodeClear($0, commandBuffer: commandBuffer) }
            fixTimer = 0
            activeFramesRemaining = max(activeFramesRemaining, 2)
        }

        if lastFrameIndex != frameIndex {
            // Real elapsed time, clamped, instead of a fixed 1/60 — so stroke
            // speed/pressure and the fluid step stay correct when the frame rate
            // is irregular (notably right after the app is tabbed out and back).
            let now = CFAbsoluteTimeGetCurrent()
            let dt: Float = lastStepTime > 0 ? Float(min(1.0 / 20.0, max(1.0 / 120.0, now - lastStepTime))) : 1.0 / 60.0
            lastStepTime = now
            if clearFadeActive {
                clearFade = max(0, clearFade - dt / fadeDuration)
                if clearFade <= 0.001 {
                    clearAll(commandBuffer)
                    bakedLiveIDs = []
                    livePointerStates = [:]
                    clearFadeActive = false
                    clearFade = 1
                    activeFramesRemaining = 0
                    fixTimer = 0
                }
            }
            let liveActive = updateLiveStroke(live, points: livePoints, settings: settings, dt: dt, commandBuffer: commandBuffer)
            if liveActive {
                activeFramesRemaining = max(activeFramesRemaining, 120)
            }
            if motionWetDriven {
                injectMotionWetness(amount: l.resolvedInkMotionWetness, commandBuffer: commandBuffer)
            }
            if motionDriven || motionWetDriven || activeFramesRemaining > 0 || liveActive {
                step(settings: settings, dt: dt, commandBuffer: commandBuffer)
                activeFramesRemaining = max(0, activeFramesRemaining - 1)
            }
            lastFrameIndex = frameIndex
        }
        render(settings: settings, paperConfig: paperConfig, commandBuffer: commandBuffer)
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
        locked = makeTexture(width: dyeW, height: dyeH, format: .rgba16Float)
        guard velocity != nil, pressure != nil, divergence != nil, curl != nil,
              ink != nil, fixed != nil, wet != nil, locked != nil else { return false }

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
        ([velocity?.read, velocity?.write, pressure?.read, pressure?.write, ink?.read, ink?.write, fixed?.read, fixed?.write, wet?.read, wet?.write, locked, divergence, curl] as [MTLTexture?])
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
        // A destructive wash re-mobilizes dried (fixed) ink under the brush so
        // the velocity field pushes it and white pigment can cover it to paper.
        // This is on for an immediate wash AND for any WHITE wash (white's job is
        // to clear/cover — without the lift it only partially covers already-dried
        // ink and leaves a gray residue). Colored/black committed wash stays
        // additive (lift 0) so its accumulative smear is unchanged. Strength
        // (slider) + charge (hold-before-drag) scale how much lifts per frame and
        // how hard it's pushed.
        let destructiveWash = mode == .brush && !sample.wetOnly && (sample.destructive || kind == .white)
        let smear = clamp01(settings.landmarks.inkSmearStrength)
        // Every wash re-mobilizes a little dried pigment so smearing EXISTING
        // (dried) strokes is consistent — previously a wash only moved still-wet
        // ink, so the same gesture did a lot on a fresh stroke and nothing on a
        // dried one. Immediate/white wash lifts harder (clears/covers). Strength
        // scales it. (Hold-to-charge removed: it multiplied force up to 3x by
        // pre-drag hold time, which you don't consciously control → wildly
        // variable. Strength + actual movement now drive the smear predictably.)
        brushLift = mode == .brush && !sample.wetOnly ? (destructiveWash ? min(1.0, 0.5 + 0.5 * smear) : 0.05 + 0.65 * smear) : 0
        let forceBoost: Float = mode == .brush ? (0.15 + 1.9 * smear) * (destructiveWash ? 1.4 : 1.0) : 1
        // The Smear slider also sets the movement SENSITIVITY: low Smear needs a
        // deliberate move before it smears (fine control), high Smear smears on
        // the slightest motion (dramatic). One dial spanning subtle → dramatic.
        let smearThreshold: Float = 0.0008 + (1 - smear) * 0.010
        let velCap: Float = 240

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
                let loadedDensity = sample.wetOnly ? 0 : brushInk * 0.10 * (0.4 + 0.6 * pressure)
                var vel = delta / max(subDtW, 0.0001) * force
                let vm = simd_length(vel)
                if vm > velCap { vel *= velCap / vm }
                if sample.wetOnly {
                    // Option-drag is a water-only spray. Connect its samples
                    // into a continuous wet ribbon, but never inject velocity,
                    // pigment, or fixed-pigment lift.
                    let spacing = radius * 0.7
                    let steps = min(max(1, Int(ceil(dist / max(spacing, 0.001)))), 12)
                    for i in 1...steps {
                        let t = Float(i) / Float(steps)
                        splat(texture: wet.read, point: previous + delta * t, radius: radius,
                              color: SIMD4<Float>(wetAmount, 0, 0, 0), blend: .max,
                              commandBuffer: commandBuffer)
                    }
                } else if dist < smearThreshold {
                    // Below the Smear-controlled sensitivity threshold: just
                    // wet/pool, no velocity. (Was radius*0.25 — a velocity-
                    // dependent cutoff that made slow drags fail to smear. Now it's
                    // an absolute distance the Smear slider dials from delicate to
                    // hair-trigger.)
                    splat(texture: wet.read, point: current, radius: radius, color: SIMD4<Float>(wetAmount, 0, 0, 0), blend: .max, commandBuffer: commandBuffer)
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
            color: color,
            control: depositionControl(for: texture)
        )
        let resist = control(.resist, fallback: zeroScalar)
        let live = control(.surfaceModulation, fallback: zeroScalar)
        encode(splatPSO, textures: [texture, resist.0, live.0], bytes: &params, length: MemoryLayout<SplatParams>.stride,
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
            color: color,
            control: depositionControl(for: texture)
        )
        let resist = control(.resist, fallback: zeroScalar)
        let live = control(.surfaceModulation, fallback: zeroScalar)
        encode(capsulePSO, textures: [texture, resist.0, live.0], bytes: &params, length: MemoryLayout<CapsuleParams>.stride,
               width: mx - ox + 1, height: my - oy + 1, commandBuffer: commandBuffer)
    }

    private func depositionControl(for texture: MTLTexture) -> SIMD4<Float> {
        let l = currentSettings.landmarks
        let resistStrength = control(.resist, fallback: zeroScalar).1
        let liveStrength = control(.surfaceModulation, fallback: zeroScalar).1
        let depositsMatter = texture.pixelFormat != .rg16Float
        return SIMD4(l.resolvedInkPaperInfluence * resistStrength,
                     l.resolvedInkLiveSurfaceInfluence * liveStrength,
                     l.resolvedInkLiveResist,
                     depositsMatter ? 1 : 0)
    }

    private func step(settings: ProcessingSettings, dt: Float, commandBuffer: MTLCommandBuffer) {
        guard let velocity, let pressure, let divergence, let curl, let wet, let ink, let fixed else { return }
        let l = settings.landmarks
        let flow = clamp01(l.inkFlow)
        let dry = clamp01(l.inkDry)
        let bleed = clamp01(l.inkBleed)
        let washStrength = clamp01(l.inkWashStrength)
        // Motion-driven painting remains mobile while the external field is
        // active. Preserve the pending settle timer so turning Motion Force off
        // still lets the stroke dry into the paper normally.
        let motionDriven = l.resolvedInkMotionForce > 0 && controlFields.field(for: .ink, input: .motionVector) != nil
        let fixing = fixTimer > 0 && !motionDriven
        if fixing { fixTimer = max(0, fixTimer - dt) }
        // Longer Fade → gentler freeze, so the motion keeps drifting/settling for
        // the whole window instead of snapping still (1.2s is the baseline feel).
        let fadeScale = 1.2 / max(0.3, l.inkFadeDuration ?? 1.2)
        let simTexel = SIMD2<Float>(1 / Float(velocity.read.width), 1 / Float(velocity.read.height))
        let dyeTexel = SIMD2<Float>(1 / Float(ink.read.width), 1 / Float(ink.read.height))
        var advVel = AdvectVelocityParams(
            texel: simTexel,
            dt: dt,
            dissipation: exp(-dt * (3.0 - flow * 2.4 + dry * 5.0)) * (fixing ? exp(-dt * 7 * fadeScale) : 1),
            control: SIMD4(l.resolvedInkPaperInfluence * control(.drag, fallback: zeroScalar).1,
                           l.resolvedInkLiveSurfaceInfluence * control(.surfaceModulation, fallback: zeroScalar).1,
                           l.resolvedInkLiveDrag, 0)
        )
        if l.resolvedInkMotionForce > 0 {
            let motion = control(.motionVector, fallback: zeroVector)
            var force = ControlForceParams(dt: dt, force: l.resolvedInkMotionForce * motion.1, maximumForce: 1)
            encode(controlForcePSO, textures: [velocity.read, motion.0, velocity.write], bytes: &force, length: MemoryLayout<ControlForceParams>.stride, grid: velocity.write, commandBuffer: commandBuffer)
            velocity.swap()
        }
        let drag = control(.drag, fallback: zeroScalar)
        let live = control(.surfaceModulation, fallback: zeroScalar)
        encode(advectVelocityPSO, textures: [velocity.read, wet.read, velocity.write, drag.0, live.0], bytes: &advVel, length: MemoryLayout<AdvectVelocityParams>.stride, grid: velocity.write, commandBuffer: commandBuffer)
        velocity.swap()

        encode(curlPSO, textures: [velocity.read, curl], bytes: &advVel, length: MemoryLayout<AdvectVelocityParams>.stride, grid: curl, commandBuffer: commandBuffer)

        // Lower vorticity confinement so the wash translates ink in the drag
        // DIRECTION rather than curling it into fast swirls/turbulence. Some curl
        // stays for organic character; it's no longer the dominant motion.
        var vort = VorticityParams(texel: simTexel, curlAmount: 2 + flow * 8, dt: dt)
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

        // Longer Fade → larger tau while fixing → wet lingers longer, so the
        // settle/diffusion stretches over the whole fade window.
        let dryTau: Float = fixing ? 0.22 / fadeScale : 0.12 + pow(1 - dry, 2.2) * 26
        let wetnessDecay = max(0, l.inkWetnessDecay ?? 1)
        let spread: Float = 0.18 * (1 - dry * 0.78)
        var advWet = AdvectWetParams(velTexel: simTexel, wetTexel: dyeTexel, dt: dt, decay: exp(-dt / dryTau * wetnessDecay), spread: spread,
                                    control: SIMD4(l.resolvedInkPaperInfluence * control(.absorbency, fallback: zeroScalar).1,
                                                   l.resolvedInkLiveSurfaceInfluence * live.1,
                                                   l.resolvedInkLiveAbsorbency, 0))
        let absorbency = control(.absorbency, fallback: zeroScalar)
        encode(advectWetPSO, textures: [velocity.read, wet.read, wet.write, absorbency.0, live.0], bytes: &advWet, length: MemoryLayout<AdvectWetParams>.stride, grid: wet.write, commandBuffer: commandBuffer)
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
            brush: SIMD4(brushNow.x, brushNow.y, brushNow.z, 0),
            control: advVel.control
        )
        encode(advectInkPSO, textures: [velocity.read, ink.read, wet.read, ink.write, drag.0, live.0], bytes: &advInk, length: MemoryLayout<AdvectInkParams>.stride, grid: ink.write, commandBuffer: commandBuffer)
        ink.swap()

        let settle: Float = fixing ? 1 - exp(-dt * 5 * fadeScale) : 0
        var exch = ExchangeParams(settle: settle, dt: dt, aspect: aspect, mode: 0, brush: SIMD4(brushNow.x, brushNow.y, brushNow.z, brushLift))
        encode(exchangePSO, textures: [fixed.read, ink.read, wet.read, fixed.write], bytes: &exch, length: MemoryLayout<ExchangeParams>.stride, grid: fixed.write, commandBuffer: commandBuffer)
        exch.mode = 1
        encode(exchangePSO, textures: [fixed.read, ink.read, wet.read, ink.write], bytes: &exch, length: MemoryLayout<ExchangeParams>.stride, grid: ink.write, commandBuffer: commandBuffer)
        fixed.swap()
        ink.swap()
    }

    private func render(settings: ProcessingSettings, paperConfig: PaperConfig, commandBuffer: MTLCommandBuffer) {
        guard let ink, let fixed, let wet, let locked, let outputTexture else { return }
        let l = settings.landmarks
        guard let paperTexture = paperRenderer.texture(config: paperConfig, size: CGSize(width: outputTexture.width, height: outputTexture.height), commandBuffer: commandBuffer) else { return }
        let resolvedPaper = paperConfig.resolved
        let texel = SIMD2<Float>(1 / Float(ink.read.width), 1 / Float(ink.read.height))
        var params = DisplayParams(
            texel: texel,
            res: SIMD2(Float(outputTexture.width), Float(outputTexture.height)),
            inkStrength: 1.9,
            edge: 1.35,
            grain: max(0, resolvedPaper.grainStrength),
            whiteTint: clamp01(l.inkColorSeparation ?? 0.5) * 0.35,
            opacity: clamp01(l.inkOpacity),
            paperOn: l.inkPaperEnabled ? clamp01(l.inkPaperOpacity ?? 1) : 0,
            // Clear fade scales the PIGMENT (and wet tint) to 0, leaving the paper
            // fully opaque — so a fade-out doesn't show through to the camera.
            inkFade: clearFadeActive ? clearFade : 1,
            washTint: Self.washTint(l.inkWashColor),
            grainScaleSeed: SIMD4(resolvedPaper.grainScaleX, resolvedPaper.grainScaleY, Float(resolvedPaper.seed), 0)
        )
        encode(displayPSO, textures: [ink.read, fixed.read, wet.read, locked, paperTexture, outputTexture], bytes: &params, length: MemoryLayout<DisplayParams>.stride, grid: outputTexture, commandBuffer: commandBuffer)
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
        // 0…1 is the normal slider range; values >1 (typed into the editable
        // field) make the brush bigger, capped at 1.5 so it stays usable/safe.
        min(1.5, max(0, value))
    }

    private func sizeMult(_ size: Float) -> Float {
        // size 0.5 = 1×; 0 ≈ 0.33×; 1 = 3×; 1.5 ≈ 11× (don't clamp the top so the
        // override past 1 actually enlarges the brush).
        pow(3, (min(1.5, max(0, size)) - 0.5) * 2)
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
        let maxC = max(rgb.x, max(rgb.y, rgb.z))
        if maxC < 0.16 { return Self.inkAbs }
        let minC = min(rgb.x, min(rgb.y, rgb.z))
        let clamped = SIMD3<Float>(max(rgb.x, 0.02), max(rgb.y, 0.02), max(rgb.z, 0.02))
        let a = SIMD3<Float>(-log(clamped.x), -log(clamped.y), -log(clamped.z))
        let m = max(max(a.x, a.y), max(a.z, 0.25))
        let chromatic = a / m
        // Desaturate toward neutral for low-saturation (near-white / grey) picks.
        // The a/m normalization otherwise amplifies a tiny channel imbalance in a
        // light colour into a saturated hue — a white pick came out purple.
        // Saturated colours (sat≈1) keep their full hue; pure white → 0 (invisible,
        // use the White ink kind for opaque white pigment).
        let sat = maxC > 0 ? (maxC - minC) / maxC : 0
        let mean = (chromatic.x + chromatic.y + chromatic.z) / 3
        let neutral = SIMD3<Float>(repeating: mean)
        return neutral + (chromatic - neutral) * sat
    }

    /// Wet-field transmission colour for the display kernel. Default (no value /
    /// old presets) ≈ light blue-grey, reproducing the built-in wash tint.
    private static func washTint(_ color: RGBAColor?) -> SIMD4<Float> {
        let c = color ?? RGBAColor(red: 0.84, green: 0.85, blue: 0.89)
        // .w carries opacity = tint strength (how strongly the wash colours the
        // wet paper); rgb is the tint colour.
        return SIMD4<Float>(c.red, c.green, c.blue, c.alpha)
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
