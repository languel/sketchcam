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
            if textureInput != nil {
                renderSettings.landmarks.inkPaperEnabled = false
            }
            let ink = engine?.layer(settings: renderSettings, live: live, livePoints: livePoints,
                                    endedLiveID: endedLiveID, outputSize: outputSize, frameIndex: frameIndex)
            guard let textureInput else { return ink }
            let rect = CGRect(origin: .zero, size: outputSize)
            guard let ink else { return textureInput.cropped(to: rect) }
            return ink.composited(over: textureInput).cropped(to: rect)
        }
    }
}
