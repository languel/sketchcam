import AVFoundation
import CoreImage
import ImageIO
import XCTest
@testable import SketchCam
import SketchCamCore

final class OutputStreamExporterTests: XCTestCase {
    private func frame(width: Int = 64, height: Int = 48, gray: CGFloat = 0.4) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw ExporterError.encodingFailed }
        CIContext().render(CIImage(color: CIColor(red: gray, green: 0.2, blue: 0.8)).cropped(
            to: CGRect(x: 0, y: 0, width: width, height: height)), to: buffer)
        return buffer
    }

    private func splitFrame(width: Int = 64, height: Int = 48) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw ExporterError.encodingFailed }
        let left = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: width / 2, height: height))
        let right = CIImage(color: .blue).cropped(to: CGRect(x: width / 2, y: 0, width: width / 2, height: height))
        CIContext().render(right.composited(over: left), to: buffer)
        return buffer
    }

    private func waitUntil(_ description: String, timeout: TimeInterval = 8,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for \(description)")
    }

    private func centerRGBA(_ image: CGImage) -> [UInt8] {
        let x = CGFloat(image.width / 2), y = CGFloat(image.height / 2)
        let sample = CIImage(cgImage: image)
            .cropped(to: CGRect(x: x, y: y, width: 1, height: 1))
            .transformed(by: CGAffineTransform(translationX: -x, y: -y))
        var bytes = [UInt8](repeating: 0, count: 4)
        CIContext().render(sample, toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8,
                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    func testBuiltInWorkflowPresetsConfigureExpectedCaptureSemantics() {
        let exporter = OutputStreamExporter()

        exporter.applyPreset(.activeInkPerformance, outputFPS: 60)
        XCTAssertEqual(exporter.configuration.trigger, .cadence)
        XCTAssertEqual(exporter.configuration.captureFPS, 60)
        XCTAssertEqual(exporter.configuration.playbackFPS, 60)
        XCTAssertEqual(exporter.configuration.gates.map(\.kind), [.inkSolverActive])
        XCTAssertEqual(exporter.configuration.gates.first?.lowerBound, 0.5)

        exporter.applyPreset(.realtimePerformance, outputFPS: 24)
        XCTAssertEqual(exporter.configuration.trigger, .cadence)
        XCTAssertEqual(exporter.configuration.captureFPS, 24)
        XCTAssertTrue(exporter.configuration.gates.isEmpty)

        exporter.applyPreset(.manualStopMotion, outputFPS: 30)
        XCTAssertEqual(exporter.configuration.trigger, .manual)
        exporter.applyPreset(.mouseUpStopMotion, outputFPS: 30)
        XCTAssertEqual(exporter.configuration.trigger, .mouseUp)
        exporter.applyPreset(.canvasActions, outputFPS: 30)
        XCTAssertEqual(exporter.configuration.trigger, .anyCanvasAction)

        exporter.applyPreset(.inkTimeLapse, outputFPS: 30)
        XCTAssertEqual(exporter.configuration.trigger, .cadence)
        XCTAssertEqual(exporter.configuration.captureFPS, 5)
        XCTAssertEqual(exporter.configuration.gates.map(\.kind), [.inkSolverActive])
    }

    func testEveryStillFormatProducesAFile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for format in ExportImageFormat.allCases {
            let exporter = OutputStreamExporter()
            exporter.configuration = ExportConfiguration(
                outputKind: .still, imageFormat: format, width: 64, height: 48,
                trigger: .manual, minimumFreeDiskGB: 0, collisionPolicy: .replace
            )
            let url = root.appendingPathComponent("still-\(format.rawValue).\(format.fileExtension)")
            exporter.destinationURL = url
            exporter.start(); exporter.captureNext(); exporter.offerFrame(try frame(), frameIndex: 0)
            try await waitUntil("\(format) still") { exporter.state == .idle || exporter.state == .failed }
            XCTAssertEqual(exporter.state, .idle, exporter.statusText)
            XCTAssertGreaterThan((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, 0)
        }
    }

    func testMovieWriterProducesMonotonicFrames() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let exporter = OutputStreamExporter()
        exporter.configuration = ExportConfiguration(
            outputKind: .movie, movieCodec: .h264, width: 64, height: 48,
            captureFPS: 30, playbackFPS: 30, trigger: .manual,
            minimumFreeDiskGB: 0, collisionPolicy: .replace
        )
        exporter.destinationURL = url
        exporter.start()
        for index in 0..<3 {
            exporter.captureNext()
            exporter.offerFrame(try frame(gray: CGFloat(index) / 3), frameIndex: index,
                                wallTime: Double(index) / 30)
            try await waitUntil("movie frame \(index)") { exporter.capturedFrames == index + 1 }
        }
        exporter.stop()
        try await waitUntil("movie finalization") { exporter.state == .idle || exporter.state == .failed }
        XCTAssertEqual(exporter.state, .idle, exporter.statusText)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(duration, 0)
    }

    func testGIFAndSequenceProduceFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        for kind in [ExportOutputKind.gif, .imageSequence] {
            let exporter = OutputStreamExporter()
            exporter.configuration = ExportConfiguration(
                outputKind: kind, width: 64, height: 48, trigger: .manual,
                minimumFreeDiskGB: 0, collisionPolicy: .replace
            )
            exporter.destinationURL = kind == .gif ? root.appendingPathComponent("test.gif") : root
            exporter.start()
            for index in 0..<2 {
                exporter.captureNext(); exporter.offerFrame(try frame(gray: CGFloat(index)), frameIndex: index)
                try await waitUntil("\(kind) frame \(index)") { exporter.capturedFrames == index + 1 }
            }
            exporter.stop()
            try await waitUntil("\(kind) finalization") { exporter.state == .idle || exporter.state == .failed }
            XCTAssertEqual(exporter.state, .idle, exporter.statusText)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("test.gif").path))
        let sequence = root.appendingPathComponent("take-001")
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: sequence.path).count), 2)
    }

    func testReviewScrubAndContinueCreateNewGIFTake() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("review.gif")
        let exporter = OutputStreamExporter()
        exporter.configuration = ExportConfiguration(
            outputKind: .gif, width: 64, height: 48, playbackFPS: 12,
            trigger: .manual, minimumFreeDiskGB: 0, collisionPolicy: .newTake
        )
        exporter.destinationURL = original
        exporter.start()
        for index in 0..<3 {
            exporter.captureNext(); exporter.offerFrame(try frame(gray: CGFloat(index) / 3), frameIndex: index)
            try await waitUntil("GIF frame \(index)") { exporter.capturedFrames == index + 1 }
        }
        exporter.stop()
        try await waitUntil("review load") { exporter.state == .idle && exporter.reviewFrameCount == 3 }
        exporter.seekReview(frame: 1)
        try await waitUntil("review seek") { exporter.reviewFrame == 1 && !exporter.reviewIsLoading }

        exporter.continueFromReview()
        try await waitUntil("review prefix") { exporter.state == .recording && exporter.capturedFrames == 2 }
        exporter.captureNext(); exporter.offerFrame(try frame(gray: 1), frameIndex: 3)
        try await waitUntil("continued frame") { exporter.capturedFrames == 3 }
        exporter.stop()
        try await waitUntil("continued GIF finalization") { exporter.state == .idle }

        let continued = root.appendingPathComponent("review-002.gif")
        let source = CGImageSourceCreateWithURL(continued as CFURL, nil)
        XCTAssertEqual(source.map(CGImageSourceGetCount), 3)
    }

    func testCropIsAppliedToEncodedPixels() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let exporter = OutputStreamExporter()
        exporter.configuration = ExportConfiguration(
            outputKind: .still, imageFormat: .png, width: 64, height: 48,
            framing: .stretch, trigger: .manual, minimumFreeDiskGB: 0,
            collisionPolicy: .replace, cropLeft: 0.5
        )
        exporter.destinationURL = url
        exporter.start(); exporter.captureNext(); exporter.offerFrame(try splitFrame(), frameIndex: 0)
        try await waitUntil("cropped still") { exporter.state == .idle || exporter.state == .failed }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertNotNil(image)
        guard let image, let data = image.dataProvider?.data else { return }
        let bytes = CFDataGetBytePtr(data)!
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
        // PNG decodes as RGBA here. The center should be blue once the red
        // half has been removed by cropLeft=0.5.
        XCTAssertLessThan(bytes[offset], 32)
        XCTAssertGreaterThan(bytes[offset + 2], 220)
    }

    func testReviewCropIsAppliedWhenReexporting() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("review-crop.png")
        let exporter = OutputStreamExporter()
        exporter.configuration = ExportConfiguration(
            outputKind: .still, imageFormat: .png, width: 64, height: 48,
            framing: .stretch, trigger: .manual, minimumFreeDiskGB: 0,
            collisionPolicy: .newTake
        )
        exporter.destinationURL = original
        exporter.start(); exporter.captureNext(); exporter.offerFrame(try splitFrame(), frameIndex: 0)
        try await waitUntil("review source") { exporter.state == .idle && exporter.reviewFrameCount == 1 }
        exporter.configuration.cropLeft = 0.5
        exporter.reexportReview()
        try await waitUntil("review crop re-export") {
            exporter.state == .idle && exporter.destinationURL?.lastPathComponent == "review-crop-002.png"
        }
        let output = root.appendingPathComponent("review-crop-002.png")
        let source = CGImageSourceCreateWithURL(output as CFURL, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertNotNil(image)
        guard let image, let data = image.dataProvider?.data else { return }
        let bytes = CFDataGetBytePtr(data)!
        let offset = (image.height / 2) * image.bytesPerRow + (image.width / 2) * 4
        XCTAssertLessThan(bytes[offset], 32)
        XCTAssertGreaterThan(bytes[offset + 2], 220)
    }

    func testCropUsesFramedOutputCoordinatesAndRemovesLetterbox() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let exporter = OutputStreamExporter()
        exporter.configuration = ExportConfiguration(
            outputKind: .still, imageFormat: .png, width: 100, height: 100,
            framing: .fit, trigger: .manual, minimumFreeDiskGB: 0,
            collisionPolicy: .replace, cropTop: 0.22, cropBottom: 0.22
        )
        exporter.destinationURL = url
        exporter.start(); exporter.captureNext()
        exporter.offerFrame(try frame(width: 160, height: 90, gray: 0.9), frameIndex: 0)
        try await waitUntil("letterbox crop") { exporter.state == .idle || exporter.state == .failed }
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        let image = source.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
        XCTAssertNotNil(image)
        guard let image, let data = image.dataProvider?.data else { return }
        let bytes = CFDataGetBytePtr(data)!
        let topCenter = 2 * image.bytesPerRow + (image.width / 2) * 4
        XCTAssertGreaterThan(bytes[topCenter], 100, "crop should remove the Fit letterbox before filling output")
    }

    func testReviewPreviewUsesSameCropRendererWithoutDoubleApplying() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let exporter = OutputStreamExporter()
        exporter.configuration = ExportConfiguration(
            outputKind: .still, imageFormat: .png, width: 64, height: 48,
            framing: .stretch, trigger: .manual, minimumFreeDiskGB: 0,
            collisionPolicy: .replace
        )
        exporter.destinationURL = url
        exporter.start(); exporter.captureNext(); exporter.offerFrame(try splitFrame(), frameIndex: 0)
        try await waitUntil("review source") { exporter.state == .idle && exporter.reviewImage != nil }

        exporter.configuration.cropLeft = 0.5
        exporter.refreshReviewPreview()
        try await waitUntil("rendered crop preview") { !exporter.reviewIsLoading }

        guard let image = exporter.reviewImage else {
            return XCTFail("missing crop preview")
        }
        let rgba = centerRGBA(image)
        XCTAssertLessThan(rgba[0], 32)
        XCTAssertGreaterThan(rgba[2], 220)

        // Re-rendering the same preview must still start from the pre-export
        // compositor frame, rather than recursively cropping the preview.
        exporter.refreshReviewPreview()
        try await waitUntil("repeat crop preview") { !exporter.reviewIsLoading }
        guard let repeated = exporter.reviewImage else {
            return XCTFail("missing repeated crop preview")
        }
        let repeatedRGBA = centerRGBA(repeated)
        XCTAssertLessThan(repeatedRGBA[0], 32)
        XCTAssertGreaterThan(repeatedRGBA[2], 220)
    }
}
