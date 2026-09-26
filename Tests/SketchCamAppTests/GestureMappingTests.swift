import XCTest
import SketchCamCore
@testable import SketchCam

final class GestureMappingTests: XCTestCase {
    let screen = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    func mapping(_ destination: MotionControlDestination = .computer) -> SystemPointerMapping {
        var m = SystemPointerMapping()
        m.destination = destination
        m.gestureRules = destination == .canvas ? GestureRule.canvas : GestureRule.computer
        m.smoothing = 0
        m.horizontalCoverage = 1; m.verticalCoverage = 1
        return m
    }
    func hand(_ gesture: HandGesture, confidence: Float = 1) -> LandmarkDetection {
        var points = [LandmarkPoint(point: CGPoint(x: 0.5, y: 0.2), confidence: confidence, label: "R0"),
                      LandmarkPoint(point: CGPoint(x: 0.5, y: 0.4), confidence: confidence, label: "R9")]
        for (i, tip) in [8, 12, 16, 20].enumerated() {
            let x = 0.45 + Double(i) * 0.035
            points.append(LandmarkPoint(point: CGPoint(x: x, y: 0.48), confidence: confidence, label: "R\(tip - 2)"))
            points.append(LandmarkPoint(point: CGPoint(x: x, y: gesture == .fist ? 0.32 : 0.65), confidence: confidence, label: "R\(tip)"))
        }
        points.append(LandmarkPoint(point: CGPoint(x: gesture == .pinch ? 0.46 : 0.3, y: 0.65), confidence: confidence, label: "R4"))
        return LandmarkDetection(groups: [LandmarkGroup(region: .hands, points: points)], detectionID: 1, sourceSize: CGSize(width: 640, height: 480))
    }

    func testClassifierAndConfidenceGate() {
        for g in HandGesture.allCases {
            XCTAssertEqual(GestureMappingEngine.recognize(detection: hand(g), mapping: mapping(), previous: nil), g)
            XCTAssertNil(GestureMappingEngine.recognize(detection: hand(g, confidence: 0.1), mapping: mapping(), previous: nil))
        }
    }

    func testDebounceHeldClickAndLossRelease() {
        let engine = GestureMappingEngine(), m = mapping()
        func update(_ detection: LandmarkDetection?, _ time: Double) -> [SystemPointerEvent] {
            engine.update(detection: detection, mapping: m, screen: screen, mirrored: false, now: time).events
        }
        XCTAssertFalse(update(hand(.pinch), 0).contains { if case .leftDown = $0 { true } else { false } })
        XCTAssertTrue(update(hand(.pinch), 0.13).contains { if case .leftDown = $0 { true } else { false } })
        XCTAssertTrue(update(hand(.pinch), 0.2).contains { if case .leftDrag = $0 { true } else { false } })
        XCTAssertTrue(update(nil, 0.5).contains { if case .leftUp = $0 { true } else { false } })
        XCTAssertTrue(engine.stop().isEmpty)
    }

    func testCanvasPinchToFistEndsDrawingBeforeEraseAndNeverPostsMouse() {
        let engine = GestureMappingEngine(), m = mapping(.canvas)
        _ = engine.update(detection: hand(.pinch), mapping: m, screen: screen, mirrored: false, now: 0)
        let draw = engine.update(detection: hand(.pinch), mapping: m, screen: screen, mirrored: false, now: 0.13)
        XCTAssertEqual(draw.events, [.canvas(.draw, CGPoint(x: 0.45, y: 0.35))])
        let transition = engine.update(detection: hand(.fist), mapping: m, screen: screen, mirrored: false, now: 0.2)
        XCTAssertEqual(transition.events, [.canvasEnd])
        let erase = engine.update(detection: hand(.fist), mapping: m, screen: screen, mirrored: false, now: 0.34)
        XCTAssertEqual(erase.events.count, 1)
        guard case .canvas(.erase, let point) = erase.events.first else {
            return XCTFail("Expected only a canvas erase sample")
        }
        XCTAssertEqual(point.x, 0.45, accuracy: 0.000001)
        XCTAssertEqual(point.y, 0.68, accuracy: 0.000001)
        XCTAssertEqual(engine.stop(), [.canvasEnd])
    }

    func testShortcutFiresOncePerGestureAndLegacyMappingDecodes() throws {
        let engine = GestureMappingEngine()
        var m = mapping()
        m.gestureRules = [.init(gesture: .fist, action: .key, shortcut: .undo)]
        _ = engine.update(detection: hand(.fist), mapping: m, screen: screen, mirrored: false, now: 0)
        let entry = engine.update(detection: hand(.fist), mapping: m, screen: screen, mirrored: false, now: 0.2)
        XCTAssertTrue(entry.events.contains(.shortcut(.undo)))
        let hold = engine.update(detection: hand(.fist), mapping: m, screen: screen, mirrored: false, now: 0.4)
        XCTAssertFalse(hold.events.contains(.shortcut(.undo)))
        var data = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as? [String: Any])
        data.removeValue(forKey: "destination"); data.removeValue(forKey: "gestureRules"); data.removeValue(forKey: "gestureDwell")
        let old = try JSONDecoder().decode(SystemPointerMapping.self, from: JSONSerialization.data(withJSONObject: data))
        XCTAssertNil(old.gestureRules)
        XCTAssertEqual(old.pointer, m.pointer)
    }
}
