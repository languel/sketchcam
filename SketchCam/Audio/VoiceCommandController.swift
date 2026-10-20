import Combine
import Foundation
import SketchCamCore

enum VoiceCommandTarget: String, Codable, CaseIterable {
    case action, event, textPreset
}

struct VoiceCommandMapping: Identifiable, Codable, Equatable {
    var id = UUID()
    var phrase: String
    var target: VoiceCommandTarget = .event
    var value: String
}

/// Exact phrase grammar, shared by built-ins, custom mappings and preset names.
/// No fuzzy inference: a transcript must be a complete, committed mic utterance.
enum VoiceCommandText {
    static func normalized(_ text: String) -> String {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return words.joined(separator: " ").replacingOccurrences(of: "m c p", with: "mcp")
    }
}

final class VoiceCommandController: ObservableObject {
    @Published var listening = false {
        didSet {
            if !listening { armed = false; status = "Voice commands off" }
            else { status = "Listening · say ‘voice MCP on’" }
        }
    }
    @Published var armed = false {
        didSet { status = armed ? "Voice control armed" : "Voice control disarmed" }
    }
    @Published private(set) var status = "Voice commands off"
    @Published var targetLayerID: UUID?
    @Published var mappings: [VoiceCommandMapping] {
        didSet { if let data = try? JSONEncoder().encode(mappings) { defaults.set(data, forKey: Self.storageKey) } }
    }
    var onTextPreset: ((String, UUID?) -> String)?
    private let streams: TemporalStreamStore
    private let defaults: UserDefaults
    private static let storageKey = "sketchcam.voice-commands.v1"
    private var handled: [UUID] = []

    init(streams: TemporalStreamStore, defaults: UserDefaults = .standard) {
        self.streams = streams; self.defaults = defaults
        mappings = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([VoiceCommandMapping].self, from: $0) } ?? [
            VoiceCommandMapping(phrase: "voice next", target: .action, value: "text.advance"),
            VoiceCommandMapping(phrase: "voice reset", target: .action, value: "text.reset")
        ]
    }

    /// Called on the main queue, like keyboard, gesture and local MCP actions.
    func receive(_ phrase: TranscriptPhrase, source: AudioSourceStreamID) {
        guard listening, source == .microphone, phrase.committed, !handled.contains(phrase.id) else { return }
        handled.append(phrase.id)
        if handled.count > 256 { handled.removeFirst(handled.count - 256) }
        let text = VoiceCommandText.normalized(phrase.text)
        if text == "voice mcp on" { armed = true; status = "Voice control armed"; return }
        if text == "voice mcp off" { armed = false; status = "Voice control disarmed"; return }
        guard armed else { return }
        let matches = mappings.filter { !VoiceCommandText.normalized($0.phrase).isEmpty && VoiceCommandText.normalized($0.phrase) == text }
        if matches.count > 1 { status = "Duplicate voice phrase: \(text)"; return }
        if let mapping = matches.first {
            dispatch(mapping.target, value: mapping.value, phrase: phrase)
        } else if text.hasPrefix("voice preset ") {
            dispatch(.textPreset, value: String(text.dropFirst("voice preset ".count)), phrase: phrase)
        } else if text.hasPrefix("voice event ") {
            dispatch(.event, value: String(text.dropFirst("voice event ".count)), phrase: phrase)
        } else if text.hasPrefix("voice ") {
            status = "No matching voice command: \(text)"
        }
    }

    private func dispatch(_ target: VoiceCommandTarget, value: String, phrase: TranscriptPhrase) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { status = "Voice command has no target"; return }
        switch target {
        case .action:
            status = ShortcutRegistry.shared.invoke(id: value) ? "Action: \(value)" : "Action unavailable: \(value)"
        case .event:
            streams.emitVoice(name: value, phrase: phrase); status = "Event: \(value)"
        case .textPreset:
            status = onTextPreset?(value, targetLayerID) ?? "No Text preset target"
        }
    }
}
