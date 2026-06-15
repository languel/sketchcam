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

    func layer(settings: ProcessingSettings, live: InkLiveStrokeSample?, livePoints: [CGPoint], endedLiveID: UUID?, outputSize: CGSize, frameIndex: Int) -> CIImage? {
        let l = settings.landmarks
        guard l.inkEnabled else {
            return lock.withLock {
                engine?.reset()
                return nil
            }
        }
        return lock.withLock {
            if engine == nil { engine = MetalInkEngine() }
            return engine?.layer(settings: settings, live: live, livePoints: livePoints, endedLiveID: endedLiveID, outputSize: outputSize, frameIndex: frameIndex)
        }
    }
}
