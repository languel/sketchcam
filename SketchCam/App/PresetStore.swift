import Foundation
import SketchCamCore

/// A named snapshot of the ENTIRE `ProcessingSettings` (effects, threshold,
/// background, and the whole landmark/drawing/detection config). On recall the
/// user chooses to apply just the render style (the `landmarks` portion) or the
/// whole state.
struct DrawingPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var settings: ProcessingSettings

    init(id: UUID = UUID(), name: String, settings: ProcessingSettings) {
        self.id = id
        self.name = name
        self.settings = settings
    }
}

/// Persists presets to UserDefaults as JSON. Saving with an existing name
/// overwrites that preset.
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [DrawingPreset] = []

    private let key = "sketchcam.presets.v2"
    private let defaults = UserDefaults.standard

    init() { load() }

    @discardableResult
    func save(name: String, settings: ProcessingSettings) -> DrawingPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Preset \(presets.count + 1)" : trimmed
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            presets[index].settings = settings
            persist()
            return presets[index]
        }
        let preset = DrawingPreset(name: finalName, settings: settings)
        presets.append(preset)
        persist()
        return preset
    }

    func delete(_ preset: DrawingPreset) {
        presets.removeAll { $0.id == preset.id }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: key)
    }

    private func load() {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([DrawingPreset].self, from: data) else { return }
        presets = decoded
    }
}
