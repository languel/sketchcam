import CoreGraphics
import XCTest
@testable import SketchCamCore

final class CanvasActionLedgerTests: XCTestCase {
    private func path(_ x: CGFloat) -> InkEditorPath {
        InkEditorPath(points: [CGPoint(x: x, y: 0), CGPoint(x: x, y: 1)])
    }

    func testImmediateStrokeIsUndoableWithoutBecomingEditable() {
        var ledger = CanvasActionLedger()
        let immediate = path(0.25)
        ledger.commitImmediate(immediate)

        XCTAssertEqual(ledger.replayPaths, [immediate])
        XCTAssertFalse(ledger.actions[0].isEditable)
        XCTAssertEqual(ledger.undo()?.id, immediate.id)
        XCTAssertTrue(ledger.replayPaths.isEmpty)
        XCTAssertEqual(ledger.redo()?.id, immediate.id)
        XCTAssertEqual(ledger.replayPaths, [immediate])
    }

    func testRecordedAndImmediateStrokesKeepExecutionOrder() {
        var ledger = CanvasActionLedger()
        let first = path(0.1)
        let immediate = path(0.2)
        let last = path(0.3)

        ledger.replaceEditablePaths([first])
        ledger.commitImmediate(immediate)
        ledger.replaceEditablePaths([first, last])

        XCTAssertEqual(ledger.replayPaths.map(\.id), [first.id, immediate.id, last.id])
        XCTAssertEqual(ledger.undo()?.id, last.id)
        XCTAssertEqual(ledger.undo()?.id, immediate.id)
        XCTAssertEqual(ledger.redo()?.id, immediate.id)
    }

    func testEditingRecordedPathUpdatesInPlaceWithoutExposingImmediate() {
        var ledger = CanvasActionLedger()
        var editable = path(0.1)
        let immediate = path(0.2)
        ledger.replaceEditablePaths([editable])
        ledger.commitImmediate(immediate)

        editable.points[1].x = 0.8
        ledger.replaceEditablePaths([editable])

        XCTAssertEqual(ledger.replayPaths.map(\.id), [editable.id, immediate.id])
        XCTAssertEqual(ledger.replayPaths[0].points[1].x, 0.8)
    }

    func testTimedGestureMetadataSurvivesLedgerAndCodableRoundTrip() throws {
        let path = InkEditorPath(
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.4, y: 0.8)],
            sampleTimes: [0, 0.125],
            strokeSeed: 42
        )
        var ledger = CanvasActionLedger()
        ledger.commitImmediate(path)
        XCTAssertEqual(ledger.replayPaths.first?.sampleTimes, [0, 0.125])

        let encoded = try JSONEncoder().encode(path)
        let decoded = try JSONDecoder().decode(InkEditorPath.self, from: encoded)
        XCTAssertEqual(decoded.sampleTimes, [0, 0.125])
        XCTAssertEqual(decoded.strokeSeed, 42)
    }
}
