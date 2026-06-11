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
