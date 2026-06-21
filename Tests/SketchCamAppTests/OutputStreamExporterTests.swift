import AVFoundation
import CoreImage
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

    private func waitUntil(_ description: String, timeout: TimeInterval = 8,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for \(description)")
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
}
