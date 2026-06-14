import Foundation
import SketchCamCore

/// A saved drawing + detection configuration: a named snapshot of the whole
/// `LandmarkSettings` (Marks toggles, all three drawing algorithms, and the
/// detection params).
struct DrawingPreset: Codable, Identifiable {
    var id: UUID
    var name: String
    var landmarks: LandmarkSettings

    init(id: UUID = UUID(), name: String, landmarks: LandmarkSettings) {
        self.id = id
        self.name = name
        self.landmarks = landmarks
    }
}

/// Persists presets to UserDefaults as JSON. Saving with an existing name
/// overwrites that preset.
final class PresetStore: ObservableObject {
    @Published private(set) var presets: [DrawingPreset] = []

    private let key = "sketchcam.presets.v1"
    private let defaults = UserDefaults.standard

    init() { load() }

    @discardableResult
    func save(name: String, landmarks: LandmarkSettings) -> DrawingPreset {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? "Preset \(presets.count + 1)" : trimmed
        if let index = presets.firstIndex(where: { $0.name.caseInsensitiveCompare(finalName) == .orderedSame }) {
            presets[index].landmarks = landmarks
            persist()
            return presets[index]
        }
        let preset = DrawingPreset(name: finalName, landmarks: landmarks)
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
