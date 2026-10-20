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
    private let toolBridge = LocalToolBridge()
    private(set) var isInvokingExternally = false

    /// Shared command surface for keyboard shortcuts, motion sequences and
    /// local MCP clients. All handlers are UI actions and run on the main queue.
    var toolCatalog: [(id: String, title: String, category: String)] {
        actions.map { ($0.id, $0.title, $0.category) }
            .sorted { $0.id < $1.id }
    }

    @discardableResult
    func invoke(id: String) -> Bool {
        guard let action = actions.first(where: { $0.id == id }) else { return false }
        isInvokingExternally = true
        defer { isInvokingExternally = false }
        action.handler()
        return true
    }

    func start() {
        guard monitor == nil else { return }
        loadOverrides()
        toolBridge.start(registry: self)
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
        toolBridge.publishCatalog(registry: self)
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
        if id == "motion.arm.toggle", event.isARepeat { return true }
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

/// Private, local-only request/reply bridge for the stdio MCP helper. Requests
/// are atomically renamed into place; no app UI command runs off-main-thread.
private final class LocalToolBridge {
    private var timer: Timer?
    private var lastHeartbeat = 0.0
    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("SketchCam/mcp-bridge", isDirectory: true)

    func start(registry: ShortcutRegistry) {
        guard timer == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self, weak registry] _ in
                guard let self, let registry else { return }
                self.poll(registry: registry)
            }
            publishCatalog(registry: registry)
        } catch {
            NSLog("SketchCam MCP bridge unavailable: %@", String(describing: error))
        }
    }

    func publishCatalog(registry: ShortcutRegistry) {
        guard timer != nil else { return }
        let catalog = registry.toolCatalog.map {
            ["id": $0.id, "title": $0.title, "category": $0.category]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: catalog) else { return }
        try? data.write(to: directory.appendingPathComponent("catalog.json"), options: .atomic)
    }

    private func poll(registry: ShortcutRegistry) {
        let now = Date().timeIntervalSince1970
        if now - lastHeartbeat >= 1 {
            lastHeartbeat = now
            let heartbeat = directory.appendingPathComponent("heartbeat")
            try? Data(String(now).utf8).write(to: heartbeat, options: .atomic)
        }
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: nil) else { return }
        for request in files where request.pathExtension == "request" {
            let stem = request.deletingPathExtension().lastPathComponent
            guard UUID(uuidString: stem) != nil else { continue }
            let claimed = directory.appendingPathComponent("\(stem).processing")
            guard (try? FileManager.default.moveItem(at: request, to: claimed)) != nil else { continue }
            let id = (try? Data(contentsOf: claimed))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["id"]
            let ok = id.map { registry.invoke(id: $0) } ?? false
            if let data = try? JSONSerialization.data(withJSONObject: ["ok": ok]) {
                try? data.write(to: directory.appendingPathComponent("\(stem).response"), options: .atomic)
            }
            try? FileManager.default.removeItem(at: claimed)
        }
    }
}
