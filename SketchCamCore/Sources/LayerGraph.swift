import Foundation

// MARK: - Layer + routing graph (Phase 1: model + migration only)
//
// SketchCam is modelled as a small DAG of typed nodes. Two signal types flow
// through it — pixels/textures and paths. Nodes are sources / effects / drawing
// algorithms / brushes / ink / web; each declares typed input ports and one
// output. `Layer`s are the pixel-producing nodes that get composited (ordered
// stack, blend/opacity/mask). A port can be bound to a shared source OR to
// another node's output — that binding is the routing (e.g. ink.texture ← web).
//
// This file is the data model + graph algorithms + a migration that builds the
// default graph from the legacy `ProcessingSettings`. Nothing here drives
// rendering yet (the compositor still reads `ProcessingSettings`); that switch is
// Phase 2. Node payloads are intentionally slim — full per-node config re-homes
// when the compositor starts consuming the graph.

public enum SignalType: String, Codable, Sendable, CaseIterable {
    case pixel
    case path
}

/// Shared, singleton inputs computed once per frame (not layers).
public enum SourceID: String, Codable, Sendable, CaseIterable {
    case camera        // pixel
    case landmarks     // path  (Vision feature analysis)
    case mouse         // path  (live brush strokes)
    case personMatte   // pixel (Vision segmentation mask)

    public var signalType: SignalType {
        switch self {
        case .camera, .personMatte: return .pixel
        case .landmarks, .mouse: return .path
        }
    }
}

/// Compositing blend modes. The full set is the goal; the compositor implements
/// them incrementally (normal/multiply/screen first).
public enum BlendMode: String, Codable, Sendable, CaseIterable {
    case normal, multiply, screen, add, overlay, darken, lighten
    case difference, subtract, hue, saturation, color, luminosity
}

/// Per-layer mask. Today: key the layer to the person (or its inverse).
public enum LayerMask: Codable, Sendable, Equatable {
    case person(invert: Bool)
}

/// The drawing algorithms — one per `drawing` node (max routing flexibility).
public enum DrawingAlgorithm: String, Codable, Sendable, CaseIterable {
    case yarn, wrap, lineWalk
}

/// Per-node config payloads (the start of moving feature config into the graph).
public struct SolidConfig: Codable, Sendable, Equatable {
    public var color: RGBAColor
    public init(color: RGBAColor = RGBAColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1)) {
        self.color = color
    }
}

/// One entry in a layer's ordered effect chain (v2 — per-layer effects).
/// A single struct carries the params for every effect kind; only the fields
/// relevant to `kind` are used. Re-homes the legacy effect flags in a later step.
public enum EffectKind: String, Codable, Sendable, CaseIterable {
    case threshold, outline, invert, blur
}

public struct EffectConfig: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var kind: EffectKind
    public var enabled: Bool
    public var amount: Float        // threshold level / edge strength / blur radius
    public var color: RGBAColor     // outline colour
    public var thickness: Float     // outline thickness
    public var invert: Bool         // threshold invert
    public var inkOnly: Bool        // threshold: transparent paper

    public init(id: UUID = UUID(), kind: EffectKind, enabled: Bool = true,
                amount: Float = 0.5, color: RGBAColor = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                thickness: Float = 2, invert: Bool = false, inkOnly: Bool = false) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.amount = amount
        self.color = color
        self.thickness = thickness
        self.invert = invert
        self.inkOnly = inkOnly
    }
}

/// A typed input port a node exposes.
public struct Port: Codable, Sendable, Equatable {
    public var name: String
    public var type: SignalType
    public init(name: String, type: SignalType) {
        self.name = name
        self.type = type
    }
}

/// Where a node's input port gets its signal.
public enum PortBinding: Codable, Sendable, Equatable {
    case none                  // use the kind's built-in default for that port
    case source(SourceID)      // a shared input
    case node(UUID)            // another node's output — the routing
}

/// What a node is. Payloads slim in Phase 1 (identity + params needed to declare
/// ports); full config re-homes here in Phase 2.
public enum NodeKind: Codable, Sendable, Equatable {
    case video                  // camera stream (camera-derived pixels)
    case movie                  // movie/file stream
    case solid(SolidConfig)     // color / transparent fill (per-node colour)
    case paper                  // ink substrate stream (so ink can sit on any layer)
    case personMatte            // segmentation matte as a stream (use as a mask source)
    case effect                 // pixel → pixel (legacy standalone; v2 uses per-layer chains)
    case overlay                // combined marks+drawing (today's single overlay image)
    case marks                  // landmark dots / stick (Phase 3b: own image)
    case drawing(DrawingAlgorithm)  // (Phase 3b: own image per algorithm)
    case ink
    case web

    /// Input ports this kind exposes, in binding order.
    public var ports: [Port] {
        switch self {
        case .video:   return [Port(name: "source", type: .pixel)]
        case .movie:   return []
        case .solid:   return []
        case .paper:   return []
        case .personMatte: return []
        case .effect:  return [Port(name: "image", type: .pixel)]
        case .overlay: return [Port(name: "analysis", type: .path)]
        // (associated-value cases still match the bare pattern in a switch.)
        case .marks:   return [Port(name: "analysis", type: .path)]
        case .drawing: return [Port(name: "analysis", type: .path)]
        case .ink:     return [Port(name: "strokes", type: .path),
                               Port(name: "texture", type: .pixel)]
        case .web:     return []
        }
    }

    /// The signal this kind outputs. (All pixel for now; path-generator nodes
    /// arrive in a later phase.)
    public var output: SignalType { .pixel }

    /// Kind identity ignoring associated config — for matching during reconcile.
    public var family: String {
        switch self {
        case .video: return "video"
        case .movie: return "movie"
        case .solid: return "solid"
        case .paper: return "paper"
        case .personMatte: return "personMatte"
        case .effect: return "effect"
        case .overlay: return "overlay"
        case .marks: return "marks"
        case .drawing(let a): return "drawing.\(a.rawValue)"
        case .ink: return "ink"
        case .web: return "web"
        }
    }

    /// The default binding for each port when a node is created fresh.
    public var defaultBindings: [PortBinding] {
        switch self {
        case .video:   return [.source(.camera)]
        case .movie:   return []
        case .solid:   return []
        case .paper:   return []
        case .personMatte: return []
        case .effect:  return [.none]
        case .overlay: return [.source(.landmarks)]
        case .marks:   return [.source(.landmarks)]
        case .drawing: return [.source(.landmarks)]
        case .ink:     return [.source(.mouse), .none]   // texture unrouted by default
        case .web:     return []
        }
    }
}

public struct Node: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var kind: NodeKind
    /// One binding per `kind.ports`, same order.
    public var inputs: [PortBinding]
    /// true = derived from the legacy feature flags (reconciliation owns it);
    /// false = user-created in the Layers panel (preserved across reconcile).
    public var managed: Bool

    public init(id: UUID = UUID(), name: String, kind: NodeKind, inputs: [PortBinding]? = nil, managed: Bool = true) {
        self.id = id
        self.name = name
        self.kind = kind
        self.inputs = inputs ?? kind.defaultBindings
        self.managed = managed
    }
}

/// A composited layer: displays one pixel node (its content stream), with an
/// ordered effect chain, a mask, and stacking attributes.
public struct Layer: Identifiable, Codable, Sendable, Equatable {
    public var id: UUID
    public var node: UUID
    public var visible: Bool
    public var opacity: Float
    public var blend: BlendMode
    public var mask: LayerMask?
    /// Ordered effects applied to this layer's content before mask + composite.
    public var effects: [EffectConfig]

    public init(id: UUID = UUID(), node: UUID, visible: Bool = true, opacity: Float = 1,
                blend: BlendMode = .normal, mask: LayerMask? = nil, effects: [EffectConfig] = []) {
        self.id = id
        self.node = node
        self.visible = visible
        self.opacity = opacity
        self.blend = blend
        self.mask = mask
        self.effects = effects
    }

    // Backward-compatible decoding: graphs persisted before `effects` existed
    // decode with an empty chain rather than failing the whole settings load.
    private enum CodingKeys: String, CodingKey {
        case id, node, visible, opacity, blend, mask, effects
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        node = try c.decode(UUID.self, forKey: .node)
        visible = try c.decode(Bool.self, forKey: .visible)
        opacity = try c.decode(Float.self, forKey: .opacity)
        blend = try c.decode(BlendMode.self, forKey: .blend)
        mask = try c.decodeIfPresent(LayerMask.self, forKey: .mask)
        effects = try c.decodeIfPresent([EffectConfig].self, forKey: .effects) ?? []
    }
}

public struct LayerGraph: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public var version: Int
    public var nodes: [Node]
    /// Ordered bottom → top; each references a node by id.
    public var layers: [Layer]

    public init(version: Int = LayerGraph.currentVersion, nodes: [Node] = [], layers: [Layer] = []) {
        self.version = version
        self.nodes = nodes
        self.layers = layers
    }

    public func node(_ id: UUID) -> Node? { nodes.first { $0.id == id } }
}

// MARK: - Validation + scheduling

public enum LayerGraphError: Error, Equatable {
    case portCountMismatch(node: UUID)
    case signalTypeMismatch(node: UUID, port: String)
    case danglingBinding(node: UUID, port: String)
    case cycle
}

public extension LayerGraph {
    /// Validate port arity, signal-type matching, and no dangling node refs.
    func validate() throws {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
        for node in nodes {
            let ports = node.kind.ports
            guard node.inputs.count == ports.count else {
                throw LayerGraphError.portCountMismatch(node: node.id)
            }
            for (port, binding) in zip(ports, node.inputs) {
                switch binding {
                case .none:
                    break
                case .source(let s):
                    if s.signalType != port.type {
                        throw LayerGraphError.signalTypeMismatch(node: node.id, port: port.name)
                    }
                case .node(let upstream):
                    guard let up = byID[upstream] else {
                        throw LayerGraphError.danglingBinding(node: node.id, port: port.name)
                    }
                    if up.kind.output != port.type {
                        throw LayerGraphError.signalTypeMismatch(node: node.id, port: port.name)
                    }
                }
            }
        }
        _ = try topologicallySortedNodeIDs()
    }

    /// Node ids in dependency order (upstream before downstream). Throws on cycle.
    func topologicallySortedNodeIDs() throws -> [UUID] {
        var result: [UUID] = []
        var state: [UUID: Int] = [:]   // 0 = visiting, 1 = done
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        func visit(_ id: UUID) throws {
            switch state[id] {
            case 1: return
            case 0: throw LayerGraphError.cycle
            default: break
            }
            state[id] = 0
            if let node = byID[id] {
                for binding in node.inputs {
                    if case .node(let up) = binding, byID[up] != nil {
                        try visit(up)
                    }
                }
            }
            state[id] = 1
            result.append(id)
        }

        for node in nodes { try visit(node.id) }
        return result
    }
}

// MARK: - Migration from legacy ProcessingSettings

public extension LayerGraph {
    /// Build the default graph from the legacy flat settings, preserving today's
    /// visual order. This does NOT yet drive rendering — it's the structural
    /// starting point the compositor will adopt in Phase 2.
    static func defaultGraph(from settings: ProcessingSettings) -> LayerGraph {
        var nodes: [Node] = []
        var layers: [Layer] = []
        let l = settings.landmarks
        // Person key currently masks only the video layer (the marks/drawing
        // overlay and ink/web are composited un-keyed in today's pipeline).
        let personMask: LayerMask? = settings.segmentation.enabled ? .person(invert: false) : nil

        func emit(_ node: Node, mask: LayerMask? = nil) {
            nodes.append(node)
            layers.append(Layer(node: node.id, mask: mask))
        }

        // Bottom→top, matching the legacy compositor exactly:
        //   [background] → video → web-behind → ink-behind → marks+drawing
        //   → ink-above → web-above
        if settings.backgroundMode != .live {
            emit(Node(name: "Background", kind: .solid(SolidConfig(color: settings.backgroundColor))))
        }
        emit(Node(name: "Camera", kind: .video), mask: personMask)

        if settings.web.enabled, settings.web.placement == .behindDrawing {
            emit(Node(name: "Web", kind: .web))
        }
        // Ink is independent of the Marks/landmarks master toggle.
        if l.inkEnabled, l.inkPlacement == .behindDrawing {
            emit(Node(name: "Ink", kind: .ink))
        }

        // The marks/drawing "overlay" — one merged image today, so one layer.
        // (Phase 3b splits this into per-algorithm layers.)
        if l.enabled, l.showDots || l.showStick || l.yarnEnabled || l.wrapEnabled || l.lineWalkEnabled {
            emit(Node(name: "Drawing", kind: .overlay))
        }

        if l.inkEnabled, l.inkPlacement == .aboveDrawing {
            emit(Node(name: "Ink", kind: .ink))
        }
        if settings.web.enabled, settings.web.placement == .aboveDrawing {
            emit(Node(name: "Web", kind: .web))
        }

        return LayerGraph(nodes: nodes, layers: layers)
    }

    /// Reconcile an existing (user-edited) graph against the current settings:
    /// keep the user's order + visibility + opacity + blend for layers that still
    /// exist (matched by node kind — instances are unique for now), drop layers
    /// whose feature was turned off, and append newly-enabled layers in their
    /// canonical position. Lets the legacy feature toggles and the Layers UI
    /// coexist while the graph is the source of truth for arrangement.
    func reconciled(with settings: ProcessingSettings) -> LayerGraph {
        let desired = LayerGraph.defaultGraph(from: settings)
        func family(_ g: LayerGraph, _ l: Layer) -> String? { g.node(l.node)?.kind.family }
        let desiredFamilies = Set(desired.layers.compactMap { family(desired, $0) })

        var resultLayers: [Layer] = []
        var resultNodes: [Node] = []
        var keptFamilies: [String] = []   // managed families kept, in result order
        for layer in layers {
            guard let node = self.node(layer.node) else { continue }
            if !node.managed {
                // User-created layers are always preserved, in place.
                resultNodes.append(node); resultLayers.append(layer)
            } else if let f = family(self, layer), desiredFamilies.contains(f) {
                resultNodes.append(node); resultLayers.append(layer); keptFamilies.append(f)
            }
            // else: a managed layer whose feature was disabled → dropped.
        }
        // Insert newly-enabled managed families at their canonical position
        // (relative to the other managed layers).
        for dl in desired.layers {
            guard let f = family(desired, dl), !keptFamilies.contains(f), let dn = desired.node(dl.node) else { continue }
            // How many desired-managed families precede f and were kept?
            let priorsKept = desired.layers.prefix(while: { family(desired, $0) != f })
                .reduce(0) { acc, prior in keptFamilies.contains(family(desired, prior) ?? "") ? acc + 1 : acc }
            // Walk result to just after that many kept-managed layers.
            var idx = 0, seenManaged = 0
            while idx < resultNodes.count, seenManaged < priorsKept {
                if resultNodes[idx].managed { seenManaged += 1 }
                idx += 1
            }
            resultNodes.insert(dn, at: min(idx, resultNodes.count))
            resultLayers.insert(dl, at: min(idx, resultLayers.count))
            keptFamilies.append(f)
        }
        return LayerGraph(nodes: resultNodes, layers: resultLayers)
    }
}
