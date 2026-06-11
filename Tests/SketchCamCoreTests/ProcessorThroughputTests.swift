import CoreImage
import CoreMedia
import XCTest
@testable import SketchCamCore
import SketchCamShared

/// Headless throughput guard for the frame-processing hot path.
/// Prints ms/frame and fails if the processor cannot sustain real-time rates;
/// thresholds are intentionally loose (CI machines vary) — the printed numbers
/// are the real instrument, tracked in notes/performance-plan.md.
final class ProcessorThroughputTests: XCTestCase {
    private func report(_ line: String) {
        print(line)
        // xcodebuild swallows test stdout; keep a copy where the perf scripts
        // and notes/performance-plan.md workflow can read it.
        let url = URL(fileURLWithPath: "/tmp/sketchcam-perf.txt")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        try? (existing + line + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func throughputMillis(
        processor: CoreImageFrameProcessor,
        settings: ProcessingSettings,
        format: FrameFormat,
        frames: Int = 60
    ) throws -> Double {
        let input = try TestPatternGenerator.makeFrame(format: format, frameIndex: 0).pixelBuffer
        // warm-up: kernel compilation, first-render setup
        for index in 0..<5 {
            _ = try processor.process(pixelBuffer: input, settings: settings, outputFormat: format, frameIndex: index, timestamp: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<frames {
            _ = try processor.process(pixelBuffer: input, settings: settings, outputFormat: format, frameIndex: index, timestamp: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        return elapsed / Double(frames) * 1_000
    }

    func testFullEffectThroughput1080p() throws {
        let millis = try throughputMillis(
            processor: CoreImageFrameProcessor(),
            settings: ProcessingSettings(),
            format: SketchCamFormats.fullHD
        )
        report("PERF full-effect 1080p: \(String(format: "%.2f", millis)) ms/frame (\(String(format: "%.1f", 1_000 / millis)) fps)")
        XCTAssertLessThan(millis, 33.3, "full effect chain at 1080p must sustain 30 fps")
    }

    func testThresholdOnlyThroughput1080p() throws {
        var settings = ProcessingSettings()
        settings.edgeStrength = 0
        let millis = try throughputMillis(
            processor: CoreImageFrameProcessor(),
            settings: settings,
            format: SketchCamFormats.fullHD
        )
        report("PERF threshold-only 1080p: \(String(format: "%.2f", millis)) ms/frame (\(String(format: "%.1f", 1_000 / millis)) fps)")
        XCTAssertLessThan(millis, 33.3)
    }

    func testFullEffectThroughput720p() throws {
        let millis = try throughputMillis(
            processor: CoreImageFrameProcessor(),
            settings: ProcessingSettings(),
            format: SketchCamFormats.hd
        )
        report("PERF full-effect 720p: \(String(format: "%.2f", millis)) ms/frame (\(String(format: "%.1f", 1_000 / millis)) fps)")
        XCTAssertLessThan(millis, 33.3)
    }
}

extension ProcessorThroughputTests {
    func testPassthroughThroughput1080p() throws {
        var settings = ProcessingSettings()
        settings.effectsEnabled = false
        let millis = try throughputMillis(
            processor: CoreImageFrameProcessor(),
            settings: settings,
            format: SketchCamFormats.fullHD
        )
        report("PERF passthrough 1080p: \(String(format: "%.2f", millis)) ms/frame (\(String(format: "%.1f", 1_000 / millis)) fps)")
        XCTAssertLessThan(millis, 33.3)
    }

    func testFastProcessingThroughput1080p() throws {
        var settings = ProcessingSettings()
        settings.processingQuality = .fast
        let millis = try throughputMillis(
            processor: CoreImageFrameProcessor(),
            settings: settings,
            format: SketchCamFormats.fullHD
        )
        report("PERF full-effect@540p->1080p: \(String(format: "%.2f", millis)) ms/frame (\(String(format: "%.1f", 1_000 / millis)) fps)")
        XCTAssertLessThan(millis, 33.3)
    }
}

extension ProcessorThroughputTests {
    /// Composite cost of a cached overlay layer (Phase 2 hot-path addition).
    func testOverlayCompositeThroughput1080p() throws {
        let processor = CoreImageFrameProcessor()
        let format = SketchCamFormats.fullHD
        let settings = ProcessingSettings()
        let input = try TestPatternGenerator.makeFrame(format: format, frameIndex: 0).pixelBuffer
        let overlaySource = try TestPatternGenerator.makeFrame(format: SketchCamFormats.hd, frameIndex: 3).pixelBuffer
        let overlay = CIImage(cvPixelBuffer: overlaySource)
            .transformed(by: CGAffineTransform(scaleX: 1.5, y: 1.5))
            .cropped(to: CGRect(origin: .zero, size: format.size))

        for index in 0..<5 {
            _ = try processor.process(pixelBuffer: input, settings: settings, outputFormat: format, frameIndex: index, timestamp: CMTime(value: CMTimeValue(index), timescale: 30), overlay: overlay)
        }
        let frames = 60
        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<frames {
            _ = try processor.process(pixelBuffer: input, settings: settings, outputFormat: format, frameIndex: index, timestamp: CMTime(value: CMTimeValue(index), timescale: 30), overlay: overlay)
        }
        let millis = (CFAbsoluteTimeGetCurrent() - start) / Double(frames) * 1_000
        report("PERF full-effect+overlay 1080p: \(String(format: "%.2f", millis)) ms/frame (\(String(format: "%.1f", 1_000 / millis)) fps)")
        XCTAssertLessThan(millis, 33.3)
    }
}

extension ProcessorThroughputTests {
    func testKeyedSolidBackgroundThroughput1080p() throws {
        let processor = CoreImageFrameProcessor()
        let format = SketchCamFormats.fullHD
        var settings = ProcessingSettings()
        settings.backgroundMode = .solid
        settings.outlineThickness = 8
        settings.outlineColor = RGBAColor(red: 1, green: 0.2, blue: 0.1)
        let input = try TestPatternGenerator.makeFrame(format: format, frameIndex: 0).pixelBuffer
        let matte = CIImage(color: CIColor(red: 1, green: 1, blue: 1))
            .cropped(to: CGRect(x: 0, y: 0, width: 512, height: 288))

        for index in 0..<5 {
            _ = try processor.process(pixelBuffer: input, settings: settings, outputFormat: format, frameIndex: index, timestamp: CMTime(value: CMTimeValue(index), timescale: 30), overlay: nil, matte: matte)
        }
        let frames = 60
        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<frames {
            _ = try processor.process(pixelBuffer: input, settings: settings, outputFormat: format, frameIndex: index, timestamp: CMTime(value: CMTimeValue(index), timescale: 30), overlay: nil, matte: matte)
        }
        let millis = (CFAbsoluteTimeGetCurrent() - start) / Double(frames) * 1_000
        report("PERF keyed+solid-bg+thick-outline 1080p: \(String(format: "%.2f", millis)) ms/frame (\(String(format: "%.1f", 1_000 / millis)) fps)")
        XCTAssertLessThan(millis, 33.3)
    }

    func testTransparentDoodleOnlyThroughput1080p() throws {
        let processor = CoreImageFrameProcessor()
        let format = SketchCamFormats.fullHD
        var settings = ProcessingSettings()
        settings.inputLayerEnabled = false
        settings.thresholdEnabled = false
        settings.backgroundMode = .transparent
        settings.outlineThickness = 4
        let input = try TestPatternGenerator.makeFrame(format: format, frameIndex: 0).pixelBuffer

        for index in 0..<5 {
            _ = try processor.process(pixelBuffer: input, settings: settings, outputFormat: format, frameIndex: index, timestamp: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        let frames = 60
        let start = CFAbsoluteTimeGetCurrent()
        for index in 0..<frames {
            _ = try processor.process(pixelBuffer: input, settings: settings, outputFormat: format, frameIndex: index, timestamp: CMTime(value: CMTimeValue(index), timescale: 30))
        }
        let millis = (CFAbsoluteTimeGetCurrent() - start) / Double(frames) * 1_000
        report("PERF outline-on-alpha 1080p: \(String(format: "%.2f", millis)) ms/frame (\(String(format: "%.1f", 1_000 / millis)) fps)")
        XCTAssertLessThan(millis, 33.3)
    }
}
