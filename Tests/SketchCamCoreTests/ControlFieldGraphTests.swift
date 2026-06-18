import XCTest
@testable import SketchCamCore

final class ControlFieldGraphTests: XCTestCase {
    private let paperID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let trackedID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let flowID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func testValidScalarAndVectorRoutes() throws {
        let paper = ControlFieldProvider(id: paperID, name: "Paper", kind: .paper)
        let motion = ControlFieldProvider(id: flowID, name: "Flow", kind: .opticalFlow)
        let graph = ControlFieldGraph(
            providers: [paper, motion],
            routes: [
                ControlFieldRoute(
                    consumer: .ink,
                    input: .absorbency,
                    source: .init(provider: paperID, output: .paperAbsorbency)
                ),
                ControlFieldRoute(
                    consumer: .ink,
                    input: .motionVector,
                    source: .init(provider: flowID, output: .motionVector)
                )
            ]
        )
        XCTAssertNoThrow(try graph.validate())
    }

    func testRejectsMismatchedRouteKind() {
        let paper = ControlFieldProvider(id: paperID, name: "Paper", kind: .paper)
        let route = ControlFieldRoute(
            consumer: .ink,
            input: .motionVector,
            source: .init(provider: paperID, output: .paperAbsorbency)
        )
        let graph = ControlFieldGraph(providers: [paper], routes: [route])

        XCTAssertThrowsError(try graph.validate()) {
            XCTAssertEqual($0 as? ControlFieldGraphError, .kindMismatch(route: route.id))
        }
    }

    func testRejectsDanglingProvider() {
        let missing = UUID()
        let route = ControlFieldRoute(
            consumer: .ink,
            input: .drag,
            source: .init(provider: missing, output: .paperDrag)
        )
        XCTAssertThrowsError(try ControlFieldGraph(routes: [route]).validate()) {
            XCTAssertEqual($0 as? ControlFieldGraphError, .danglingProvider(provider: missing))
        }
    }

    func testRejectsUnavailableProviderOutput() {
        let tracked = ControlFieldProvider(id: trackedID, name: "Tracked", kind: .trackedMotion)
        let route = ControlFieldRoute(
            consumer: .ink,
            input: .absorbency,
            source: .init(provider: trackedID, output: .paperAbsorbency)
        )
        XCTAssertThrowsError(try ControlFieldGraph(providers: [tracked], routes: [route]).validate()) {
            XCTAssertEqual(
                $0 as? ControlFieldGraphError,
                .unavailableOutput(provider: trackedID, output: .paperAbsorbency)
            )
        }
    }

    func testRejectsProviderCycle() {
        let a = ControlFieldProvider(
            id: trackedID,
            name: "A",
            kind: .combinedMotion,
            inputs: [.init(provider: flowID, output: .motionVector)]
        )
        let b = ControlFieldProvider(
            id: flowID,
            name: "B",
            kind: .combinedMotion,
            inputs: [.init(provider: trackedID, output: .motionVector)]
        )
        XCTAssertThrowsError(try ControlFieldGraph(providers: [a, b]).validate()) {
            XCTAssertEqual($0 as? ControlFieldGraphError, .cycle)
        }
    }

    func testCodableRoundTripAndLegacySettingsDefault() throws {
        let provider = ControlFieldProvider(
            id: paperID,
            name: "Paper",
            kind: .paper,
            quality: .high
        )
        let graph = ControlFieldGraph(providers: [provider])
        let data = try JSONEncoder().encode(graph)
        XCTAssertEqual(try JSONDecoder().decode(ControlFieldGraph.self, from: data), graph)

        var legacyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(ProcessingSettings())) as? [String: Any]
        )
        legacyObject.removeValue(forKey: "controlFields")
        let legacy = try JSONDecoder().decode(
            ProcessingSettings.self,
            from: JSONSerialization.data(withJSONObject: legacyObject)
        )
        XCTAssertEqual(legacy.resolvedControlFields, .empty)
    }

    func testMotionAndInkInfluenceDefaultsAreDisabled() {
        let motion = MotionControlConfig()
        XCTAssertFalse(motion.enabled)
        XCTAssertEqual(motion.mode, .combined)
        XCTAssertEqual(motion.input, .camera)

        let ink = LandmarkSettings()
        XCTAssertEqual(ink.resolvedInkPaperInfluence, 0)
        XCTAssertEqual(ink.resolvedInkLiveSurfaceInfluence, 0)
        XCTAssertEqual(ink.resolvedInkMotionForce, 0)
        XCTAssertEqual(ink.resolvedInkLiveAbsorbency, 0)
        XCTAssertEqual(ink.resolvedInkLiveDrag, 0.5)
        XCTAssertEqual(ink.resolvedInkLiveResist, 1)
    }

    func testProviderPaperAndMotionSettingsRoundTrip() throws {
        let nodeID = UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!
        let motion = MotionControlConfig(
            enabled: true,
            mode: .opticalFlow,
            input: .movie,
            sensitivity: 1.4,
            threshold: 0.08,
            smoothing: 0.5,
            decay: 0.9,
            spatialScale: 0.75,
            maximumForce: 1.8
        )
        let providers = [
            ControlFieldProvider(id: paperID, name: "Paper", kind: .paper, paperNodeID: nodeID),
            ControlFieldProvider(id: flowID, name: "Motion", kind: .opticalFlow, motionConfig: motion)
        ]
        let data = try JSONEncoder().encode(providers)
        XCTAssertEqual(try JSONDecoder().decode([ControlFieldProvider].self, from: data), providers)
        XCTAssertEqual(providers[0].paperNodeID, nodeID)
        XCTAssertEqual(providers[1].resolvedMotionConfig, motion)
    }
}
