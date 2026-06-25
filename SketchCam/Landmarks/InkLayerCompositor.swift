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
    private let penRenderer = InkPenRibbonRenderer()

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
            // The PEN's ink doesn't go through the engine's nib splat; instead it's
            // rendered as a smooth ribbon and DEPOSITED into the dye (below) so the
            // wash can push it. The engine still owns the WASH (and the dye/sim).
            renderSettings.landmarks.inkPaths = sourcePaths.filter { !isPen($0) }
            let livePen = live?.brushMode == .pen
            let engineLive = livePen ? nil : live
            let engineLivePoints = livePen ? [] : livePoints

            // Render the pen ribbons to coverage images for this frame's deposit.
            let penDeposits = penRenderer.deposits(
                committed: penPaths, liveSample: livePen ? live : nil,
                livePoints: livePen ? livePoints : [], settings: settings,
                outputSize: outputSize, canvas: canvasContext)

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
                                    canvasContext: canvasContext, penDeposits: penDeposits)
            let rect = CGRect(origin: .zero, size: outputSize)

            // Wash + paper substrate — the engine output already contains the
            // deposited pen ink (wash pushes it), so no separate pen composite.
            guard let routed = textureInput?.cropped(to: rect), paperOpacity > 0.001 else { return ink }
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
            guard let ink else { return visibleSubstrate }
            return ink.composited(over: visibleSubstrate).cropped(to: rect)
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
