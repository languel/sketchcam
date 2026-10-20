import Combine
import Foundation
import SketchCamCore

/// A Text look includes its drawing, typography and timing configuration, but
/// never captures source bindings, scripts, audio devices or another layer.
struct TextPreset: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var configuration: TextLayerConfig
}

private struct TextPresetFile: Codable {
    var format = "SketchCamText"
    var version = 1
    var name: String
    var configuration: TextLayerConfig
}

enum TextPresetError: LocalizedError {
    case unsupportedFormat
    var errorDescription: String? { "This file is not a supported SketchCam Text preset." }
}

final class TextPresetStore: ObservableObject {
    @Published private(set) var presets: [TextPreset] = []
    private let defaults: UserDefaults
    private let key = "sketchcam.text-presets.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key), let decoded = try? JSONDecoder().decode([TextPreset].self, from: data) {
            presets = decoded
        }
    }

    @discardableResult
    func save(name: String, configuration: TextLayerConfig) -> TextPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Text \(presets.count + 1)" : trimmed
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            presets[index].configuration = configuration; persist(); return presets[index]
        }
        let preset = TextPreset(name: name, configuration: configuration)
        presets.append(preset); persist(); return preset
    }
    func delete(_ preset: TextPreset) { presets.removeAll { $0.id == preset.id }; persist() }
    func export(_ preset: TextPreset) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(TextPresetFile(name: preset.name, configuration: preset.configuration))
    }
    @discardableResult
    func importPreset(_ data: Data) throws -> TextPreset {
        guard data.count < 1_000_000 else { throw TextPresetError.unsupportedFormat }
        let file = try JSONDecoder().decode(TextPresetFile.self, from: data)
        guard file.format == "SketchCamText", file.version == 1 else { throw TextPresetError.unsupportedFormat }
        let base = file.name.trimmingCharacters(in: .whitespacesAndNewlines)
        var name = base.isEmpty ? "Imported Text" : base
        var suffix = 2
        while presets.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "\(base.isEmpty ? "Imported Text" : base) \(suffix)"; suffix += 1
        }
        return save(name: name, configuration: file.configuration)
    }
    private func persist() { if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: key) } }

    static let builtins: [TextPreset] = {
        var subtitle = TextLayerConfig()
        subtitle.style = .typeOn; subtitle.alignment = .left
        subtitle.paddingHorizontal = 0.4; subtitle.paddingVertical = 0.3
        subtitle.lineLimit = 2; subtitle.fontSize = 0.055; subtitle.y = 0.86
        var flash = TextLayerConfig()
        flash.style = .subtitles; flash.fontName = "Monaco"; flash.letterCase = .uppercase
        flash.alignment = .center; flash.verticalAlignment = .center
        flash.height = 1; flash.width = 1; flash.x = 0.5; flash.y = 0.5
        flash.fontFit = .fit; flash.lineLimit = 4; flash.wordsPerCue = 4
        flash.cornerRadius = 0; flash.paddingHorizontal = 0.2; flash.paddingVertical = 0.2
        flash.color = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        flash.background = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        flash.trigger = .timer; flash.interval = 0.25
        var headline = flash
        headline.fontName = "HelveticaNeue-Bold"; headline.bold = true
        headline.alignment = .justified; headline.justifyLastLine = true
        headline.captionLifetime = .untilReplaced
        headline.letterSpacing = 0.03; headline.wordsPerCue = 3
        headline.background = RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)
        headline.color = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
        var typeOn = subtitle
        typeOn.fontName = "Menlo-Regular"; typeOn.fontSize = 0.045
        typeOn.background.alpha = 0; typeOn.lineLimit = 4; typeOn.y = 0.5
        var fade = TextLayerConfig()
        fade.style = .trail; fade.fadeSeconds = 2.5; fade.fontName = "HelveticaNeue-Medium"
        fade.background.alpha = 0
        let looks: [(String, TextLayerConfig)] = [
            ("Bottom captions", subtitle), ("Monochrome flash", flash),
            ("Justified headline", headline), ("Typewriter", typeOn), ("Fading words", fade)
        ]
        return looks.enumerated().map { index, look in
            TextPreset(id: UUID(uuidString: String(format: "A8100000-0000-4000-8000-%012d", index + 1))!,
                       name: look.0, configuration: look.1)
        }
    }()
}
