import AppKit
import XCTest
import SketchCamCore
@testable import SketchCam

final class GesturePortraitTests: XCTestCase {
    private var settings: LandmarkSettings {
        var s = LandmarkSettings()
        s.portraitApproach = .gesture
        s.portraitEnabled = true
        return s
    }
    private func fixture(eye: CGFloat = 8, mouth: CGFloat = 10) -> [MappedGroup] {
        func ring(_ region: LandmarkRegion, _ x: CGFloat, _ y: CGFloat, _ rx: CGFloat, _ ry: CGFloat) -> MappedGroup {
            MappedGroup(region: region, points: (0..<12).map {
                let a = CGFloat($0) * .pi / 6
                return CGPoint(x: x + cos(a)*rx, y: y + sin(a)*ry)
            })
        }
        return [ring(.leftEye, 235, 225, 29, eye), ring(.rightEye, 365, 225, 29, eye),
                ring(.mouth, 300, 380, 32, mouth),
                MappedGroup(region: .nose, points: [CGPoint(x: 292, y: 288), CGPoint(x: 278, y: 326), CGPoint(x: 308, y: 326)])]
    }

    func testCompletesMissingScalpAndBustWithoutContourOrJaw() throws {
        let path = try XCTUnwrap(GesturePortrait.paths(groups: fixture(), settings: settings).first)
        XCTAssertLessThan(path.map(\.y).min()!, 100)
        XCTAssertGreaterThan(path.map(\.y).max()!, 680)
        XCTAssertLessThan(path.count, 800)
        XCTAssertTrue(path.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertEqual(GesturePortrait.paths(groups: [], settings: settings), [])
    }

    func testFaceFrameRotatesAndTranslatesAllInventedGeometry() throws {
        let transform = CGAffineTransform(rotationAngle: 0.6).translatedBy(x: 18, y: 30)
        let original = try XCTUnwrap(GesturePortrait.paths(groups: fixture(), settings: settings).first)
        let groups = fixture().map { MappedGroup(region: $0.region, points: $0.points.map { $0.applying(transform) }) }
        let turned = try XCTUnwrap(GesturePortrait.paths(groups: groups, settings: settings).first)
        XCTAssertEqual(original.count, turned.count)
        for (a, b) in zip(original, turned) {
            let expected = a.applying(transform)
            XCTAssertEqual(expected.x, b.x, accuracy: 0.001)
            XCTAssertEqual(expected.y, b.y, accuracy: 0.001)
        }
    }

    func testExpressionDeformsWithoutChangingTopologyAndSeedChangesGrammar() throws {
        let first = GesturePortrait.paths(groups: fixture(), settings: settings)
        let open = GesturePortrait.paths(groups: fixture(eye: 14, mouth: 28), settings: settings)
        XCTAssertEqual(first.map(\.count), open.map(\.count))
        XCTAssertNotEqual(first, open)
        var next = settings
        next.portraitSeed = 14
        XCTAssertNotEqual(first, GesturePortrait.paths(groups: fixture(), settings: next))
        next.portraitSegments = 3
        XCTAssertEqual(GesturePortrait.paths(groups: fixture(), settings: next).count, 3)
        let restored = try JSONDecoder().decode(LandmarkSettings.self, from: JSONEncoder().encode(next))
        XCTAssertEqual(restored, next)
    }

    func testGestureGeometryPerformance() {
        let groups = fixture(), s = settings
        measure { for _ in 0..<1000 { _ = GesturePortrait.paths(groups: groups, settings: s) } }
    }

    func testRenderReferencePreview() throws {
        let context = try XCTUnwrap(CGContext(data: nil, width: 640, height: 900, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor(calibratedRed: 0.95, green: 0.91, blue: 0.85, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 900))
        context.translateBy(x: 0, y: 900); context.scaleBy(x: 1, y: -1)
        var s = settings
        s.portraitWidth = 5
        s.portraitColor = .black
        PortraitDrawing().render(groups: fixture(), landmarks: s, into: context)
        let image = try XCTUnwrap(context.makeImage())
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        attachment.name = "Gesture portrait - missing scalp and body completed"
        attachment.lifetime = .keepAlways
        add(attachment)
        // Opt-in artifact for visual review, outside the app's saved session.
        if let path = ProcessInfo.processInfo.environment["SKETCHCAM_PORTRAIT_PREVIEW"] {
            try png.write(to: URL(fileURLWithPath: path))
        }
    }
}
