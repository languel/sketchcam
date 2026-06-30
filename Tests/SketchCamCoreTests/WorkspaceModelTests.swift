import CoreGraphics
import XCTest
@testable import SketchCamCore

final class WorkspaceModelTests: XCTestCase {
    func testWorkspaceTypesRoundTripThroughCodable() throws {
        let frameID = UUID()
        let targetID = UUID()
        let workspace = CollageWorkspace(
            outputViewport: WorkspaceOutputViewport(frame: CGRect(x: 100, y: 50, width: 640, height: 360), formatID: "test"),
            frames: [
                WorkspaceFrame(
                    id: frameID,
                    name: "Reference",
                    role: .reference,
                    material: .image(WorkspaceImageConfig(urlString: "/tmp/ref.png")),
                    localBounds: CGRect(x: 0, y: 0, width: 320, height: 180),
                    transform: WorkspaceAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 24, ty: 48),
                    cropRect: CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.7),
                    mask: .person(invert: true),
                    visible: true,
                    includeInOutput: false,
                    previewPolicy: .boundsOnly,
                    contentFit: .fit,
                    opacity: 0.75,
                    blend: .multiply,
                    bleed: 12,
                    locked: true
                )
            ],
            activeFrameID: frameID,
            selectedFrameIDs: [frameID],
            activeTool: .transform,
            viewCenter: CGPoint(x: 12, y: 34),
            zoom: 1.5,
            routes: [WorkspaceRenderRoute(sourceFrameID: frameID, targetFrameID: targetID)]
        )

        let decoded = try JSONDecoder().decode(CollageWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(decoded, workspace)
    }

    func testLegacySettingsResolveDefaultWorkspaceFromLayerGraph() {
        var settings = ProcessingSettings()
        settings.landmarks.inkEnabled = true
        let graph = LayerGraph.defaultGraph(from: settings)
        settings.layerGraph = graph

        let workspace = settings.resolvedWorkspace(outputSize: CGSize(width: 1280, height: 720), formatID: "720p")

        XCTAssertEqual(workspace.outputViewport.frame.size, CGSize(width: 1280, height: 720))
        XCTAssertEqual(workspace.frames.count, graph.layers.count)
        XCTAssertEqual(workspace.frames.map(\.id), graph.layers.map(\.id))
        XCTAssertTrue(workspace.frames.allSatisfy { $0.includeInOutput })
        XCTAssertTrue(workspace.frames.contains { frame in
            guard case .layer(let id) = frame.material,
                  let layer = graph.layers.first(where: { $0.id == id }),
                  let node = graph.node(layer.node) else { return false }
            return node.kind.family == "ink" && frame.bleed > 0
        })
    }

    func testOutputFrameCullingIgnoresReferencePreviewAndOffViewportFrames() {
        let output = WorkspaceOutputViewport(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let visible = WorkspaceFrame(
            id: UUID(),
            name: "Visible",
            role: .layer,
            material: .node(UUID()),
            localBounds: CGRect(x: 0, y: 0, width: 50, height: 50)
        )
        let offscreen = WorkspaceFrame(
            id: UUID(),
            name: "Off",
            role: .layer,
            material: .node(UUID()),
            localBounds: CGRect(x: 0, y: 0, width: 50, height: 50),
            transform: .translation(x: 500, y: 0)
        )
        let reference = WorkspaceFrame(
            id: UUID(),
            name: "Reference",
            role: .reference,
            material: .node(UUID()),
            localBounds: CGRect(x: 0, y: 0, width: 50, height: 50)
        )
        let workspace = CollageWorkspace(outputViewport: output, frames: [visible, offscreen, reference])

        XCTAssertEqual(workspace.visibleOutputFrames().map(\.id), [visible.id])
    }

    func testRenderRouteCycleDetection() {
        let a = WorkspaceFrame(name: "A", role: .layer, material: .node(UUID()), localBounds: CGRect(x: 0, y: 0, width: 1, height: 1))
        let b = WorkspaceFrame(name: "B", role: .layer, material: .node(UUID()), localBounds: CGRect(x: 0, y: 0, width: 1, height: 1))

        let acyclic = CollageWorkspace(
            outputViewport: WorkspaceOutputViewport(frame: CGRect(x: 0, y: 0, width: 1, height: 1)),
            frames: [a, b],
            routes: [WorkspaceRenderRoute(sourceFrameID: a.id, targetFrameID: b.id)]
        )
        XCTAssertFalse(acyclic.containsRenderRouteCycle())

        let cyclic = CollageWorkspace(
            outputViewport: acyclic.outputViewport,
            frames: [a, b],
            routes: [
                WorkspaceRenderRoute(sourceFrameID: a.id, targetFrameID: b.id),
                WorkspaceRenderRoute(sourceFrameID: b.id, targetFrameID: a.id)
            ]
        )
        XCTAssertTrue(cyclic.containsRenderRouteCycle())
    }

    func testImageNodeHasNoPortsAndRoundTrips() throws {
        let node = Node(name: "Image", kind: .image(WorkspaceImageConfig(urlString: "/tmp/ref.png")), managed: false)
        XCTAssertTrue(node.kind.ports.isEmpty)
        XCTAssertTrue(node.kind.defaultBindings.isEmpty)
        let graph = LayerGraph(nodes: [node], layers: [Layer(node: node.id)])
        XCTAssertEqual(try JSONDecoder().decode(LayerGraph.self, from: JSONEncoder().encode(graph)), graph)
    }
}
