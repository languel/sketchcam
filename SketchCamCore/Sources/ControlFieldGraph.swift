import Foundation

/// Spatial GPU data used to control simulations without becoming a visible
/// compositing layer. Scalar fields are normalized masks; vector fields carry
/// signed canvas-space motion.
public enum ControlFieldKind: String, Codable, Sendable, CaseIterable {
    case scalar
    case vector
}

/// Stable names published by the first material and motion providers.
public enum ControlFieldOutputID: String, Codable, Sendable, CaseIterable {
    case paperAbsorbency
    case paperDrag
    case paperResist
    case motionMagnitude
    case motionVector

    public var kind: ControlFieldKind {
        self == .motionVector ? .vector : .scalar
    }
}

/// Typed control inputs exposed by simulations.
public enum ControlFieldInputID: String, Codable, Sendable, CaseIterable {
    case absorbency
    case drag
    case resist
    case surfaceModulation
    case motionVector
    case wetness

    public var kind: ControlFieldKind {
        self == .motionVector ? .vector : .scalar
    }
}

public enum ControlFieldProviderKind: String, Codable, Sendable, CaseIterable {
    case paper
    case trackedMotion
    case opticalFlow
    case combinedMotion

    public var outputs: Set<ControlFieldOutputID> {
        switch self {
        case .paper:
            return [.paperAbsorbency, .paperDrag, .paperResist]
        case .trackedMotion, .opticalFlow, .combinedMotion:
            return [.motionMagnitude, .motionVector]
        }
    }
}

public enum ControlFieldUpdateQuality: String, Codable, Sendable, CaseIterable {
    case low
    case medium
    case high
}

public enum MotionExtractionMode: String, Codable, Sendable, CaseIterable {
    case trackedHuman
    case opticalFlow
    case combined
}

public enum MotionInputSource: String, Codable, Sendable, CaseIterable {
    case camera
    case movie
    case inkTexture
}

public struct MotionControlConfig: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var mode: MotionExtractionMode
    public var input: MotionInputSource
    public var sensitivity: Float
    public var threshold: Float
    public var smoothing: Float
    public var decay: Float
    public var spatialScale: Float
    public var maximumForce: Float

    public init(
        enabled: Bool = false,
        mode: MotionExtractionMode = .combined,
        input: MotionInputSource = .camera,
        sensitivity: Float = 1,
        threshold: Float = 0.03,
        smoothing: Float = 0.7,
        decay: Float = 0.85,
        spatialScale: Float = 1,
        maximumForce: Float = 1
    ) {
        self.enabled = enabled
        self.mode = mode
        self.input = input
        self.sensitivity = sensitivity
        self.threshold = threshold
        self.smoothing = smoothing
        self.decay = decay
        self.spatialScale = spatialScale
        self.maximumForce = maximumForce
    }
}

public enum ControlFieldConsumerID: Codable, Sendable, Hashable {
    case ink
    case acrylic(UUID)
}

public struct ControlFieldReference: Codable, Sendable, Equatable, Hashable {
    public var provider: UUID
    public var output: ControlFieldOutputID

    public init(provider: UUID, output: ControlFieldOutputID) {
        self.provider = provider
        self.output = output
    }
}

public struct ControlFieldProvider: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: ControlFieldProviderKind
    public var enabled: Bool
    public var quality: ControlFieldUpdateQuality
    /// Upstream fields used by derived providers such as Combined Motion.
    public var inputs: [ControlFieldReference]
    public var motionConfig: MotionControlConfig?
    public var paperNodeID: UUID?

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ControlFieldProviderKind,
        enabled: Bool = true,
        quality: ControlFieldUpdateQuality = .low,
        inputs: [ControlFieldReference] = [],
        motionConfig: MotionControlConfig? = nil,
        paperNodeID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.quality = quality
        self.inputs = inputs
        self.motionConfig = motionConfig
        self.paperNodeID = paperNodeID
    }


    public var resolvedMotionConfig: MotionControlConfig { motionConfig ?? MotionControlConfig() }
}

public struct ControlFieldRoute: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var consumer: ControlFieldConsumerID
    public var input: ControlFieldInputID
    public var source: ControlFieldReference
    public var strength: Float
    public var invert: Bool
    public var threshold: Float

    public init(
        id: UUID = UUID(),
        consumer: ControlFieldConsumerID,
        input: ControlFieldInputID,
        source: ControlFieldReference,
        strength: Float = 1,
        invert: Bool = false,
        threshold: Float = 0
    ) {
        self.id = id
        self.consumer = consumer
        self.input = input
        self.source = source
        self.strength = strength
        self.invert = invert
        self.threshold = threshold
    }
}

public enum ControlFieldGraphError: Error, Equatable {
    case duplicateProvider(UUID)
    case duplicateRoute(UUID)
    case danglingProvider(provider: UUID)
    case unavailableOutput(provider: UUID, output: ControlFieldOutputID)
    case kindMismatch(route: UUID)
    case cycle
}

public struct ControlFieldGraph: Codable, Sendable, Equatable {
    private static let internalInkPaperProviderID = UUID(uuidString: "7BDE6A90-6B1F-4DA5-9B42-A2174A0B1001")!
    private static let internalInkPaperRouteIDs: [ControlFieldInputID: UUID] = [
        .absorbency: UUID(uuidString: "7BDE6A90-6B1F-4DA5-9B42-A2174A0B1002")!,
        .drag: UUID(uuidString: "7BDE6A90-6B1F-4DA5-9B42-A2174A0B1003")!,
        .resist: UUID(uuidString: "7BDE6A90-6B1F-4DA5-9B42-A2174A0B1004")!
    ]
    private static let internalInkMotionProviderID = UUID(uuidString: "7BDE6A90-6B1F-4DA5-9B42-A2174A0B1010")!
    private static let internalInkMotionRouteIDs: [ControlFieldInputID: UUID] = [
        .surfaceModulation: UUID(uuidString: "7BDE6A90-6B1F-4DA5-9B42-A2174A0B1011")!,
        .motionVector: UUID(uuidString: "7BDE6A90-6B1F-4DA5-9B42-A2174A0B1012")!,
        .wetness: UUID(uuidString: "7BDE6A90-6B1F-4DA5-9B42-A2174A0B1013")!
    ]
    public var providers: [ControlFieldProvider]
    public var routes: [ControlFieldRoute]

    public init(providers: [ControlFieldProvider] = [], routes: [ControlFieldRoute] = []) {
        self.providers = providers
        self.routes = routes
    }

    public static let empty = ControlFieldGraph()

    /// Supplies the Ink engine's internal paper as a physical source whenever
    /// Paper Influence is active. Explicit routes win input-by-input.
    public func addingDefaultInkPaperRoutes() -> ControlFieldGraph {
        let mappings: [(ControlFieldInputID, ControlFieldOutputID)] = [
            (.absorbency, .paperAbsorbency), (.drag, .paperDrag), (.resist, .paperResist)
        ]
        let missing = mappings.filter { input, _ in
            !routes.contains { $0.consumer == .ink && $0.input == input }
        }
        guard !missing.isEmpty else { return self }
        var result = self
        if !result.providers.contains(where: { $0.id == Self.internalInkPaperProviderID }) {
            result.providers.append(ControlFieldProvider(
                id: Self.internalInkPaperProviderID,
                name: "Internal Ink Paper",
                kind: .paper
            ))
        }
        result.routes.append(contentsOf: missing.map { input, output in
            ControlFieldRoute(
                id: Self.internalInkPaperRouteIDs[input]!,
                consumer: .ink,
                input: input,
                source: .init(provider: Self.internalInkPaperProviderID, output: output)
            )
        })
        return result
    }

    /// Uses optical flow from the Ink node's routed texture as the
    /// zero-configuration live source. This makes a post-effect Camera or
    /// Movie layer drive the same physical response that is visible as paper.
    public func addingDefaultInkMotionRoutes() -> ControlFieldGraph {
        let mappings: [(ControlFieldInputID, ControlFieldOutputID)] = [
            (.surfaceModulation, .motionMagnitude), (.motionVector, .motionVector),
            (.wetness, .motionMagnitude)
        ]
        let missing = mappings.filter { input, _ in
            !routes.contains { $0.consumer == .ink && $0.input == input }
        }
        guard !missing.isEmpty else { return self }
        var result = self
        if !result.providers.contains(where: { $0.id == Self.internalInkMotionProviderID }) {
            result.providers.append(ControlFieldProvider(
                id: Self.internalInkMotionProviderID,
                name: "Paper Input Motion",
                kind: .opticalFlow,
                motionConfig: MotionControlConfig(enabled: true, mode: .opticalFlow, input: .inkTexture)
            ))
        }
        result.routes.append(contentsOf: missing.map { input, output in
            ControlFieldRoute(
                id: Self.internalInkMotionRouteIDs[input]!,
                consumer: .ink,
                input: input,
                source: .init(provider: Self.internalInkMotionProviderID, output: output)
            )
        })
        return result
    }

    public func validate() throws {
        var providersByID: [UUID: ControlFieldProvider] = [:]
        for provider in providers {
            guard providersByID.updateValue(provider, forKey: provider.id) == nil else {
                throw ControlFieldGraphError.duplicateProvider(provider.id)
            }
        }

        var routeIDs = Set<UUID>()
        for route in routes {
            guard routeIDs.insert(route.id).inserted else {
                throw ControlFieldGraphError.duplicateRoute(route.id)
            }
            try validate(route.source, providersByID: providersByID)
            guard route.source.output.kind == route.input.kind else {
                throw ControlFieldGraphError.kindMismatch(route: route.id)
            }
        }

        for provider in providers {
            for input in provider.inputs {
                try validate(input, providersByID: providersByID)
            }
        }
        try validateAcyclic(providersByID: providersByID)
    }

    private func validate(
        _ reference: ControlFieldReference,
        providersByID: [UUID: ControlFieldProvider]
    ) throws {
        guard let provider = providersByID[reference.provider] else {
            throw ControlFieldGraphError.danglingProvider(provider: reference.provider)
        }
        guard provider.kind.outputs.contains(reference.output) else {
            throw ControlFieldGraphError.unavailableOutput(
                provider: reference.provider,
                output: reference.output
            )
        }
    }

    private func validateAcyclic(providersByID: [UUID: ControlFieldProvider]) throws {
        var state: [UUID: UInt8] = [:]

        func visit(_ id: UUID) throws {
            switch state[id] {
            case 1: throw ControlFieldGraphError.cycle
            case 2: return
            default: break
            }
            state[id] = 1
            if let provider = providersByID[id] {
                for input in provider.inputs {
                    try visit(input.provider)
                }
            }
            state[id] = 2
        }

        for provider in providers {
            try visit(provider.id)
        }
    }
}
