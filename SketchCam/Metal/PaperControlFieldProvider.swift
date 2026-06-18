import CoreGraphics
import Foundation
import SketchCamCore

/// Publishes hidden physical fields from the same cached renderer used for the
/// visible Paper source and Ink's internal substrate.
final class PaperControlFieldProvider: GPUControlFieldProvider {
    private struct CacheKey: Equatable {
        let config: ResolvedPaperConfig
        let width: Int
        let height: Int
    }

    let id: UUID
    let outputs: Set<ControlFieldOutputID> = [.paperAbsorbency, .paperDrag, .paperResist]

    private let paperNodeID: UUID?
    private let renderer: MetalPaperRenderer
    private var cachedKey: CacheKey?
    private var cachedTextures: PaperTextureSet?

    init?(settings: ControlFieldProvider, renderer: MetalPaperRenderer? = .shared) {
        guard settings.kind == .paper, let renderer else { return nil }
        id = settings.id
        paperNodeID = settings.paperNodeID
        self.renderer = renderer
    }

    func update(_ context: ControlFieldFrameContext, store: GPUControlFieldStore) {
        let config = paperConfig(in: context.settings)
        let key = CacheKey(config: config.resolved, width: context.width, height: context.height)
        if key != cachedKey {
            guard let commandBuffer = renderer.makeCommandBuffer(),
                  let textures = renderer.textures(
                    config: config,
                    size: CGSize(width: context.width, height: context.height),
                    commandBuffer: commandBuffer
                  ) else { return }
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            guard commandBuffer.status == .completed else { return }
            cachedKey = key
            cachedTextures = textures
        }
        guard let textures = cachedTextures else { return }
        store.publish(
            GPUControlField(kind: .scalar, texture: textures.absorbency, revision: textures.materialRevision),
            provider: id,
            output: .paperAbsorbency
        )
        store.publish(
            GPUControlField(kind: .scalar, texture: textures.drag, revision: textures.materialRevision),
            provider: id,
            output: .paperDrag
        )
        store.publish(
            GPUControlField(kind: .scalar, texture: textures.resist, revision: textures.materialRevision),
            provider: id,
            output: .paperResist
        )
    }

    func reset(store: GPUControlFieldStore) {
        cachedKey = nil
        cachedTextures = nil
        store.remove(provider: id)
    }

    private func paperConfig(in settings: ProcessingSettings) -> PaperConfig {
        if let paperNodeID,
           let graph = settings.layerGraph,
           let node = graph.nodes.first(where: { $0.id == paperNodeID }),
           case .paper(let config) = node.kind {
            return config
        }
        return settings.landmarks.inkPaperConfig ?? .metalDefault
    }
}
