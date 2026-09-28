import Foundation
import XCTest
@testable import SketchCam
import SketchCamCore

final class PortraitPresetTests: XCTestCase {
    func testPortraitPresetRoundTripTouchesOnlyPortraitSettings() throws {
        let suite = "sketchcam.portrait-preset-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        var source = LandmarkSettings()
        source.portraitEnabled = true
        source.portraitSeed = 83147
        source.portraitSegments = 12
        source.portraitSubsample = 3.5
        source.portraitPoseBodyEnabled = true
        source.portraitBodyEnabled = false
        source.portraitLineFeatures = [.eyes: false, .hands: true]
        source.portraitFingerContoursEnabled = true
        source.portraitBrowCenterlineEnabled = true
        source.portraitMouthCenterlineEnabled = true
        source.portraitConstructivist = 0.8
        source.portraitFillEnabled = true
        source.portraitFillPalettized = true
        source.portraitFillVariation = 0.7

        let store = PortraitPresetStore(defaults: defaults)
        let saved = store.save(name: "Painted", landmarks: source)
        let data = try store.export(saved)
        let importedStore = PortraitPresetStore(defaults: defaults)
        XCTAssertEqual(importedStore.presets.count, 1)
        let imported = try importedStore.importPreset(data)
        XCTAssertEqual(imported.name, "Painted 2")
        XCTAssertEqual(imported.configuration, PortraitConfiguration(source))

        var target = LandmarkSettings()
        target.yarnEnabled = true
        target.trackHands = false
        imported.configuration.apply(to: &target)
        XCTAssertEqual(PortraitConfiguration(target), PortraitConfiguration(source))
        XCTAssertFalse(target.portraitLineVisible(.eyes))
        XCTAssertTrue(target.portraitLineVisible(.hands))
        XCTAssertTrue(target.resolvedPortraitBrowCenterlineEnabled)
        XCTAssertTrue(target.resolvedPortraitMouthCenterlineEnabled)
        XCTAssertFalse(target.resolvedPortraitBodyEnabled)
        XCTAssertEqual(target.resolvedPortraitConstructivist, 0.8)
        XCTAssertTrue(target.yarnEnabled)
        XCTAssertFalse(target.trackHands)
    }
}
