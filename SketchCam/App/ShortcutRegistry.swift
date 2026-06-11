import AppKit
import Foundation

struct KeyBinding: Codable, Equatable {
    /// Lowercased character or special name ("return", "escape", "space",
    /// "left", "right", "up", "down", "f1"…).
    var key: String
    /// Raw NSEvent.ModifierFlags, masked to cmd/opt/ctrl/shift.
    var modifiers: UInt

    static let relevantFlags: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers.intersection(Self.relevantFlags).rawValue
    }

    init?(event: NSEvent) {
        guard let name = Self.keyName(for: event) else { return nil }
        self.init(key: name, modifiers: event.modifierFlags)
    }

    var display: String {
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }

    static func keyName(for event: NSEvent) -> String? {
        switch event.keyCode {
        case 36: return "return"
        case 48: return "tab"
        case 49: return "space"
        case 53: return "escape"
        case 51: return "delete"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        default:
            guard let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty else { return nil }
            return String(chars.prefix(1))
        }
    }
}

struct AppAction: Identifiable {
    let id: String
    let title: String
    let category: String
    let handler: () -> Void
}

/// Central rebindable shortcut system. Features register actions with a
/// default binding; one NSEvent local monitor dispatches key-downs against
/// the current bindings (works in borderless/presentation windows and
/// regardless of control focus). User overrides persist in UserDefaults.
final class ShortcutRegistry: ObservableObject {
    static let shared = ShortcutRegistry()

    @Published private(set) var actions: [AppAction] = []
    @Published private(set) var bindings: [String: KeyBinding] = [:]
    /// Action currently capturing its next keypress in the Keys tab.
    @Published var recordingActionID: String?

    private var defaults: [String: KeyBinding] = [:]
    private var monitor: Any?
    private let storeKey = "io.github.languel.sketchcam.shortcuts"

    func start() {
        guard monitor == nil else { return }
        loadOverrides()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }
    }

    /// Idempotent: re-registering an id replaces its handler.
    func register(id: String, title: String, category: String, default defaultBinding: KeyBinding?, handler: @escaping () -> Void) {
        let action = AppAction(id: id, title: title, category: category, handler: handler)
        if let index = actions.firstIndex(where: { $0.id == id }) {
            actions[index] = action
        } else {
            actions.append(action)
        }
        if let defaultBinding {
            defaults[id] = defaultBinding
            if bindings[id] == nil, !overriddenClear.contains(id) {
                bindings[id] = defaultBinding
            }
        }
    }

    func setBinding(_ binding: KeyBinding?, for id: String) {
        if let binding {
            // steal from any conflicting action
            for (otherID, other) in bindings where other == binding && otherID != id {
                bindings[otherID] = nil
                overriddenClear.insert(otherID)
            }
            bindings[id] = binding
            overriddenClear.remove(id)
        } else {
            bindings[id] = nil
            overriddenClear.insert(id)
        }
        persist()
    }

    func resetBinding(for id: String) {
        bindings[id] = defaults[id]
        overriddenClear.remove(id)
        persist()
    }

    func isDefault(_ id: String) -> Bool {
        bindings[id] == defaults[id]
    }

    // MARK: - Dispatch

    private func handle(_ event: NSEvent) -> Bool {
        guard let pressed = KeyBinding(event: event) else { return false }

        if let recording = recordingActionID {
            if pressed.key == "escape", pressed.modifiers == 0 {
                recordingActionID = nil
            } else {
                setBinding(pressed, for: recording)
                recordingActionID = nil
            }
            return true
        }

        // Don't steal plain keystrokes from text fields.
        let flags = NSEvent.ModifierFlags(rawValue: pressed.modifiers)
        if flags.isDisjoint(with: [.command, .option, .control]),
           NSApp.keyWindow?.firstResponder is NSTextView {
            return false
        }

        guard let (id, _) = bindings.first(where: { $0.value == pressed }),
              let action = actions.first(where: { $0.id == id }) else {
            return false
        }
        action.handler()
        return true
    }

    // MARK: - Persistence

    /// IDs the user explicitly unbound (so a default doesn't reappear).
    private var overriddenClear: Set<String> = []

    private struct Store: Codable {
        var bindings: [String: KeyBinding]
        var cleared: [String]
    }

    private func persist() {
        let store = Store(bindings: bindings, cleared: Array(overriddenClear))
        if let data = try? JSONEncoder().encode(store) {
            UserDefaults.standard.set(data, forKey: storeKey)
        }
    }

    private func loadOverrides() {
        guard let data = UserDefaults.standard.data(forKey: storeKey),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        bindings.merge(store.bindings) { _, new in new }
        overriddenClear = Set(store.cleared)
        for id in overriddenClear where store.bindings[id] == nil {
            bindings[id] = nil
        }
    }
}
