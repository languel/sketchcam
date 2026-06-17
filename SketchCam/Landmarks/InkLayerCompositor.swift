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

    func layer(settings: ProcessingSettings, live: InkLiveStrokeSample?, livePoints: [CGPoint],
               endedLiveID: UUID?, outputSize: CGSize, frameIndex: Int, textureInput: CIImage? = nil) -> CIImage? {
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
            let paperOpacity = max(0, min(1, settings.landmarks.inkPaperOpacity ?? (settings.landmarks.inkPaperEnabled ? 1 : 0)))
            let routedTexture = textureInput.flatMap { input -> CIImage? in
                guard paperOpacity > 0.001 else { return nil }
                if paperOpacity >= 0.999 { return input }
                let alpha = CIVector(x: 0, y: 0, z: 0, w: CGFloat(paperOpacity))
                return input.applyingFilter("CIColorMatrix", parameters: [
                    "inputAVector": alpha
                ])
            }
            renderSettings.landmarks.inkPaperEnabled = paperOpacity > 0.001
            if routedTexture != nil {
                renderSettings.landmarks.inkPaperEnabled = false
            }
            let ink = engine?.layer(settings: renderSettings, live: live, livePoints: livePoints,
                                    endedLiveID: endedLiveID, outputSize: outputSize, frameIndex: frameIndex)
            guard let routedTexture else { return ink }
            let rect = CGRect(origin: .zero, size: outputSize)
            guard let ink else { return routedTexture.cropped(to: rect) }
            return ink.composited(over: routedTexture).cropped(to: rect)
        }
    }
}
