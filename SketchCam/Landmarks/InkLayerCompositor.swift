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
    private let artifact = WorldInkArtifactCache()
    private var activeCamera: CanvasCamera?
    private var pendingInk: CIImage?
    private var settleFrames = 0
    private var lastClearRevision = 0

    func artifactReferences() -> [ArtifactTileReference] {
        lock.withLock { artifact.references() }
    }

    func writeArtifacts(to packageURL: URL) throws {
        try lock.withLock { try artifact.writeTiles(to: packageURL) }
    }

    func loadArtifacts(from packageURL: URL, references: [ArtifactTileReference]) throws {
        try lock.withLock {
            engine?.reset()
            pendingInk = nil
            settleFrames = 0
            try artifact.loadTiles(from: packageURL, references: references)
        }
    }

    /// Rasterizes the best stored world-tile LOD for an arbitrary camera and
    /// output size. This does not allocate or advance a fluid simulation.
    func artifactImage(camera: CanvasCamera, outputSize: CGSize) -> CIImage? {
        lock.withLock {
            if let pendingInk, let activeCamera {
                artifact.commit(pendingInk, camera: activeCamera, outputSize: outputSize)
                self.pendingInk = nil
            }
            return artifact.image(camera: camera, outputSize: outputSize)
        }
    }

    func layer(settings: ProcessingSettings, live: InkLiveStrokeSample?, livePoints: [CGPoint],
               endedLiveID: UUID?, outputSize: CGSize, camera: CanvasCamera = CanvasCamera(), frameIndex: Int, textureInput: CIImage? = nil,
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
            artifact.resetBaseDensity(outputSize.height)
            if let activeCamera, activeCamera != camera {
                if let pendingInk { artifact.commit(pendingInk, camera: activeCamera, outputSize: outputSize) }
                pendingInk = nil
                engine?.reset()
                settleFrames = 0
            }
            activeCamera = camera
            let clearRevision = settings.landmarks.inkClearFadeRevision ?? 0
            if clearRevision != lastClearRevision {
                lastClearRevision = clearRevision
                artifact.clear()
            }
            var renderSettings = settings
            let paperOpacity = max(0, min(1, settings.landmarks.inkPaperOpacity ?? (settings.landmarks.inkPaperEnabled ? 1 : 0)))
            let hasRoutedTexture = textureInput != nil
            // The world tile cache stores ink only. Paper/substrate is applied
            // after the camera extracts the visible artifact.
            renderSettings.landmarks.inkPaperEnabled = false
            renderSettings.landmarks.inkPaperOpacity = 0
            let ink = engine?.layer(settings: renderSettings, live: live, livePoints: livePoints,
                                    endedLiveID: endedLiveID, outputSize: outputSize, frameIndex: frameIndex,
                                    controlFields: controlFields)
            let rect = CGRect(origin: .zero, size: outputSize)
            if live != nil || endedLiveID != nil { settleFrames = 180 }
            if let ink { pendingInk = ink }
            if settleFrames > 0 {
                settleFrames -= 1
                if settleFrames == 0, let pendingInk {
                    artifact.commit(pendingInk, camera: camera, outputSize: outputSize)
                    self.pendingInk = nil
                    engine?.reset()
                }
            }
            let settled = artifact.image(camera: camera, outputSize: outputSize)
            let visibleInk: CIImage? = {
                guard let ink else { return settled }
                guard let settled else { return ink }
                return ink.composited(over: settled).cropped(to: rect)
            }()

            let routed: CIImage? = textureInput?.cropped(to: rect) ?? {
                guard paperOpacity > 0.001, let paperRenderer else { return nil }
                let config = settings.landmarks.inkPaperConfig ?? .metalDefault
                return paperRenderer.image(config: config, rect: rect)
            }()
            guard let routed, paperOpacity > 0.001 else { return visibleInk }
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
            guard let visibleInk else { return visibleSubstrate }
            return visibleInk.composited(over: visibleSubstrate).cropped(to: rect)
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
