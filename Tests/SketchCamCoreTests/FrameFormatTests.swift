import CoreVideo
import XCTest
@testable import SketchCamCore
@testable import SketchCamShared

final class FrameFormatTests: XCTestCase {
    func testPresetOrderAndDefault() {
        XCTAssertEqual(SketchCamFormats.all.map(\.id), ["360p", "720p", "1080p"])
        XCTAssertEqual(SketchCamFormats.defaultFormat, SketchCamFormats.fullHD)
        XCTAssertEqual(SketchCamFormats.fullHD.frameRate, 30)
        XCTAssertEqual(SketchCamFormats.fullHD.pixelFormat, kCVPixelFormatType_32BGRA)
    }

    func testDefaultProcessingSettingsMatchPhaseOneDefaults() {
        let settings = ProcessingSettings()
        XCTAssertEqual(settings.threshold, 0.52, accuracy: 0.001)
        XCTAssertEqual(settings.edgeStrength, 0.25, accuracy: 0.001)
        XCTAssertTrue(settings.mirror)
        XCTAssertFalse(settings.invert)
        XCTAssertFalse(settings.testPatternMode)
    }
}

