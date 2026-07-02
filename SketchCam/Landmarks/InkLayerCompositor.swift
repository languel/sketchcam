import CoreGraphics
import CoreImage
import Foundation
import SketchCamCore

/// Full-canvas inkwash layer backed by the native Metal feedback simulator.
/// The returned CIImage is a materialized BGRA pixel buffer, so the main frame
/// compositor receives a flat image instead of a recursively growing CI graph.
final class InkLayerCompositor {
    private let lock = NSLock()
    private var engines: [UUID: MetalInkEngine] = [:]
    private let legacyEngineID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    func layer(nodeID: UUID? = nil, settings: ProcessingSettings, live: InkLiveStrokeSample?, livePoints: [InkLiveStrokePoint],
               endedLiveID: UUID?, outputSize: CGSize, frameIndex: Int, textureInput: CIImage? = nil,
               actionPaths: [InkEditorPath]? = nil,
               controlFields: ResolvedControlFields = .empty) -> CIImage? {
        let l = settings.landmarks
        let key = nodeID ?? legacyEngineID
        guard l.inkEnabled else {
            return lock.withLock {
                engines[key]?.reset()
                return nil
            }
        }
        return lock.withLock {
            let engine: MetalInkEngine
            if let existing = engines[key] {
                engine = existing
            } else if let created = MetalInkEngine() {
                engines[key] = created
                engine = created
            } else {
                return nil
            }
            var renderSettings = settings
            if let actionPaths {
                renderSettings.landmarks.inkPaths = actionPaths
            }
            renderSettings.landmarks.inkPaperConfig = Self.neutralPaperConfig
            renderSettings.landmarks.inkPaperEnabled = false
            return engine.layer(settings: renderSettings, live: live, livePoints: livePoints,
                                endedLiveID: endedLiveID, outputSize: outputSize, frameIndex: frameIndex,
                                controlFields: controlFields)
        }
    }

    private static var neutralPaperConfig: PaperConfig {
        var config = PaperConfig.metalDefault
        config.tint = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        config.grain = 0
        config.texture = .fiber
        config.response = 0
        config.variation = 0
        config.contrast = 1
        config.saturation = 0
        config.vignetteStrength = 0
        config.fiberStrength = 0
        config.toothStrength = 0
        config.grainScaleX = 0.12
        config.grainScaleY = 0.12
        config.absorbency = 0
        config.drag = 0
        config.resist = 0
        return config
    }
}
