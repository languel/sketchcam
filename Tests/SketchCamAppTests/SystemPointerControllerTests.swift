import CoreGraphics
import XCTest
@testable import SketchCam

final class SystemPointerControllerTests: XCTestCase {
    private let screen = CGRect(x: 100, y: 50, width: 1_000, height: 500)

    func testMappingPersistsButArmedStateDoesNot() throws {
        let suiteName = "SystemPointerControllerTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let controller = SystemPointerController(defaults: defaults)
        controller.mapping.pointer = MediaPipeHandFeature(side: .left, landmark: .middleTip)
        controller.mapping.driveMode = .always
        controller.mapping.smoothing = 0.2

        let restored = SystemPointerController(defaults: defaults)
        XCTAssertEqual(restored.mapping, controller.mapping)
        XCTAssertFalse(restored.isArmed)
    }

    func testAlwaysModeMapsVisionCoordinatesIntoQuartzScreenCoordinates() {
        let engine = SystemPointerEngine()
        var mapping = SystemPointerMapping.default
        mapping.driveMode = .always
        mapping.clickWithPinch = false
        mapping.smoothing = 0
        mapping.horizontalCoverage = 1
        mapping.verticalCoverage = 1

        let result = engine.update(
            detection: handDetection(index: CGPoint(x: 0.25, y: 0.75), pinchRatio: 0.8),
            mapping: mapping,
            screenBounds: screen,
            mirrored: false,
            now: 1
        )

        XCTAssertEqual(result.events, [.move(CGPoint(x: 350, y: 175))])
        XCTAssertEqual(result.live.normalizedPoint, CGPoint(x: 0.25, y: 0.75))
    }

    func testMirroringFlipsPointerHorizontally() {
        let engine = SystemPointerEngine()
        var mapping = SystemPointerMapping.default
        mapping.driveMode = .always
        mapping.clickWithPinch = false
        mapping.smoothing = 0
        mapping.horizontalCoverage = 1
        mapping.verticalCoverage = 1

        let result = engine.update(
            detection: handDetection(index: CGPoint(x: 0.25, y: 0.75), pinchRatio: 0.8),
            mapping: mapping,
            screenBounds: screen,
            mirrored: true,
            now: 1
        )

        XCTAssertEqual(result.events, [.move(CGPoint(x: 850, y: 175))])
    }

    func testWhilePinchingMovesPressesDragsAndReleases() {
        let engine = SystemPointerEngine()
        var mapping = SystemPointerMapping.default
        mapping.smoothing = 0
        mapping.horizontalCoverage = 1
        mapping.verticalCoverage = 1

        let open = engine.update(
            detection: handDetection(index: CGPoint(x: 0.4, y: 0.6), pinchRatio: 0.7),
            mapping: mapping,
            screenBounds: screen,
            mirrored: false,
            now: 1
        )
        XCTAssertTrue(open.events.isEmpty)

        let down = engine.update(
            detection: handDetection(index: CGPoint(x: 0.4, y: 0.6), pinchRatio: 0.3),
            mapping: mapping,
            screenBounds: screen,
            mirrored: false,
            now: 2
        )
        XCTAssertEqual(down.events, [
            .move(CGPoint(x: 500, y: 250)),
            .leftDown(CGPoint(x: 500, y: 250))
        ])

        let drag = engine.update(
            detection: handDetection(index: CGPoint(x: 0.5, y: 0.5), pinchRatio: 0.3),
            mapping: mapping,
            screenBounds: screen,
            mirrored: false,
            now: 3
        )
        XCTAssertEqual(drag.events, [.leftDrag(CGPoint(x: 600, y: 300))])

        let up = engine.update(
            detection: handDetection(index: CGPoint(x: 0.5, y: 0.5), pinchRatio: 0.5),
            mapping: mapping,
            screenBounds: screen,
            mirrored: false,
            now: 4
        )
        XCTAssertEqual(up.events, [.leftUp(CGPoint(x: 600, y: 300))])
    }

    func testPinchUsesReleaseHysteresis() {
        let engine = SystemPointerEngine()
        var mapping = SystemPointerMapping.default
        mapping.smoothing = 0

        let down = engine.update(
            detection: handDetection(pinchRatio: 0.30), mapping: mapping,
            screenBounds: screen, mirrored: false, now: 1
        )
        XCTAssertTrue(down.live.pinching)

        let held = engine.update(
            detection: handDetection(pinchRatio: 0.40), mapping: mapping,
            screenBounds: screen, mirrored: false, now: 2
        )
        XCTAssertTrue(held.live.pinching)
        XCTAssertFalse(held.events.contains { if case .leftUp = $0 { true } else { false } })

        let released = engine.update(
            detection: handDetection(pinchRatio: 0.46), mapping: mapping,
            screenBounds: screen, mirrored: false, now: 3
        )
        XCTAssertFalse(released.live.pinching)
        XCTAssertTrue(released.events.contains { if case .leftUp = $0 { true } else { false } })
    }

    func testMissingHandReleasesHeldButtonAfterGracePeriod() {
        let engine = SystemPointerEngine()
        var mapping = SystemPointerMapping.default
        mapping.smoothing = 0
        mapping.missingGraceSeconds = 0.18

        _ = engine.update(
            detection: handDetection(pinchRatio: 0.3), mapping: mapping,
            screenBounds: screen, mirrored: false, now: 1
        )
        let grace = engine.update(
            detection: nil, mapping: mapping,
            screenBounds: screen, mirrored: false, now: 1.1
        )
        XCTAssertTrue(grace.events.isEmpty)

        let missing = engine.update(
            detection: nil, mapping: mapping,
            screenBounds: screen, mirrored: false, now: 1.2
        )
        XCTAssertEqual(missing.events.count, 1)
        guard case .leftUp = missing.events[0] else {
            return XCTFail("Expected a left-button release")
        }
    }

    private func handDetection(
        index: CGPoint = CGPoint(x: 0.5, y: 0.5),
        pinchRatio: CGFloat
    ) -> LandmarkDetection {
        let wrist = CGPoint(x: 0.5, y: 0.8)
        let middleMCP = CGPoint(x: 0.5, y: 0.6)
        let palmSize = hypot(wrist.x - middleMCP.x, wrist.y - middleMCP.y)
        let thumb = CGPoint(x: index.x - pinchRatio * palmSize, y: index.y)
        return LandmarkDetection(
            groups: [LandmarkGroup(region: .hands, points: [
                LandmarkPoint(point: wrist, confidence: 1, label: "R0"),
                LandmarkPoint(point: thumb, confidence: 1, label: "R4"),
                LandmarkPoint(point: index, confidence: 1, label: "R8"),
                LandmarkPoint(point: middleMCP, confidence: 1, label: "R9")
            ])],
            detectionID: 1,
            sourceSize: CGSize(width: 640, height: 480)
        )
    }
}
