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
        XCTAssertTrue(kinds.contains(.overlay), "marks+drawing collapse to one overlay layer")
        XCTAssertTrue(kinds.contains(.ink))

        // Camera + content layers are masked to the person when segmentation is on.
        let cameraLayer = g.layers.first { g.node($0.node)?.kind == .video }
        XCTAssertEqual(cameraLayer?.mask, .person(invert: false))
    }

    // MARK: - Reconciliation (user edits vs feature toggles)

    func testReconcilePreservesUserOrderAndDropsDisabled() throws {
        var s = ProcessingSettings()
        s.landmarks.enabled = true
        s.landmarks.showStick = true        // overlay
        s.landmarks.inkEnabled = true       // ink
        s.web.enabled = true                // web
        var g = LayerGraph.defaultGraph(from: s)

        // User reverses the movable layers' order and hides one.
        g.layers.reverse()
        let hiddenKind = g.node(g.layers[0].node)!.kind
        g.layers[0].visible = false
        let userOrder = g.layers.compactMap { g.node($0.node)?.kind }

        // Turn web OFF → its layer must drop, the rest keep the user's order.
        s.web.enabled = false
        let r = g.reconciled(with: s)
        XCTAssertNoThrow(try r.validate())
        let kinds = r.layers.compactMap { r.node($0.node)?.kind }
        XCTAssertFalse(kinds.contains(.web), "disabled feature's layer is dropped")
        XCTAssertEqual(kinds, userOrder.filter { $0 != .web }, "user order preserved")
        // Visibility carried over.
        if hiddenKind != .web {
            XCTAssertEqual(r.layers.first { r.node($0.node)?.kind == hiddenKind }?.visible, false)
        }
    }

    func testReconcileAppendsNewlyEnabledFeature() throws {
        var s = ProcessingSettings()
        s.landmarks.enabled = true
        s.landmarks.showStick = true
        let g = LayerGraph.defaultGraph(from: s)   // video + overlay
        s.landmarks.inkEnabled = true              // enable ink after the fact
        let r = g.reconciled(with: s)
        XCTAssertNoThrow(try r.validate())
        XCTAssertTrue(r.layers.contains { r.node($0.node)?.kind == .ink }, "newly enabled ink appears")
    }

    func testInkLayerIndependentOfMarksMaster() throws {
        // Ink enabled but the landmarks/Marks master OFF must still yield an ink layer.
        var s = ProcessingSettings()
        s.landmarks.enabled = false
        s.landmarks.inkEnabled = true
        let g = LayerGraph.defaultGraph(from: s)
        XCTAssertTrue(g.layers.contains { g.node($0.node)?.kind == .ink },
                      "ink is independent of the Marks master toggle")
        XCTAssertFalse(g.layers.contains { g.node($0.node)?.kind == .overlay },
                       "no drawing/marks overlay when the master is off")
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
            let drawIdx = g.layers.firstIndex { g.node($0.node)?.kind == .overlay }!
            return (inkIdx, drawIdx)
        }
        let above = inkVsDrawingOrder(.aboveDrawing)
        XCTAssertGreaterThan(above.ink, above.draw, "aboveDrawing → ink stacks after the drawing")
        let behind = inkVsDrawingOrder(.behindDrawing)
        XCTAssertLessThan(behind.ink, behind.draw, "behindDrawing → ink stacks before the drawing")
    }
}
