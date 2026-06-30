import CoreGraphics
import Foundation

public enum WorkspaceTool: String, CaseIterable, Identifiable, Sendable, Codable {
    case select
    case artboard
    case pan
    case transform
    case crop
    case mask
    case pen
    case wash

    public var id: String { rawValue }
}

public enum WorkspaceFrameRole: String, CaseIterable, Identifiable, Sendable, Codable {
    case output
    case layer
    case reference
    case preview

    public var id: String { rawValue }
}

public enum WorkspacePreviewPolicy: String, CaseIterable, Identifiable, Sendable, Codable {
    case full
    case throttled
    case boundsOnly

    public var id: String { rawValue }
}

public enum WorkspaceContentFit: String, CaseIterable, Identifiable, Sendable, Codable {
    case fill
    case fit
    case stretch

    public var id: String { rawValue }
}

public struct WorkspaceAffineTransform: Equatable, Sendable, Codable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, tx: Double = 0, ty: Double = 0) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public init(_ transform: CGAffineTransform) {
        self.init(
            a: transform.a,
            b: transform.b,
            c: transform.c,
            d: transform.d,
            tx: transform.tx,
            ty: transform.ty
        )
    }

    public static let identity = WorkspaceAffineTransform()

    public var cgAffineTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    public static func translation(x: Double, y: Double) -> WorkspaceAffineTransform {
        WorkspaceAffineTransform(tx: x, ty: y)
    }
}

public struct WorkspaceImageConfig: Equatable, Sendable, Codable {
    public var urlString: String
    public var bookmarkData: Data?

    public init(urlString: String = "", bookmarkData: Data? = nil) {
        self.urlString = urlString
        self.bookmarkData = bookmarkData
    }
}

public enum WorkspaceMaterial: Equatable, Sendable, Codable {
    case layer(UUID)
    case node(UUID)
    case image(WorkspaceImageConfig)
    case outputViewport(UUID)
}

public struct WorkspaceOutputViewport: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var frame: CGRect
    public var formatID: String

    public init(
        id: UUID = UUID(),
        name: String = "Output",
        frame: CGRect,
        formatID: String = "workspace-output"
    ) {
        self.id = id
        self.name = name
        self.frame = frame
        self.formatID = formatID
    }
}

public struct WorkspaceFrame: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var name: String
    public var role: WorkspaceFrameRole
    public var material: WorkspaceMaterial
    public var localBounds: CGRect
    public var transform: WorkspaceAffineTransform
    public var cropRect: CGRect
    public var mask: MaskBinding?
    public var visible: Bool
    public var includeInOutput: Bool
    public var previewPolicy: WorkspacePreviewPolicy
    public var contentFit: WorkspaceContentFit
    public var opacity: Float
    public var blend: BlendMode
    public var bleed: CGFloat
    public var locked: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        role: WorkspaceFrameRole,
        material: WorkspaceMaterial,
        localBounds: CGRect,
        transform: WorkspaceAffineTransform = .identity,
        cropRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1),
        mask: MaskBinding? = nil,
        visible: Bool = true,
        includeInOutput: Bool = true,
        previewPolicy: WorkspacePreviewPolicy = .throttled,
        contentFit: WorkspaceContentFit = .stretch,
        opacity: Float = 1,
        blend: BlendMode = .normal,
        bleed: CGFloat = 0,
        locked: Bool = false
    ) {
        self.id = id
        self.name = name
        self.role = role
        self.material = material
        self.localBounds = localBounds
        self.transform = transform
        self.cropRect = cropRect
        self.mask = mask
        self.visible = visible
        self.includeInOutput = includeInOutput
        self.previewPolicy = previewPolicy
        self.contentFit = contentFit
        self.opacity = opacity
        self.blend = blend
        self.bleed = bleed
        self.locked = locked
    }

    public var worldBounds: CGRect {
        let local = localBounds.insetBy(dx: -bleed, dy: -bleed)
        let transform = transform.cgAffineTransform
        let points = [
            CGPoint(x: local.minX, y: local.minY),
            CGPoint(x: local.maxX, y: local.minY),
            CGPoint(x: local.maxX, y: local.maxY),
            CGPoint(x: local.minX, y: local.maxY)
        ].map { $0.applying(transform) }
        guard let first = points.first else { return .zero }
        return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { rect, point in
            rect.union(CGRect(origin: point, size: .zero))
        }
    }
}

public struct WorkspaceRenderRoute: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var sourceFrameID: UUID
    public var targetFrameID: UUID
    public var targetPort: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(),
        sourceFrameID: UUID,
        targetFrameID: UUID,
        targetPort: String = "texture",
        enabled: Bool = true
    ) {
        self.id = id
        self.sourceFrameID = sourceFrameID
        self.targetFrameID = targetFrameID
        self.targetPort = targetPort
        self.enabled = enabled
    }
}

public struct CollageWorkspace: Equatable, Sendable, Codable {
    public static let currentVersion = 1

    public var version: Int
    public var outputViewport: WorkspaceOutputViewport
    public var frames: [WorkspaceFrame]
    public var activeFrameID: UUID?
    public var selectedFrameIDs: [UUID]
    public var activeTool: WorkspaceTool
    public var viewCenter: CGPoint
    public var zoom: Double
    public var routes: [WorkspaceRenderRoute]
    public var secondaryOutputVisible: Bool

    public init(
        version: Int = CollageWorkspace.currentVersion,
        outputViewport: WorkspaceOutputViewport,
        frames: [WorkspaceFrame] = [],
        activeFrameID: UUID? = nil,
        selectedFrameIDs: [UUID] = [],
        activeTool: WorkspaceTool = .select,
        viewCenter: CGPoint = .zero,
        zoom: Double = 1,
        routes: [WorkspaceRenderRoute] = [],
        secondaryOutputVisible: Bool = false
    ) {
        self.version = version
        self.outputViewport = outputViewport
        self.frames = frames
        self.activeFrameID = activeFrameID
        self.selectedFrameIDs = selectedFrameIDs
        self.activeTool = activeTool
        self.viewCenter = viewCenter
        self.zoom = zoom
        self.routes = routes
        self.secondaryOutputVisible = secondaryOutputVisible
    }

    public func visibleOutputFrames() -> [WorkspaceFrame] {
        frames.filter {
            $0.visible &&
            $0.includeInOutput &&
            $0.role != .reference &&
            $0.role != .preview &&
            $0.worldBounds.intersects(outputViewport.frame)
        }
    }

    public func frame(id: UUID?) -> WorkspaceFrame? {
        guard let id else { return nil }
        return frames.first { $0.id == id }
    }

    public func containsRenderRouteCycle() -> Bool {
        var edges: [UUID: [UUID]] = [:]
        for route in routes where route.enabled {
            edges[route.sourceFrameID, default: []].append(route.targetFrameID)
        }
        var visiting = Set<UUID>()
        var visited = Set<UUID>()

        func visit(_ id: UUID) -> Bool {
            if visiting.contains(id) { return true }
            if visited.contains(id) { return false }
            visiting.insert(id)
            for next in edges[id] ?? [] {
                if visit(next) { return true }
            }
            visiting.remove(id)
            visited.insert(id)
            return false
        }

        return frames.contains { visit($0.id) }
    }

    public static func defaultWorkspace(graph: LayerGraph, outputSize: CGSize, formatID: String = "workspace-output") -> CollageWorkspace {
        let outputRect = CGRect(origin: .zero, size: outputSize)
        let output = WorkspaceOutputViewport(frame: outputRect, formatID: formatID)
        let frames = graph.layers.compactMap { layer -> WorkspaceFrame? in
            guard let node = graph.node(layer.node) else { return nil }
            let role: WorkspaceFrameRole = node.kind.family == "ink" ? .layer : .layer
            let bleed: CGFloat = node.kind.family == "ink" ? 96 : 0
            return WorkspaceFrame(
                id: layer.id,
                name: node.name,
                role: role,
                material: .layer(layer.id),
                localBounds: outputRect,
                mask: layer.mask,
                visible: layer.visible,
                includeInOutput: true,
                previewPolicy: .throttled,
                opacity: layer.opacity,
                blend: layer.blend,
                bleed: bleed
            )
        }
        return CollageWorkspace(
            outputViewport: output,
            frames: frames,
            activeFrameID: frames.first?.id,
            selectedFrameIDs: frames.first.map { [$0.id] } ?? [],
            activeTool: .select,
            viewCenter: CGPoint(x: outputRect.midX, y: outputRect.midY)
        )
    }
}

public extension ProcessingSettings {
    func resolvedWorkspace(outputSize: CGSize, formatID: String = "workspace-output") -> CollageWorkspace {
        if let workspace {
            return workspace
        }
        let graph = (layerGraph ?? LayerGraph.defaultGraph(from: self)).reconciled(with: self)
        return CollageWorkspace.defaultWorkspace(graph: graph, outputSize: outputSize, formatID: formatID)
    }
}
