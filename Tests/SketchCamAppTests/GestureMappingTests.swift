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
    func hand(_ gesture: HandGesture, confidence: Float = 1,
              side: MediaPipeHandSide = .right) -> LandmarkDetection {
        let prefix = side.labelPrefix
        var points = [LandmarkPoint(point: CGPoint(x: 0.5, y: 0.2), confidence: confidence, label: "\(prefix)0"),
                      LandmarkPoint(point: CGPoint(x: 0.5, y: 0.4), confidence: confidence, label: "\(prefix)9")]
        for (i, tip) in [8, 12, 16, 20].enumerated() {
            let x = 0.45 + Double(i) * 0.035
            points.append(LandmarkPoint(point: CGPoint(x: x, y: 0.48), confidence: confidence, label: "\(prefix)\(tip - 2)"))
            points.append(LandmarkPoint(point: CGPoint(x: x, y: gesture == .fist ? 0.32 : 0.65), confidence: confidence, label: "\(prefix)\(tip)"))
        }
        points.append(LandmarkPoint(point: CGPoint(x: gesture == .pinch ? 0.46 : 0.3, y: 0.65), confidence: confidence, label: "\(prefix)4"))
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

    func testCustomStackRoutesEachHandAndReleasesBetweenTools() throws {
        var m = mapping(.canvas)
        m.customGestureMaps = Array(MotionGestureMap.examples.prefix(4))
        let engine = CanvasGestureStackEngine()
        func events(_ side: MediaPipeHandSide, _ gesture: HandGesture, _ time: Double) -> [SystemPointerEvent] {
            engine.update(detection: hand(gesture, side: side), mapping: m,
                          screen: screen, mirrored: false, now: time).events
        }
        _ = events(.left, .pinch, 0)
        let left = events(.left, .pinch, 0.13)
        guard case .canvasPaint(let leftPaint)? = left.last else { return XCTFail("Missing left paint") }
        XCTAssertEqual(leftPaint.hand, .left)
        XCTAssertEqual(leftPaint.mode, .pen)
        XCTAssertEqual(leftPaint.intent, .draw)

        XCTAssertEqual(events(.right, .pinch, 0.2), [.canvasEnd])
        let right = events(.right, .pinch, 0.34)
        guard case .canvasPaint(let rightPaint)? = right.last else { return XCTFail("Missing right paint") }
        XCTAssertEqual(rightPaint.hand, .right)
        XCTAssertEqual(rightPaint.mode, .wash)
        XCTAssertEqual(rightPaint.intent, .draw)

        XCTAssertEqual(events(.right, .fist, 0.4), [.canvasEnd])
        let erase = events(.right, .fist, 0.54)
        guard case .canvasPaint(let erasePaint)? = erase.last else { return XCTFail("Missing wash erase") }
        XCTAssertEqual(erasePaint.mode, .wash)
        XCTAssertEqual(erasePaint.intent, .erase)
        XCTAssertEqual(engine.update(detection: nil, mapping: m, screen: screen,
                                     mirrored: false, now: 0.8).events, [.canvasEnd])
        XCTAssertTrue(engine.stop().isEmpty)
    }

    func testPassiveLeftJointDistanceModulatesRightWashWhilePinching() throws {
        var m = mapping(.canvas)
        m.customGestureMaps = [.action(.right, .pinch, .wash, .draw), .parameter()]
        let engine = CanvasGestureStackEngine()
        let left = hand(.openPalm, side: .left).groups[0]
        let right = hand(.pinch, side: .right).groups[0]
        let detection = LandmarkDetection(groups: [left, right], detectionID: 2,
                                          sourceSize: CGSize(width: 640, height: 480))
        _ = engine.update(detection: detection, mapping: m, screen: screen, mirrored: false, now: 0)
        let output = engine.update(detection: detection, mapping: m, screen: screen, mirrored: false, now: 0.13)
        guard case .canvasPaint(let paint)? = output.events.last else { return XCTFail("Missing paint") }
        let rule = try XCTUnwrap(m.customGestureMaps?.last)
        let measured = try XCTUnwrap(CanvasGestureStackEngine.measure(rule, detection: detection,
                                                                      minimumConfidence: m.minimumConfidence))
        let expected = Float(rule.outputLow + min(1, max(0,
            (measured - rule.inputLow) / (rule.inputHigh - rule.inputLow)))
            * (rule.outputHigh - rule.outputLow))
        XCTAssertEqual(paint.parameters[.washSize], expected)
        let fistDetection = LandmarkDetection(groups: [left, hand(.fist, side: .right).groups[0]],
                                              detectionID: 3,
                                              sourceSize: CGSize(width: 640, height: 480))
        XCTAssertEqual(engine.update(detection: fistDetection, mapping: m, screen: screen,
                                     mirrored: false, now: 0.2).events, [.canvasEnd])
        let encoded = try JSONEncoder().encode(m)
        XCTAssertEqual(try JSONDecoder().decode(SystemPointerMapping.self, from: encoded).customGestureMaps,
                       m.customGestureMaps)
    }

    func testDisabledAndOrderedMapsAndAngleMeasurement() throws {
        var first = MotionGestureMap.action(.right, .pinch, .pen, .draw)
        var second = MotionGestureMap.action(.right, .pinch, .wash, .erase)
        first.enabled = false
        var m = mapping(.canvas)
        m.customGestureMaps = [first, second]
        let engine = CanvasGestureStackEngine()
        _ = engine.update(detection: hand(.pinch), mapping: m, screen: screen, mirrored: false, now: 0)
        let chosen = engine.update(detection: hand(.pinch), mapping: m,
                                   screen: screen, mirrored: false, now: 0.13)
        guard case .canvasPaint(let paint)? = chosen.events.last else { return XCTFail("Missing paint") }
        XCTAssertEqual(paint.ruleID, second.id)
        XCTAssertEqual(paint.intent, .erase)

        second.enabled = false
        m.customGestureMaps = [first, second]
        XCTAssertEqual(engine.update(detection: hand(.pinch), mapping: m,
                                     screen: screen, mirrored: false, now: 0.2).events, [.canvasEnd])

        var angle = MotionGestureMap.parameter()
        angle.metric = .angle
        angle.first = .init(side: .left, landmark: .thumbTip)
        angle.vertex = .init(side: .left, landmark: .wrist)
        angle.last = .init(side: .left, landmark: .indexTip)
        let observed = hand(.openPalm, side: .left)
        let degrees = try XCTUnwrap(CanvasGestureStackEngine.measure(
            angle, detection: observed, minimumConfidence: 0.25))
        XCTAssertGreaterThan(degrees, 0)
        XCTAssertLessThanOrEqual(degrees, 180)
    }
}
