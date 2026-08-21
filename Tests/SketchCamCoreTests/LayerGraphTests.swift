import XCTest
@testable import SketchCamCore

/// Phase 1: the layer/routing graph model, validation, scheduling, and the
/// legacy→graph migration. No rendering yet.
final class LayerGraphTests: XCTestCase {
    func testInkCanvasStateCommandRevisionsRoundTrip() throws {
        var settings = ProcessingSettings()
        XCTAssertEqual(settings.landmarks.inkFixRevision, 0)
        XCTAssertEqual(settings.landmarks.inkUnfixRevision, 0)
        XCTAssertEqual(settings.landmarks.inkWetCanvasRevision, 0)
        XCTAssertEqual(settings.landmarks.inkDryCanvasRevision, 0)

        settings.landmarks.inkFixRevision = 1
        settings.landmarks.inkUnfixRevision = 2
        settings.landmarks.inkWetCanvasRevision = 3
        settings.landmarks.inkDryCanvasRevision = 4

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ProcessingSettings.self, from: data)
        XCTAssertEqual(decoded.landmarks.inkFixRevision, 1)
        XCTAssertEqual(decoded.landmarks.inkUnfixRevision, 2)
        XCTAssertEqual(decoded.landmarks.inkWetCanvasRevision, 3)
        XCTAssertEqual(decoded.landmarks.inkDryCanvasRevision, 4)
    }

    func testSettingsWithoutPortraitFieldsUsePortraitDefaults() throws {
        let encoded = try JSONEncoder().encode(ProcessingSettings())
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var landmarks = try XCTUnwrap(root["landmarks"] as? [String: Any])
        for key in [
            "portraitEnabled", "portraitStyle", "portraitFollow", "portraitFlourish",
            "portraitWidth", "portraitWidthVariation", "portraitHalo", "portraitColor",
            "portraitSeed", "portraitVariation", "portraitRouteVariation",
            "portraitSegments", "portraitConnectorWidth",
            "portraitOutlineEnabled", "portraitOutlineStrength", "portraitHairEnabled",
            "portraitHairStyle", "portraitHairAmount", "portraitUnifiedRoute",
            "portraitDetailPriority", "portraitSubsample",
        ] {
            landmarks.removeValue(forKey: key)
        }
        root["landmarks"] = landmarks

        let legacyData = try JSONSerialization.data(withJSONObject: root)
        let decoded = try JSONDecoder().decode(ProcessingSettings.self, from: legacyData)

        XCTAssertFalse(decoded.landmarks.resolvedPortraitEnabled)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitStyle, .fluid)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitFollow, 0.72)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitFlourish, 0.2)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitWidth, 2.8)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitWidthVariation, 0.45)
        XCTAssertFalse(decoded.landmarks.resolvedPortraitHalo)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitColor, .ink)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitSeed, 7)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitVariation, 0.22)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitRouteVariation, 0.38)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitSegments, 1)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitConnectorWidth, 0.42)
        XCTAssertFalse(decoded.landmarks.resolvedPortraitOutlineEnabled)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitOutlineStrength, 0.68)
        XCTAssertFalse(decoded.landmarks.resolvedPortraitUnifiedRoute)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitDetailPriority, 0.65)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitSubsample, 1)
        XCTAssertFalse(decoded.landmarks.resolvedPortraitHairEnabled)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitHairStyle, .clean)
        XCTAssertEqual(decoded.landmarks.resolvedPortraitHairAmount, 0.45)
    }

    func testFreshSettingsStartWithCameraThresholdOnly() throws {
        let settings = ProcessingSettings()
        XCTAssertTrue(settings.thresholdEnabled)
        XCTAssertFalse(settings.outlineEnabled)

        let graph = LayerGraph.defaultGraph(from: settings)
        XCTAssertEqual(graph.layers.count, 1)
        let camera = try XCTUnwrap(graph.layers.first)
        XCTAssertEqual(graph.node(camera.node)?.kind, .video)
        XCTAssertEqual(camera.effects.map(\.kind), [.threshold])
    }

    func testEnablingDrawingKeepsItAboveDuplicateUserCameras() {
        var disabled = ProcessingSettings()
        disabled.landmarks.enabled = true
        disabled.landmarks.showDots = false
        disabled.landmarks.showStick = false
        disabled.landmarks.yarnEnabled = false
        disabled.landmarks.wrapEnabled = false
        disabled.landmarks.lineWalkEnabled = false
        disabled.landmarks.portraitEnabled = false

        let cameraOne = Node(name: "Camera 1", kind: .video, managed: false)
        let cameraTwo = Node(name: "Camera 2", kind: .video, managed: false)
        let graph = LayerGraph(
            nodes: [cameraOne, cameraTwo],
            layers: [Layer(node: cameraOne.id), Layer(node: cameraTwo.id)]
        )

        var enabled = disabled
        enabled.landmarks.showStick = true
        let reconciled = graph.reconciled(with: enabled)

        XCTAssertEqual(reconciled.layers.map { reconciled.node($0.node)?.name }, ["Camera 1", "Camera 2", "Drawing"])
    }

    func testAcrylicDefaultsAndBodyMacro() throws {
        var config = AcrylicConfig()
        XCTAssertEqual(config.body, 0.5)
        XCTAssertEqual(config.mixModel, .pigment)
        config.applyBody(0)
        XCTAssertEqual(config.viscosity, 0.1, accuracy: 0.0001)
        config.applyBody(1)
        XCTAssertEqual(config.viscosity, 0.95, accuracy: 0.0001)
        let decoded = try JSONDecoder().decode(AcrylicConfig.self, from: JSONEncoder().encode(config))
        XCTAssertEqual(decoded, config)
    }

    func testAcrylicNodePortsAndRoundTrip() throws {
        let node = Node(name: "Acrylic", kind: .acrylic(AcrylicConfig()), managed: false)
        XCTAssertEqual(node.kind.ports.map(\.type), [.path, .pixel])
        let graph = LayerGraph(nodes: [node], layers: [Layer(node: node.id)])
        XCTAssertEqual(try JSONDecoder().decode(LayerGraph.self, from: JSONEncoder().encode(graph)), graph)
    }

    // MARK: - Kind invariants

    func testEveryKindHasMatchingDefaultBindings() {
        let kinds: [NodeKind] = [.video, .movie, .solid(SolidConfig()), .paper(PaperConfig()), .personMatte,
                                 .effect, .marks,
                                 .drawing(.yarn), .drawing(.wrap), .drawing(.lineWalk), .drawing(.portrait),
                                 .ink, .web, .image(WorkspaceImageConfig(urlString: "/tmp/reference.png"))]
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

    func testMetalPaperDefaultsMatchOriginalShader() {
        let paper = PaperConfig.metalDefault.resolved
        XCTAssertEqual(paper.tintRed, 0.962, accuracy: 0.0001)
        XCTAssertEqual(paper.tintGreen, 0.954, accuracy: 0.0001)
        XCTAssertEqual(paper.tintBlue, 0.930, accuracy: 0.0001)
        XCTAssertEqual(paper.fiberStrength, 0.05, accuracy: 0.0001)
        XCTAssertEqual(paper.fiberScaleX, 0.055, accuracy: 0.0001)
        XCTAssertEqual(paper.toothStrength, 0.022, accuracy: 0.0001)
        XCTAssertEqual(paper.toothScaleX, 0.42, accuracy: 0.0001)
        XCTAssertEqual(paper.grainStrength, 0.45, accuracy: 0.0001)
        XCTAssertEqual(paper.grainScaleX, 0.12, accuracy: 0.0001)
        XCTAssertEqual(paper.vignetteStrength, 0.16, accuracy: 0.0001)
        XCTAssertEqual(paper.saturation, 1, accuracy: 0.0001)
    }

    func testLegacyPaperConfigDecodesWithResolvedDefaults() throws {
        let json = #"{"tint":{"red":0.94,"green":0.92,"blue":0.86,"alpha":1},"grain":0.6,"scale":2,"texture":"fiber"}"#
        let paper = try JSONDecoder().decode(PaperConfig.self, from: Data(json.utf8))
        XCTAssertEqual(paper.resolved.grainStrength, 0.6, accuracy: 0.0001)
        XCTAssertEqual(paper.resolved.fiberScaleX, 0.0275, accuracy: 0.0001)
        XCTAssertEqual(paper.resolved.seed, 0)
        XCTAssertEqual(paper.resolved.saturation, 1, accuracy: 0.0001)
        XCTAssertEqual(paper.resolved.response, 1, accuracy: 0.0001)
        XCTAssertEqual(paper.resolved.variation, 1, accuracy: 0.0001)
        XCTAssertEqual(paper.resolved.absorbency, 1, accuracy: 0.0001)
        XCTAssertEqual(paper.resolved.drag, 1, accuracy: 0.0001)
        XCTAssertEqual(paper.resolved.resist, 1, accuracy: 0.0001)
        XCTAssertEqual(paper.resolved.resistThreshold, 0.5, accuracy: 0.0001)
        XCTAssertEqual(paper.resolved.resistSoftness, 0.1, accuracy: 0.0001)
    }

    func testPaperPhysicalResponseRoundTrips() throws {
        let paper = PaperConfig(
            response: 0.75,
            variation: 1.6,
            absorbency: 0.4,
            drag: 0.8,
            resist: 0.3,
            resistThreshold: 0.62,
            resistSoftness: 0.08
        )
        let decoded = try JSONDecoder().decode(PaperConfig.self, from: JSONEncoder().encode(paper))
        XCTAssertEqual(decoded, paper)
        XCTAssertEqual(decoded.resolved.response, 0.75, accuracy: 0.0001)
        XCTAssertEqual(decoded.resolved.variation, 1.6, accuracy: 0.0001)
    }

    func testCodableRoundTripWithEffectsAndStreamMask() throws {
        // A solid used as a threshold mask on a camera layer carrying an effect chain.
        let cam = Node(name: "Camera", kind: .video)
        let maskSrc = Node(name: "Solid", kind: .solid(SolidConfig()), managed: false)
        let layer = Layer(node: cam.id,
                          mask: MaskBinding(source: .node(maskSrc.id), mode: .threshold, level: 0.3, invert: true,
                                            personKeyInvert: true, personKeySilhouette: true,
                                            personKeyColor: RGBAColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)),
                          effects: [EffectConfig(kind: .threshold, amount: 0.4),
                                    EffectConfig(kind: .blur, amount: 3)])
        let g = LayerGraph(nodes: [cam, maskSrc], layers: [layer])
        XCTAssertNoThrow(try g.validate())
        let decoded = try JSONDecoder().decode(LayerGraph.self, from: try JSONEncoder().encode(g))
        XCTAssertEqual(decoded, g)
        XCTAssertEqual(decoded.layers.first?.effects.count, 2)
        XCTAssertEqual(decoded.layers.first?.mask?.mode, .threshold)
        XCTAssertEqual(decoded.layers.first?.mask?.personKeyColor.alpha, 0.8)
    }

    func testPatternEffectsRoundTripTheirParametricControls() throws {
        XCTAssertEqual(EffectConfig(kind: .levels).levelGain, 1)
        XCTAssertEqual(EffectConfig(kind: .levels).levelSoftClip, 0.2)
        XCTAssertEqual(EffectConfig(kind: .blueNoiseStipple).patternDotResponse, 0)
        XCTAssertTrue(EffectKind.duotone.usesAmount)
        let experimental = EffectConfig(kind: .blueNoiseStipple, amount: 1.8,
                                         thickness: 24, patternScale: 64,
                                         patternSampling: 1.75, patternDotResponse: 2.2)
        let experimentalDecoded = try JSONDecoder().decode(
            EffectConfig.self, from: JSONEncoder().encode(experimental)
        )
        XCTAssertEqual(experimentalDecoded, experimental)
        XCTAssertTrue(EffectConfig(kind: .blueNoiseStipple).transparentBackground)
        XCTAssertTrue(EffectConfig(kind: .stipple).transparentBackground)
        XCTAssertTrue(EffectConfig(kind: .stripes).transparentBackground)
        XCTAssertTrue(EffectConfig(kind: .pixelate).transparentBackground)
        XCTAssertEqual(EffectConfig(kind: .stripes).patternVariationScale, 1)
        XCTAssertEqual(EffectConfig(kind: .stripes).patternStripeResponse, 1)
        XCTAssertEqual(EffectConfig(kind: .stripes).patternStripeBleed, 0.5)
        let effects = [
            EffectConfig(kind: .levels, levelBlack: 0.08, levelWhite: 0.92,
                         levelGamma: 1.4, levelGain: 1.8, levelSoftClip: 0.35),
            EffectConfig(kind: .blueNoiseStipple, amount: 0.78, thickness: 2.5,
                         patternScale: 10, patternSoftness: 0.25,
                         patternSampling: 0.7, patternDotResponse: 0.85),
            EffectConfig(kind: .stipple, amount: 0.7, thickness: 3.5,
                         invert: true, patternScale: 9, patternSoftness: 0.2,
                         patternSampling: 0.8,
                         backgroundColor: RGBAColor(red: 0.9, green: 0.8, blue: 0.7, alpha: 1),
                         transparentBackground: true),
            EffectConfig(kind: .stripes, amount: 0.8, thickness: 6,
                         patternScale: 18, patternAngle: 0.4, patternSoftness: 0.3,
                         patternSampling: 0.65, patternVariationScale: 2.4,
                         patternStripeResponse: 1.8, patternStripeBleed: 0.85,
                         transparentBackground: false),
            EffectConfig(kind: .pixelate, amount: 0.9, thickness: 2,
                         patternScale: 7, patternSoftness: 0.6),
            EffectConfig(kind: .duotone, amount: 0.9,
                         color: RGBAColor(red: 0.1, green: 0.02, blue: 0.15, alpha: 1),
                         levelBlack: 0.08, levelWhite: 0.94, levelGamma: 1.25,
                         backgroundColor: RGBAColor(red: 0.95, green: 0.8, blue: 0.45, alpha: 1)),
        ]
        let camera = Node(name: "Camera", kind: .video)
        let graph = LayerGraph(nodes: [camera], layers: [Layer(node: camera.id, effects: effects)])
        let decoded = try JSONDecoder().decode(LayerGraph.self, from: JSONEncoder().encode(graph))
        XCTAssertEqual(decoded, graph)
        XCTAssertEqual(Array(EffectKind.allCases.suffix(3)), [.stipple, .stripes, .pixelate])
    }

    func testMaskWithPathSourceThrows() {
        var cam = Node(name: "Camera", kind: .video)
        cam.inputs = [.source(.camera)]
        var layer = Layer(node: cam.id)
        layer.mask = MaskBinding(source: .source(.mouse))   // path source as a matte ✗
        let g = LayerGraph(nodes: [cam], layers: [layer])
        XCTAssertThrowsError(try g.validate())
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
        XCTAssertEqual(kinds.first?.family, "video", "v2: the Camera is the bottom layer (no global background)")
        XCTAssertTrue(kinds.contains(.overlay), "marks+drawing collapse to one overlay layer")
        XCTAssertTrue(kinds.contains(.ink))

        // v2: person key is a per-layer effect on the camera, not a global mask.
        let cameraLayer = g.layers.first { g.node($0.node)?.kind == .video }
        XCTAssertTrue(cameraLayer?.effects.contains { $0.kind == .personKey } ?? false,
                      "segmentation seeds a Person Key effect on the camera layer")
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

    func testReconcilePreservesUserCreatedSolid() throws {
        var s = ProcessingSettings()
        s.landmarks.inkEnabled = true
        var g = LayerGraph.defaultGraph(from: s)   // video + ink (both managed)
        // User adds a freeform solid on top (unmanaged).
        let solid = Node(name: "Solid", kind: .solid(SolidConfig(color: .white)), managed: false)
        g.nodes.append(solid)
        g.layers.append(Layer(node: solid.id))
        // Toggle a managed feature; the user-created solid must survive.
        s.web.enabled = true
        let r = g.reconciled(with: s)
        XCTAssertNoThrow(try r.validate())
        XCTAssertTrue(r.layers.contains { $0.id == g.layers.last!.id }, "user solid preserved")
        XCTAssertTrue(r.layers.contains { r.node($0.node)?.kind.family == "web" }, "new web added")
    }

    func testReconcileDoesNotAddManagedInkWhenUserInkExists() throws {
        var s = ProcessingSettings()
        s.landmarks.inkEnabled = true
        let camera = Node(name: "Camera", kind: .video)
        let ink1 = Node(name: "Ink 1", kind: .ink, managed: false)
        let ink2 = Node(name: "Ink 2", kind: .ink, managed: false)
        let g = LayerGraph(
            nodes: [camera, ink1, ink2],
            layers: [Layer(node: camera.id), Layer(node: ink1.id), Layer(node: ink2.id)]
        )

        let r = g.reconciled(with: s)

        XCTAssertNoThrow(try r.validate())
        let inkNodes = r.nodes.filter { $0.kind.family == "ink" }
        XCTAssertEqual(inkNodes.count, 2)
        XCTAssertTrue(inkNodes.allSatisfy { !$0.managed })
        XCTAssertEqual(Set(inkNodes.map(\.name)), ["Ink 1", "Ink 2"])
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
