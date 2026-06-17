import XCTest
@testable import SketchCamCore

/// Phase 1: the layer/routing graph model, validation, scheduling, and the
/// legacy→graph migration. No rendering yet.
final class LayerGraphTests: XCTestCase {

    // MARK: - Kind invariants

    func testEveryKindHasMatchingDefaultBindings() {
        let kinds: [NodeKind] = [.video, .solid, .effect, .marks,
                                 .drawing(.yarn), .drawing(.wrap), .drawing(.lineWalk),
                                 .ink, .web]
        for kind in kinds {
            XCTAssertEqual(kind.ports.count, kind.defaultBindings.count,
                           "ports and defaultBindings must align for \(kind)")
        }
    }

    func testNodeDefaultsToKindBindings() {
        let n = Node(name: "Ink", kind: .ink)
        XCTAssertEqual(n.inputs, NodeKind.ink.defaultBindings)
        XCTAssertEqual(n.inputs.count, 2) // strokes + texture
    }

    // MARK: - Validation

    func testValidGraphValidates() throws {
        let cam = Node(name: "Camera", kind: .video)
        let ink = Node(name: "Ink", kind: .ink)
        let g = LayerGraph(nodes: [cam, ink],
                           layers: [Layer(node: cam.id), Layer(node: ink.id)])
        XCTAssertNoThrow(try g.validate())
    }

    func testSignalTypeMismatchThrows() {
        // ink.texture is a pixel port; binding it to a path source must fail.
        var ink = Node(name: "Ink", kind: .ink)
        ink.inputs = [.source(.mouse), .source(.mouse)] // texture ← mouse(path) ✗
        let g = LayerGraph(nodes: [ink], layers: [Layer(node: ink.id)])
        XCTAssertThrowsError(try g.validate()) { error in
            XCTAssertEqual(error as? LayerGraphError, .signalTypeMismatch(node: ink.id, port: "texture"))
        }
    }

    func testPortCountMismatchThrows() {
        var ink = Node(name: "Ink", kind: .ink)
        ink.inputs = [.source(.mouse)] // missing texture binding
        let g = LayerGraph(nodes: [ink], layers: [])
        XCTAssertThrowsError(try g.validate()) { error in
            XCTAssertEqual(error as? LayerGraphError, .portCountMismatch(node: ink.id))
        }
    }

    func testDanglingNodeBindingThrows() {
        var ink = Node(name: "Ink", kind: .ink)
        ink.inputs = [.source(.mouse), .node(UUID())] // texture ← nonexistent node
        let g = LayerGraph(nodes: [ink], layers: [])
        XCTAssertThrowsError(try g.validate()) { error in
            XCTAssertEqual(error as? LayerGraphError, .danglingBinding(node: ink.id, port: "texture"))
        }
    }

    // MARK: - Routing + scheduling

    func testRoutingWebIntoInkTextureValidatesAndOrders() throws {
        // The north-star route: ink.texture ← web output.
        let web = Node(name: "Web", kind: .web)
        var ink = Node(name: "Ink", kind: .ink)
        ink.inputs = [.source(.mouse), .node(web.id)]
        let g = LayerGraph(nodes: [ink, web], // deliberately out of order
                           layers: [Layer(node: web.id), Layer(node: ink.id)])
        XCTAssertNoThrow(try g.validate())
        let order = try g.topologicallySortedNodeIDs()
        XCTAssertLessThan(order.firstIndex(of: web.id)!, order.firstIndex(of: ink.id)!,
                          "web must be scheduled before ink that depends on it")
    }

    func testCycleThrows() {
        // Two effect nodes feeding each other.
        var a = Node(name: "A", kind: .effect)
        var b = Node(name: "B", kind: .effect)
        a.inputs = [.node(b.id)]
        b.inputs = [.node(a.id)]
        let g = LayerGraph(nodes: [a, b], layers: [])
        XCTAssertThrowsError(try g.topologicallySortedNodeIDs()) { error in
            XCTAssertEqual(error as? LayerGraphError, .cycle)
        }
    }

    // MARK: - Codable

    func testCodableRoundTrip() throws {
        let web = Node(name: "Web", kind: .web)
        var ink = Node(name: "Ink", kind: .ink)
        ink.inputs = [.source(.mouse), .node(web.id)]
        let g = LayerGraph(nodes: [web, ink],
                           layers: [Layer(node: web.id, opacity: 0.5, blend: .multiply),
                                    Layer(node: ink.id, mask: .person(invert: true))])
        let data = try JSONEncoder().encode(g)
        let decoded = try JSONDecoder().decode(LayerGraph.self, from: data)
        XCTAssertEqual(decoded, g)
    }

    // MARK: - Migration

    func testDefaultSettingsMigratesToSingleCameraLayer() throws {
        let g = LayerGraph.defaultGraph(from: ProcessingSettings())
        XCTAssertNoThrow(try g.validate())
        XCTAssertEqual(g.layers.count, 1)
        XCTAssertEqual(g.node(g.layers[0].node)?.kind, .video)
    }

    func testMigrationIncludesEnabledFeaturesAndMasks() throws {
        var s = ProcessingSettings()
        s.backgroundMode = .solid
        s.segmentation.enabled = true
        s.landmarks.enabled = true
        s.landmarks.showStick = true
        s.landmarks.lineWalkEnabled = true
        s.landmarks.inkEnabled = true
        s.landmarks.inkPlacement = .aboveDrawing
        let g = LayerGraph.defaultGraph(from: s)
        XCTAssertNoThrow(try g.validate())

        let kinds = g.layers.compactMap { g.node($0.node)?.kind }
        XCTAssertEqual(kinds.first, .solid, "solid background sits at the bottom")
        XCTAssertTrue(kinds.contains(.marks))
        XCTAssertTrue(kinds.contains(.drawing(.lineWalk)))
        XCTAssertTrue(kinds.contains(.ink))

        // Camera + content layers are masked to the person when segmentation is on.
        let cameraLayer = g.layers.first { g.node($0.node)?.kind == .video }
        XCTAssertEqual(cameraLayer?.mask, .person(invert: false))
    }

    func testInkPlacementOrdersRelativeToDrawing() throws {
        func inkVsDrawingOrder(_ placement: WebLayerPlacement) -> (ink: Int, draw: Int) {
            var s = ProcessingSettings()
            s.landmarks.enabled = true
            s.landmarks.lineWalkEnabled = true
            s.landmarks.inkEnabled = true
            s.landmarks.inkPlacement = placement
            let g = LayerGraph.defaultGraph(from: s)
            let inkIdx = g.layers.firstIndex { g.node($0.node)?.kind == .ink }!
            let drawIdx = g.layers.firstIndex { g.node($0.node)?.kind == .drawing(.lineWalk) }!
            return (inkIdx, drawIdx)
        }
        let above = inkVsDrawingOrder(.aboveDrawing)
        XCTAssertGreaterThan(above.ink, above.draw, "aboveDrawing → ink stacks after the drawing")
        let behind = inkVsDrawingOrder(.behindDrawing)
        XCTAssertLessThan(behind.ink, behind.draw, "behindDrawing → ink stacks before the drawing")
    }
}
