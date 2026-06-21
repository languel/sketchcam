import CoreImage
import XCTest
@testable import SketchCam
import SketchCamCore

final class MetalInkStateSnapshotTests: XCTestCase {
    func testSnapshotRestoreAndFixedClockContinuationAreDeterministic() throws {
        guard let live = MetalInkEngine(), let first = MetalInkEngine(), let second = MetalInkEngine() else {
            throw XCTSkip("Metal ink is unavailable")
        }
        var settings = ProcessingSettings()
        settings.landmarks.inkEnabled = true
        settings.landmarks.inkPaperEnabled = true
        settings.landmarks.inkPaths = [InkEditorPath(
            points: [CGPoint(x: 0.15, y: 0.3), CGPoint(x: 0.45, y: 0.7), CGPoint(x: 0.85, y: 0.4)],
            sampleTimes: [0, 0.08, 0.4], strokeSeed: 42, brushMode: .pen,
            inkKind: .black, width: 0.8, flow: 0.9
        )]
        let size = CGSize(width: 96, height: 64)
        for frame in 0..<12 {
            _ = live.layer(settings: settings, live: nil, livePoints: [], endedLiveID: nil,
                           outputSize: size, frameIndex: frame, fixedDeltaTime: 1 / 60)
        }
        guard let snapshot = live.makeStateSnapshot() else { return XCTFail("Could not capture state") }
        XCTAssertTrue(first.restoreStateSnapshot(snapshot))
        XCTAssertTrue(second.restoreStateSnapshot(snapshot))

        var firstImage: CIImage?, secondImage: CIImage?
        for frame in 0..<8 {
            firstImage = first.layer(settings: settings, live: nil, livePoints: [], endedLiveID: nil,
                                     outputSize: size, frameIndex: frame, fixedDeltaTime: 1 / 60)
            secondImage = second.layer(settings: settings, live: nil, livePoints: [], endedLiveID: nil,
                                       outputSize: size, frameIndex: frame, fixedDeltaTime: 1 / 60)
        }
        XCTAssertEqual(try hash(firstImage, size: size), try hash(secondImage, size: size))
    }

    private func hash(_ image: CIImage?, size: CGSize) throws -> UInt64 {
        guard let image else { throw ExporterError.encodingFailed }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw ExporterError.encodingFailed }
        CIContext().render(image, to: buffer)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let count = CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer)
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var value: UInt64 = 14_695_981_039_346_656_037
        for index in 0..<count { value = (value ^ UInt64(bytes[index])) &* 1_099_511_628_211 }
        return value
    }
}
