import Foundation
import SketchCamCore

/// Only Portrait controls are serialized. Camera selection, effects, layers,
/// detection, marks, ink, and other drawing algorithms stay untouched on load.
struct PortraitConfiguration: Codable, Equatable {
    var enabled: Bool
    var approach: PortraitApproach
    var style: PortraitStyle
    var constructivist: Float?
    var abstraction: Float
    var shapeVariation: Float
    var expression: Float
    var follow: Float
    var flourish: Float
    var width: Float
    var widthVariation: Float
    var halo: Bool
    var color: RGBAColor
    var seed: Int
    var variation: Float
    var routeVariation: Float
    var segments: Int
    var connectorWidth: Float
    var separateFeatures: Bool?
    var lineFeatures: [PortraitLineFeature: Bool]?
    var outlineEnabled: Bool
    var poseBodyEnabled: Bool
    var bodyEnabled: Bool?
    var outlineStrength: Float
    var unifiedRoute: Bool
    var detailPriority: Float
    var subsample: Float
    var hairEnabled: Bool
    var hairStyle: PortraitHairStyle
    var hairdo: PortraitHairdo?
    var hairAmount: Float
    var hairExpansion: Float?
    var earsEnabled: Bool?
    var fingerContoursEnabled: Bool
    var fingerFullness: Float
    var mouthConnection: PortraitMouthConnection
    var innerMouthEnabled: Bool
    var browCenterlineEnabled: Bool?
    var mouthCenterlineEnabled: Bool?
    var fillEnabled: Bool
    var fillPalettized: Bool
    var fillPaletteSteps: Int
    var fillVariation: Float
    var fillOpacity: Float

    init(_ value: LandmarkSettings) {
        enabled = value.resolvedPortraitEnabled
        approach = value.resolvedPortraitApproach
        style = value.resolvedPortraitStyle
        constructivist = value.resolvedPortraitConstructivist
        abstraction = value.resolvedPortraitAbstraction
        shapeVariation = value.resolvedPortraitShapeVariation
        expression = value.resolvedPortraitExpression
        follow = value.resolvedPortraitFollow
        flourish = value.resolvedPortraitFlourish
        width = value.resolvedPortraitWidth
        widthVariation = value.resolvedPortraitWidthVariation
        halo = value.resolvedPortraitHalo
        color = value.resolvedPortraitColor
        seed = value.resolvedPortraitSeed
        variation = value.resolvedPortraitVariation
        routeVariation = value.resolvedPortraitRouteVariation
        segments = value.resolvedPortraitSegments
        connectorWidth = value.resolvedPortraitConnectorWidth
        separateFeatures = value.resolvedPortraitSeparateFeatures
        lineFeatures = value.portraitLineFeatures
        outlineEnabled = value.resolvedPortraitOutlineEnabled
        poseBodyEnabled = value.resolvedPortraitPoseBodyEnabled
        bodyEnabled = value.resolvedPortraitBodyEnabled
        outlineStrength = value.resolvedPortraitOutlineStrength
        unifiedRoute = value.resolvedPortraitUnifiedRoute
        detailPriority = value.resolvedPortraitDetailPriority
        subsample = value.resolvedPortraitSubsample
        hairEnabled = value.resolvedPortraitHairEnabled
        hairStyle = value.resolvedPortraitHairStyle
        hairdo = value.resolvedPortraitHairdo
        hairAmount = value.resolvedPortraitHairAmount
        hairExpansion = value.resolvedPortraitHairExpansion
        earsEnabled = value.resolvedPortraitEarsEnabled
        fingerContoursEnabled = value.resolvedPortraitFingerContoursEnabled
        fingerFullness = value.resolvedPortraitFingerFullness
        mouthConnection = value.resolvedPortraitMouthConnection
        innerMouthEnabled = value.resolvedPortraitInnerMouthEnabled
        browCenterlineEnabled = value.resolvedPortraitBrowCenterlineEnabled
        mouthCenterlineEnabled = value.resolvedPortraitMouthCenterlineEnabled
        fillEnabled = value.resolvedPortraitFillEnabled
        fillPalettized = value.resolvedPortraitFillPalettized
        fillPaletteSteps = value.resolvedPortraitFillPaletteSteps
        fillVariation = value.resolvedPortraitFillVariation
        fillOpacity = value.resolvedPortraitFillOpacity
    }

    func apply(to value: inout LandmarkSettings) {
        value.portraitEnabled = enabled
        value.portraitApproach = approach
        value.portraitStyle = style
        value.portraitConstructivist = constructivist ?? 0
        value.portraitAbstraction = abstraction
        value.portraitShapeVariation = shapeVariation
        value.portraitExpression = expression
        value.portraitFollow = follow
        value.portraitFlourish = flourish
        value.portraitWidth = width
        value.portraitWidthVariation = widthVariation
        value.portraitHalo = halo
        value.portraitColor = color
        value.portraitSeed = seed
        value.portraitVariation = variation
        value.portraitRouteVariation = routeVariation
        value.portraitSegments = segments
        value.portraitConnectorWidth = connectorWidth
        value.portraitSeparateFeatures = separateFeatures ?? false
        value.portraitLineFeatures = lineFeatures
        value.portraitOutlineEnabled = outlineEnabled
        value.portraitPoseBodyEnabled = poseBodyEnabled
        value.portraitBodyEnabled = bodyEnabled ?? true
        value.portraitOutlineStrength = outlineStrength
        value.portraitUnifiedRoute = unifiedRoute
        value.portraitDetailPriority = detailPriority
        value.portraitSubsample = subsample
        value.portraitHairEnabled = hairEnabled
        value.portraitHairStyle = hairStyle
        value.portraitHairdo = hairdo ?? .rounded
        value.portraitHairAmount = hairAmount
        value.portraitHairExpansion = hairExpansion ?? 0
        value.portraitEarsEnabled = earsEnabled ?? true
        value.portraitFingerContoursEnabled = fingerContoursEnabled
        value.portraitFingerFullness = fingerFullness
        value.portraitMouthConnection = mouthConnection
        value.portraitInnerMouthEnabled = innerMouthEnabled
        value.portraitBrowCenterlineEnabled = browCenterlineEnabled ?? false
        value.portraitMouthCenterlineEnabled = mouthCenterlineEnabled ?? false
        value.portraitFillEnabled = fillEnabled
        value.portraitFillPalettized = fillPalettized
        value.portraitFillPaletteSteps = fillPaletteSteps
        value.portraitFillVariation = fillVariation
        value.portraitFillOpacity = fillOpacity
    }
}

struct PortraitPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var configuration: PortraitConfiguration

    init(id: UUID = UUID(), name: String, configuration: PortraitConfiguration) {
        self.id = id
        self.name = name
        self.configuration = configuration
    }
}

struct PortraitPresetFile: Codable {
    let format: String
    let version: Int
    let name: String
    let configuration: PortraitConfiguration

    init(_ preset: PortraitPreset) {
        format = "SketchCamPortrait"
        version = 1
        name = preset.name
        configuration = preset.configuration
    }
}

enum PortraitPresetError: LocalizedError {
    case unsupportedFormat

    var errorDescription: String? {
        "This file is not a supported SketchCam Portrait preset."
    }
}

final class PortraitPresetStore: ObservableObject {
    @Published private(set) var presets: [PortraitPreset] = []
    private let key = "sketchcam.portrait-presets.v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([PortraitPreset].self, from: data) {
            presets = saved
        }
    }

    @discardableResult
    func save(name: String, landmarks: LandmarkSettings) -> PortraitPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Portrait \(presets.count + 1)" : trimmed
        let configuration = PortraitConfiguration(landmarks)
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            presets[index].configuration = configuration
            persist()
            return presets[index]
        }
        let preset = PortraitPreset(name: finalName, configuration: configuration)
        presets.append(preset)
        persist()
        return preset
    }

    func delete(_ preset: PortraitPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    func export(_ preset: PortraitPreset) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(PortraitPresetFile(preset))
    }

    @discardableResult
    func importPreset(_ data: Data) throws -> PortraitPreset {
        let file = try JSONDecoder().decode(PortraitPresetFile.self, from: data)
        guard file.format == "SketchCamPortrait", file.version == 1 else {
            throw PortraitPresetError.unsupportedFormat
        }
        let trimmed = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = trimmed.isEmpty ? "Imported Portrait" : trimmed
        var name = base
        var suffix = 2
        while presets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        let preset = PortraitPreset(name: name, configuration: file.configuration)
        presets.append(preset)
        persist()
        return preset
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: key)
    }
}
