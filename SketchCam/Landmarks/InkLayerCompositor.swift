import CoreGraphics
import CoreImage
import Foundation
import SketchCamCore

/// Full-canvas inkwash layer backed by the native Metal feedback simulator.
/// The returned CIImage is a materialized BGRA pixel buffer, so the main frame
/// compositor receives a flat image instead of a recursively growing CI graph.
final class InkLayerCompositor {
    private let lock = NSLock()
    private var engine: MetalInkEngine? = MetalInkEngine()
    private let paperRenderer = MetalPaperRenderer.shared
    private let penRenderer = InkVectorPenRenderer()

    var activitySnapshot: InkActivitySnapshot {
        lock.withLock { engine?.activitySnapshot ?? InkActivitySnapshot() }
    }

    func makeStateSnapshot() -> MetalInkStateSnapshot? {
        lock.withLock { engine?.makeStateSnapshot() }
    }

    func restoreStateSnapshot(_ snapshot: MetalInkStateSnapshot) -> Bool {
        lock.withLock {
            if engine == nil { engine = MetalInkEngine() }
            return engine?.restoreStateSnapshot(snapshot) ?? false
        }
    }

    func layer(settings: ProcessingSettings, live: InkLiveStrokeSample?, livePoints: [InkLiveStrokePoint],
               endedLiveID: UUID?, outputSize: CGSize, frameIndex: Int, textureInput: CIImage? = nil,
               actionPaths: [InkEditorPath]? = nil,
               controlFields: ResolvedControlFields = .empty,
               fixedDeltaTime: Float? = nil, advanceSimulation: Bool = true,
               canvasContext: CanvasRenderContext = CanvasRenderContext()) -> CIImage? {
        let l = settings.landmarks
        guard l.inkEnabled else {
            return lock.withLock {
                engine?.reset()
                return nil
            }
        }
        return lock.withLock {
            if engine == nil { engine = MetalInkEngine() }
            var renderSettings = settings
            let sourcePaths = actionPaths ?? settings.landmarks.inkPaths
            // PEN strokes render as crisp vector ribbons (below); only the WASH
            // goes through the fluid engine. Split committed + live by mode.
            func isPen(_ p: InkEditorPath) -> Bool {
                (p.brushMode ?? settings.landmarks.inkBrushMode ?? .pen) == .pen
            }
            let penPaths = sourcePaths.filter(isPen)
            // The PEN is a clean VECTOR layer (Core Graphics), composited OVER the
            // wash — it never touches the fluid dye (whose grain/edge roughen a
            // crisp line). The engine owns only the WASH now.
            renderSettings.landmarks.inkPaths = sourcePaths.filter { !isPen($0) }
            let livePen = live?.brushMode == .pen
            let engineLive = livePen ? nil : live
            let engineLivePoints = livePen ? [] : livePoints
            let rect = CGRect(origin: .zero, size: outputSize)

            // Crisp vector pen (committed + in-progress).
            let penImage = penRenderer.image(
                committed: penPaths, liveSample: livePen ? live : nil,
                livePoints: livePen ? livePoints : [], settings: settings,
                outputSize: outputSize, canvas: canvasContext)?.cropped(to: rect)

            let paperOpacity = max(0, min(1, settings.landmarks.inkPaperOpacity ?? (settings.landmarks.inkPaperEnabled ? 1 : 0)))
            let hasRoutedTexture = textureInput != nil
            renderSettings.landmarks.inkPaperEnabled = paperOpacity > 0.001
            if hasRoutedTexture {
                renderSettings.landmarks.inkPaperEnabled = false
            }
            let ink = engine?.layer(settings: renderSettings, live: engineLive, livePoints: engineLivePoints,
                                    endedLiveID: endedLiveID, outputSize: outputSize, frameIndex: frameIndex,
                                    controlFields: controlFields, fixedDeltaTime: fixedDeltaTime,
                                    advanceSimulation: advanceSimulation,
                                    canvasContext: canvasContext)

            // Wash + paper substrate (the WASH base the pen sits on).
            let washBase: CIImage?
            if let routed = textureInput?.cropped(to: rect), paperOpacity > 0.001 {
                let mode = settings.landmarks.inkPaperCompositeMode ?? .multiply
                let config = settings.landmarks.inkPaperConfig ?? .metalDefault
                let substrate: CIImage
                if mode == .none || paperRenderer == nil {
                    substrate = routed
                } else if let paper = paperRenderer?.image(config: config, rect: rect) {
                    substrate = blend(paper: paper, over: routed, mode: mode).cropped(to: rect)
                } else {
                    substrate = routed
                }
                let visibleSubstrate = applyOpacity(paperOpacity, to: substrate)
                washBase = ink.map { $0.composited(over: visibleSubstrate).cropped(to: rect) } ?? visibleSubstrate
            } else {
                washBase = ink
            }

            switch (penImage, washBase) {
            case let (p?, b?): return p.composited(over: b).cropped(to: rect)
            case let (p?, nil): return p
            case let (nil, b): return b
            }
        }
    }

    private func blend(paper: CIImage, over source: CIImage, mode: InkPaperCompositeMode) -> CIImage {
        let filter: String
        switch mode {
        case .none: return source
        case .normal: return paper.composited(over: source)
        case .multiply: filter = "CIMultiplyBlendMode"
        case .screen: filter = "CIScreenBlendMode"
        case .add: filter = "CIAdditionCompositing"
        case .overlay: filter = "CIOverlayBlendMode"
        case .darken: filter = "CIDarkenBlendMode"
        case .lighten: filter = "CILightenBlendMode"
        case .difference: filter = "CIDifferenceBlendMode"
        case .subtract: filter = "CISubtractBlendMode"
        case .softLight: filter = "CISoftLightBlendMode"
        }
        return paper.applyingFilter(filter, parameters: [kCIInputBackgroundImageKey: source])
    }

    private func applyOpacity(_ opacity: Float, to image: CIImage) -> CIImage {
        guard opacity < 0.999 else { return image }
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))
        ])
    }
}
