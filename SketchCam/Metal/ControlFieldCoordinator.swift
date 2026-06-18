import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Metal
import SketchCamCore
import os

struct ControlFieldFrameContext {
    let frameIndex: Int
    let timestamp: CMTime
    let outputSize: CGSize
    let cameraPixelBuffer: CVPixelBuffer?
    let moviePixelBuffer: CVPixelBuffer?
    let detection: LandmarkDetection?
    let settings: ProcessingSettings

    var width: Int { max(1, Int(outputSize.width.rounded(.up))) }
    var height: Int { max(1, Int(outputSize.height.rounded(.up))) }
}

protocol GPUControlFieldProvider: AnyObject {
    var id: UUID { get }
    var outputs: Set<ControlFieldOutputID> { get }
    func update(_ context: ControlFieldFrameContext, store: GPUControlFieldStore)
    func reset(store: GPUControlFieldStore)
}

struct ResolvedControlField {
    let field: GPUControlField
    let strength: Float
    let invert: Bool
    let threshold: Float
}

struct ResolvedControlFields {
    fileprivate struct Key: Hashable {
        let consumer: ControlFieldConsumerID
        let input: ControlFieldInputID
    }

    private let values: [Key: ResolvedControlField]

    static let empty = ResolvedControlFields(values: [:])

    fileprivate init(values: [Key: ResolvedControlField]) {
        self.values = values
    }

    func field(for consumer: ControlFieldConsumerID, input: ControlFieldInputID) -> ResolvedControlField? {
        values[Key(consumer: consumer, input: input)]
    }
}

/// Reconciles the persisted graph with live GPU providers once per frame.
/// Concrete paper and motion providers are installed by the feature plans that
/// own their settings; this shared layer only controls lifecycle and routing.
final class ControlFieldCoordinator {
    typealias ProviderFactory = (ControlFieldProvider) -> GPUControlFieldProvider?

    private static let logger = Logger(subsystem: "io.github.languel.sketchcam", category: "control-fields")

    private let store: GPUControlFieldStore
    private let providerFactory: ProviderFactory
    private var providers: [UUID: GPUControlFieldProvider] = [:]
    private var providerSettings: [UUID: ControlFieldProvider] = [:]
    private var lastValidationError: String?

    #if DEBUG
    private(set) var providerUpdateCount = 0
    #endif

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(), providerFactory: ProviderFactory? = nil) {
        guard let device, let store = GPUControlFieldStore(device: device) else { return nil }
        self.store = store
        self.providerFactory = providerFactory ?? { settings in
            switch settings.kind {
            case .paper: return PaperControlFieldProvider(settings: settings)
            case .trackedMotion, .opticalFlow, .combinedMotion: return nil
            }
        }
        #if DEBUG
        runDisabledPathSelfCheck()
        #endif
    }

    func update(graph: ControlFieldGraph, context: ControlFieldFrameContext) -> ResolvedControlFields {
        do {
            try graph.validate()
            lastValidationError = nil
        } catch {
            logValidationErrorOnce(error)
            removeAllProviders()
            return zeroFields(for: graph.routes, context: context)
        }

        let settingsByID = Dictionary(uniqueKeysWithValues: graph.providers.map { ($0.id, $0) })
        let enabledIDs = Set(graph.providers.lazy.filter(\.enabled).map(\.id))
        let routedIDs = Set(graph.routes.lazy.map { $0.source.provider }.filter { enabledIDs.contains($0) })
        let activeIDs = providerClosure(from: routedIDs, settingsByID: settingsByID, enabledIDs: enabledIDs)
        reconcile(activeIDs: activeIDs, settingsByID: settingsByID)

        for id in topologicalOrder(activeIDs: activeIDs, settingsByID: settingsByID) {
            guard let provider = providers[id] else { continue }
            provider.update(context, store: store)
            #if DEBUG
            providerUpdateCount += 1
            #endif
        }

        var resolved: [ResolvedControlFields.Key: ResolvedControlField] = [:]
        for route in graph.routes {
            let field = activeIDs.contains(route.source.provider)
                ? store.resolve(route.source, width: context.width, height: context.height)
                : store.zero(kind: route.input.kind, width: context.width, height: context.height)
            let key = ResolvedControlFields.Key(consumer: route.consumer, input: route.input)
            resolved[key] = ResolvedControlField(
                field: field,
                strength: route.strength,
                invert: route.invert,
                threshold: route.threshold
            )
        }
        return ResolvedControlFields(values: resolved)
    }

    private func zeroFields(
        for routes: [ControlFieldRoute],
        context: ControlFieldFrameContext
    ) -> ResolvedControlFields {
        var resolved: [ResolvedControlFields.Key: ResolvedControlField] = [:]
        for route in routes {
            let key = ResolvedControlFields.Key(consumer: route.consumer, input: route.input)
            resolved[key] = ResolvedControlField(
                field: store.zero(kind: route.input.kind, width: context.width, height: context.height),
                strength: route.strength,
                invert: route.invert,
                threshold: route.threshold
            )
        }
        return ResolvedControlFields(values: resolved)
    }

    func reset() {
        removeAllProviders()
        store.reset()
    }

    private func providerClosure(
        from roots: Set<UUID>,
        settingsByID: [UUID: ControlFieldProvider],
        enabledIDs: Set<UUID>
    ) -> Set<UUID> {
        var result = Set<UUID>()
        func visit(_ id: UUID) {
            guard enabledIDs.contains(id), result.insert(id).inserted, let settings = settingsByID[id] else { return }
            settings.inputs.forEach { visit($0.provider) }
        }
        roots.forEach(visit)
        return result
    }

    private func reconcile(activeIDs: Set<UUID>, settingsByID: [UUID: ControlFieldProvider]) {
        for id in Set(providerSettings.keys).subtracting(activeIDs) {
            providers[id]?.reset(store: store)
            providers[id] = nil
            providerSettings[id] = nil
            store.remove(provider: id)
        }

        for id in activeIDs {
            guard let settings = settingsByID[id] else { continue }
            if providerSettings[id] != settings {
                providers[id]?.reset(store: store)
                store.remove(provider: id)
                providers[id] = providerFactory(settings)
                providerSettings[id] = settings
            }
        }
    }

    private func topologicalOrder(
        activeIDs: Set<UUID>,
        settingsByID: [UUID: ControlFieldProvider]
    ) -> [UUID] {
        var visited = Set<UUID>()
        var order: [UUID] = []
        func visit(_ id: UUID) {
            guard activeIDs.contains(id), visited.insert(id).inserted else { return }
            settingsByID[id]?.inputs.forEach { visit($0.provider) }
            order.append(id)
        }
        activeIDs.sorted { $0.uuidString < $1.uuidString }.forEach(visit)
        return order
    }

    private func removeAllProviders() {
        for id in providerSettings.keys {
            providers[id]?.reset(store: store)
            store.remove(provider: id)
        }
        providers.removeAll()
        providerSettings.removeAll()
    }

    private func logValidationErrorOnce(_ error: Error) {
        let message = String(describing: error)
        guard message != lastValidationError else { return }
        lastValidationError = message
        Self.logger.error("Invalid control-field graph; disabling fields: \(message, privacy: .public)")
    }

    #if DEBUG
    private func runDisabledPathSelfCheck() {
        let context = ControlFieldFrameContext(
            frameIndex: 0,
            timestamp: .zero,
            outputSize: CGSize(width: 11, height: 7),
            cameraPixelBuffer: nil,
            moviePixelBuffer: nil,
            detection: nil,
            settings: ProcessingSettings()
        )
        let updatesBefore = providerUpdateCount
        let zeroAllocationsBefore = store.zeroAllocationCount
        let result = update(graph: .empty, context: context)
        assert(result.field(for: .ink, input: .drag) == nil)
        assert(providerUpdateCount == updatesBefore)
        assert(store.zeroAllocationCount == zeroAllocationsBefore)
    }
    #endif
}
