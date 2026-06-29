import CoreGraphics
import XCTest
@testable import SketchCamCore

final class CanvasActionLedgerTests: XCTestCase {
    private func path(_ x: CGFloat) -> InkEditorPath {
        InkEditorPath(
            points: [CGPoint(x: x, y: 0), CGPoint(x: x, y: 1)],
            sampleTimes: [0, 0.25],
            strokeSeed: UInt64(x * 1_000)
        )
    }

    private func record(_ x: CGFloat, editable: Bool = true, mode: InkStrokeCaptureMode = .pen) -> InkStrokeRecord {
        let id = UUID()
        let samples = [
            InkStrokeSample(point: CGPoint(x: x, y: 0), time: 0),
            InkStrokeSample(point: CGPoint(x: x, y: 1), time: 0.25, modifiers: InkStrokeModifierFlags(shift: true), charge: 0.5)
        ]
        return InkStrokeRecord(
            capture: InkStrokeCapture(
                id: id,
                seed: UInt64(x * 10_000),
                rawSamples: samples,
                canonicalSamples: samples,
                mode: mode
            ),
            activeRender: InkRenderRecipe(
                intent: mode == .pen ? .pen : mode == .wetOnly ? .wetOnly : .wash,
                inkKind: .black,
                color: .ink,
                width: 0.45,
                flow: 0.8,
                bleed: 0.7,
                dry: 0.2,
                colorSeparation: 0.4,
                brushInk: mode == .pen ? 0 : 0.2,
                smoothing: 0.6
            ),
            isEditable: editable
        )
    }

    func testImmediateStrokeIsUndoableWithoutBecomingEditable() {
        var ledger = CanvasActionLedger()
        let immediate = record(0.25, editable: false)
        ledger.commitImmediate(immediate)

        XCTAssertEqual(ledger.records, [immediate])
        XCTAssertEqual(ledger.replayPaths, [immediate.renderPath])
        XCTAssertFalse(ledger.actions[0].isEditable)
        XCTAssertEqual(ledger.undo()?.id, immediate.id)
        XCTAssertTrue(ledger.replayPaths.isEmpty)
        XCTAssertEqual(ledger.redo()?.id, immediate.id)
        XCTAssertEqual(ledger.replayPaths, [immediate.renderPath])
    }

    func testRecordedAndImmediateStrokesKeepExecutionOrder() {
        var ledger = CanvasActionLedger()
        let first = record(0.1)
        let immediate = record(0.2, editable: false)
        let last = record(0.3)

        ledger.replaceEditableRecords([first])
        ledger.commitImmediate(immediate)
        ledger.replaceEditableRecords([first, last])

        XCTAssertEqual(ledger.records.map(\.id), [first.id, immediate.id, last.id])
        XCTAssertEqual(ledger.replayPaths.map(\.id), [first.id, immediate.id, last.id])
        XCTAssertEqual(ledger.undo()?.id, last.id)
        XCTAssertEqual(ledger.undo()?.id, immediate.id)
        XCTAssertEqual(ledger.redo()?.id, immediate.id)
    }

    func testEditingRecordedPathUpdatesInPlaceWithoutExposingImmediate() {
        var ledger = CanvasActionLedger()
        var editable = path(0.1)
        let immediate = record(0.2, editable: false)
        ledger.replaceEditablePaths([editable])
        ledger.commitImmediate(immediate)

        editable.points[1].x = 0.8
        ledger.replaceEditablePaths([editable])

        XCTAssertEqual(ledger.replayPaths.map(\.id), [editable.id, immediate.id])
        XCTAssertEqual(ledger.replayPaths[0].points[1].x, 0.8)
        XCTAssertEqual(ledger.records[0].capture.canonicalSamples[1].point.x, 0.8)
    }

    func testInkStrokeTypesSurviveCodableRoundTrip() throws {
        let stroke = record(0.4, editable: true, mode: .wash)
        let encodedSample = try JSONEncoder().encode(stroke.capture.rawSamples[1])
        let decodedSample = try JSONDecoder().decode(InkStrokeSample.self, from: encodedSample)
        XCTAssertEqual(decodedSample.modifiers?.shift, true)
        XCTAssertEqual(decodedSample.charge, 0.5)

        let encodedCapture = try JSONEncoder().encode(stroke.capture)
        let decodedCapture = try JSONDecoder().decode(InkStrokeCapture.self, from: encodedCapture)
        XCTAssertEqual(decodedCapture, stroke.capture)

        let encodedRecipe = try JSONEncoder().encode(stroke.activeRender)
        let decodedRecipe = try JSONDecoder().decode(InkRenderRecipe.self, from: encodedRecipe)
        XCTAssertEqual(decodedRecipe, stroke.activeRender)

        let encodedRecord = try JSONEncoder().encode(stroke)
        let decodedRecord = try JSONDecoder().decode(InkStrokeRecord.self, from: encodedRecord)
        XCTAssertEqual(decodedRecord, stroke)
    }

    func testLegacyPathMigratesWithoutLosingMetadata() throws {
        let path = InkEditorPath(
            id: UUID(),
            points: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.4, y: 0.8)],
            sampleTimes: [0, 0.125],
            strokeSeed: 42,
            brushMode: .brush,
            inkKind: .white,
            width: 0.7,
            flow: 0.6,
            bleed: 0.5,
            dry: 0.4,
            colorSeparation: 0.3,
            brushInk: 0.2,
            color: RGBAColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        )
        let settings = LandmarkSettings(inkPaths: [path])
        let records = settings.resolvedInkStrokeRecords()
        XCTAssertNil(settings.inkStrokeRecords)
        XCTAssertEqual(records.count, 1)
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.id, path.id)
        XCTAssertEqual(record.capture.seed, 42)
        XCTAssertEqual(record.capture.rawSamples.map(\.point), path.points)
        XCTAssertEqual(record.capture.canonicalSamples.map(\.time), [0, 0.125])
        XCTAssertEqual(record.activeRender.intent, .wash)
        XCTAssertEqual(record.activeRender.inkKind, .white)
        XCTAssertEqual(record.activeRender.width, 0.7)
        XCTAssertEqual(record.activeRender.flow, 0.6)
        XCTAssertEqual(record.activeRender.bleed, 0.5)
        XCTAssertEqual(record.activeRender.dry, 0.4)
        XCTAssertEqual(record.activeRender.colorSeparation, 0.3)
        XCTAssertEqual(record.activeRender.brushInk, 0.2)
        XCTAssertEqual(record.activeRender.color, path.color)
        XCTAssertEqual(record.renderPath.sampleTimes, path.sampleTimes)

        let encoded = try JSONEncoder().encode(path)
        let decoded = try JSONDecoder().decode(InkEditorPath.self, from: encoded)
        XCTAssertEqual(decoded.sampleTimes, [0, 0.125])
        XCTAssertEqual(decoded.strokeSeed, 42)
    }
}
