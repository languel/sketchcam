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

    func layer(settings: ProcessingSettings, live: InkLiveStrokeSample?, livePoints: [CGPoint],
               endedLiveID: UUID?, outputSize: CGSize, frameIndex: Int, textureInput: CIImage? = nil,
               actionPaths: [InkEditorPath]? = nil,
               controlFields: ResolvedControlFields = .empty) -> CIImage? {
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
            if let actionPaths {
                renderSettings.landmarks.inkPaths = actionPaths
            }
            let paperOpacity = max(0, min(1, settings.landmarks.inkPaperOpacity ?? (settings.landmarks.inkPaperEnabled ? 1 : 0)))
            let hasRoutedTexture = textureInput != nil
            renderSettings.landmarks.inkPaperEnabled = paperOpacity > 0.001
            if hasRoutedTexture {
                renderSettings.landmarks.inkPaperEnabled = false
            }
            let ink = engine?.layer(settings: renderSettings, live: live, livePoints: livePoints,
                                    endedLiveID: endedLiveID, outputSize: outputSize, frameIndex: frameIndex,
                                    controlFields: controlFields)
            let rect = CGRect(origin: .zero, size: outputSize)
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
