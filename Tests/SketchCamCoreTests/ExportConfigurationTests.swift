import XCTest
@testable import SketchCamCore

final class ExportConfigurationTests: XCTestCase {
    func testRatesClampToSupportedRange() {
        var value = ExportConfiguration(captureFPS: 0, playbackFPS: 900, simulationFPS: 0)
        value.clamp()
        XCTAssertEqual(value.captureFPS, 0.001)
        XCTAssertEqual(value.playbackFPS, 360)
        XCTAssertEqual(value.simulationFPS, 1)
    }

    func testCodecConstrainsAlphaAndContainer() {
        var opaque = ExportConfiguration(movieCodec: .h264, includeAlpha: true)
        opaque.clamp()
        XCTAssertFalse(opaque.includeAlpha)
        var proRes = ExportConfiguration(movieCodec: .proRes4444, container: .mp4, includeAlpha: true)
        proRes.clamp()
        XCTAssertEqual(proRes.container, .mov)
        XCTAssertTrue(proRes.includeAlpha)
    }

    func testConfigurationRoundTrip() throws {
        let value = ExportConfiguration(outputKind: .imageSequence, trigger: .washEnd,
                                        gates: [CaptureGate(kind: .inkPixelsChanging)])
        XCTAssertEqual(try JSONDecoder().decode(ExportConfiguration.self,
                                                from: JSONEncoder().encode(value)), value)
    }

    func testExtremePlaybackRatesStayMonotonic() {
        XCTAssertEqual(ExportTiming.presentationTime(frameIndex: 1, fps: 0.001), 1_000, accuracy: 0.0001)
        var previous = -1.0
        for index in 0..<1_000 {
            let time = ExportTiming.presentationTime(frameIndex: index, fps: 360)
            XCTAssertGreaterThan(time, previous)
            previous = time
        }
    }

    func testGateComparisonsAreDeterministicAtEdges() {
        XCTAssertTrue(ExportTiming.condition(0.5, comparison: .inside, lower: 0.5, upper: 1))
        XCTAssertTrue(ExportTiming.condition(1, comparison: .inside, lower: 0.5, upper: 1))
        XCTAssertFalse(ExportTiming.condition(0.5, comparison: .outside, lower: 0.5, upper: 1))
        XCTAssertTrue(ExportTiming.condition(1.01, comparison: .outside, lower: 0.5, upper: 1))
    }
}
