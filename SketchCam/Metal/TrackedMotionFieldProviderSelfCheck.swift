#if DEBUG
import CoreGraphics
import CoreMedia
import Metal
import SketchCamCore

extension TrackedMotionFieldProvider {
    static func runDeterministicSelfCheck(device: MTLDevice, store: GPUControlFieldStore) {
        let previous = LandmarkDetection(
            groups: [LandmarkGroup(region: .torso, points: [
                LandmarkPoint(point: CGPoint(x: 0.2, y: 0.3), confidence: 1, label: "a"),
                LandmarkPoint(point: CGPoint(x: 0.5, y: 0.6), confidence: 0.9, label: "b"),
                LandmarkPoint(point: CGPoint(x: 0.1, y: 0.1), confidence: 1, label: nil),
                LandmarkPoint(point: CGPoint(x: 0.8, y: 0.8), confidence: 0.05, label: "weak")
            ])],
            detectionID: 1,
            sourceSize: CGSize(width: 640, height: 480)
        )
        let current = LandmarkDetection(
            groups: [LandmarkGroup(region: .torso, points: [
                LandmarkPoint(point: CGPoint(x: 0.3, y: 0.25), confidence: 1, label: "a"),
                LandmarkPoint(point: CGPoint(x: 0.6, y: 0.55), confidence: 0.9, label: "b"),
                LandmarkPoint(point: CGPoint(x: 0.4, y: 0.4), confidence: 1, label: nil),
                LandmarkPoint(point: CGPoint(x: 0.9, y: 0.75), confidence: 0.05, label: "weak")
            ])],
            detectionID: 2,
            sourceSize: CGSize(width: 640, height: 480)
        )
        let config = MotionControlConfig(enabled: true, mode: .trackedHuman, smoothing: 0, decay: 0.8)
        let samples = matchedSamples(previous: previous, current: current, elapsed: 1, config: config)
        assert(samples.count == 2)
        assert(abs(samples[0].velocity.x - 0.1) < 0.0001)
        assert(abs(samples[0].velocity.y + 0.05) < 0.0001)

        let providerID = UUID()
        let settings = ControlFieldProvider(
            id: providerID,
            name: "Tracked self-check",
            kind: .trackedMotion,
            motionConfig: config
        )
        guard let provider = TrackedMotionFieldProvider(settings: settings, device: device) else {
            assertionFailure("Unable to create tracked-motion self-check provider")
            return
        }
        func context(_ detection: LandmarkDetection?, seconds: Double) -> ControlFieldFrameContext {
            ControlFieldFrameContext(
                frameIndex: Int(seconds * 30),
                timestamp: CMTime(seconds: seconds, preferredTimescale: 600),
                outputSize: CGSize(width: 64, height: 48),
                cameraPixelBuffer: nil,
                moviePixelBuffer: nil,
                detection: detection,
                settings: ProcessingSettings()
            )
        }
        provider.update(context(previous, seconds: 1), store: store)
        provider.update(context(current, seconds: 2), store: store)
        assert(store.debugPublishedField(provider: providerID, output: .motionVector)?.kind == .vector)
        assert(store.debugPublishedField(provider: providerID, output: .motionMagnitude)?.kind == .scalar)
        let movingRevision = provider.debugRevision
        provider.update(context(nil, seconds: 3), store: store)
        assert(provider.debugRevision > movingRevision)
        assert(provider.debugLastDecay == 0.8)
        provider.reset(store: store)
    }
}
#endif
