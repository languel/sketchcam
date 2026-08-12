import CoreGraphics
import XCTest
@testable import SketchCam
import SketchCamCore

final class PathSignalRoutingTests: XCTestCase {
    func testMousePathsBecomeSeparateConnectedGroupsInLandmarkCoordinates() throws {
        let first = InkEditorPath(points: [
            CGPoint(x: 0.1, y: 0.2),
            CGPoint(x: 0.4, y: 0.7),
            CGPoint(x: 0.8, y: 0.9)
        ])
        let second = InkEditorPath(points: [CGPoint(x: 0.25, y: 0.5)])

        let detection = try XCTUnwrap(RoutedPathSignalResolver.mouseDetection(
            paths: [first, second],
            revision: 7,
            sourceSize: CGSize(width: 1920, height: 1080)
        ))

        XCTAssertEqual(detection.groups.count, 2)
        let expectedPoints = [
            CGPoint(x: 0.1, y: 0.8),
            CGPoint(x: 0.4, y: 0.3),
            CGPoint(x: 0.8, y: 0.1)
        ]
        for (actual, expected) in zip(detection.groups[0].points.map(\.point), expectedPoints) {
            XCTAssertEqual(actual.x, expected.x, accuracy: 0.000_001)
            XCTAssertEqual(actual.y, expected.y, accuracy: 0.000_001)
        }
        XCTAssertEqual(detection.groups[0].edges.map { [$0.0, $0.1] }, [[0, 1], [1, 2]])
        XCTAssertEqual(detection.groups[1].edges.count, 0)
        XCTAssertEqual(detection.sourceSize, CGSize(width: 1920, height: 1080))
        XCTAssertEqual(detection.detectionID, 7 | (UInt64(1) << 63))
    }

    func testEmptyMouseStreamProducesNoDetection() {
        XCTAssertNil(RoutedPathSignalResolver.mouseDetection(
            paths: [], revision: 0, sourceSize: CGSize(width: 640, height: 480)
        ))
    }

    func testCanvasPathSnapshotRevisionChangesAfterMutation() {
        let history = CanvasActionHistory()
        let before = history.pathSnapshot()
        history.commitImmediate(InkEditorPath(points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]))
        let after = history.pathSnapshot()

        XCTAssertEqual(before.paths.count, 0)
        XCTAssertEqual(after.paths.count, 1)
        XCTAssertNotEqual(before.revision, after.revision)
    }

    func testLiveMousePathSnapshotDoesNotConsumeInkSamples() {
        let live = InkLiveStroke()
        let sample = InkLiveStrokeSample(
            id: UUID(), seed: 1, point: CGPoint(x: 0.2, y: 0.3), time: 0,
            brushMode: .pen, inkKind: .black, width: 0.5, flow: 1,
            brushInk: 0, color: .ink, smoothBoost: false, destructive: false,
            wetOnly: false, charge: 0
        )
        live.update(sample)

        let path = live.pathSnapshot()
        let consumed = live.consume()

        XCTAssertEqual(path.points, [sample.point])
        XCTAssertEqual(consumed.sample, sample)
        XCTAssertEqual(consumed.points.map(\.point), [sample.point])
    }
}
