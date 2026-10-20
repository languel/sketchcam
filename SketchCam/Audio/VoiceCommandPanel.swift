import SwiftUI
import SketchCamCore

struct VoiceCommandPanel: View {
    @ObservedObject var controller: VoiceCommandController
    @ObservedObject private var registry = ShortcutRegistry.shared
    var textLayers: [Node] = []

    init(controller: VoiceCommandController, textLayers: [Node] = []) {
        self.controller = controller
        self.textLayers = textLayers
    }

    var body: some View {
        DisclosureGroup("Voice commands") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Listen for commands", isOn: $controller.listening)
                    .help("Allow committed microphone speech to reach the local command router. Requires an active microphone and speech model. Recorded audio and provisional words never execute commands. Off at every launch.")
                Toggle("Armed", isOn: $controller.armed).disabled(!controller.listening)
                    .help("Say ‘voice MCP on’ to arm, or ‘voice MCP off’ to disarm. Runs mapped actions through the same registry as keyboard, gestures and local MCP; it does not start an AI agent or a new MCP server.")
                if !textLayers.isEmpty {
                    Picker("Preset layer", selection: $controller.targetLayerID) {
                        Text("First Text layer").tag(Optional<UUID>.none)
                        ForEach(textLayers) { Text($0.name).tag(Optional($0.id)) }
                    }.help("Target for ‘voice preset <name>’ and custom Text preset commands. Applies a saved or built-in Text look while preserving source bindings. Explicit missing targets report an error.")
                }
                ForEach($controller.mappings) { $mapping in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            TextField("Spoken phrase", text: $mapping.phrase)
                                .help("Match the entire microphone utterance, ignoring case and punctuation. Pause after speaking. Avoid duplicate phrases. ‘voice MCP on/off’ are reserved.")
                            Button { controller.mappings.removeAll { $0.id == mapping.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help("Delete this local voice mapping.")
                        }
                        HStack {
                            Picker("Target", selection: $mapping.target) {
                                Text("Action").tag(VoiceCommandTarget.action)
                                Text("Event").tag(VoiceCommandTarget.event)
                                Text("Text preset").tag(VoiceCommandTarget.textPreset)
                            }.labelsHidden().help("Action invokes an existing shared command; Event emits a named stream event; Text preset applies a look by exact name.")
                            if mapping.target == .action {
                                Picker("Action", selection: $mapping.value) {
                                    Text("Choose action…").tag("")
                                    if !mapping.value.isEmpty && !registry.actions.contains(where: { $0.id == mapping.value }) {
                                        Text(mapping.value).tag(mapping.value)
                                    }
                                    ForEach(registry.actions.sorted { $0.title < $1.title }) { action in
                                        Text("\(action.category) · \(action.title)").tag(action.id)
                                    }
                                }.labelsHidden().help("Existing keyboard/gesture/MCP command to run once when this phrase is recognized. Available actions depend on the app's registered commands.")
                            } else {
                                TextField(mapping.target == .event ? "Event name" : "Preset name", text: $mapping.value)
                                    .help("Event names match a Script layer's Voice event name. Presets match saved or built-in Text names, ignoring case and punctuation; ambiguous names are rejected.")
                            }
                        }
                    }.padding(.vertical, 2)
                }
                Button("Add phrase…") {
                    controller.mappings.append(VoiceCommandMapping(phrase: "", value: "next"))
                }.help("Create a saved local spoken-phrase mapping. New entries emit a named event until you choose another target.")
                Text(controller.status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .help("Latest command result. Built-ins: voice MCP on/off, voice preset <name>, voice event <name>. Commands execute only after a final recognition result, so a pause and decode time are expected.")
            }.padding(.top, 4)
        }
    }
}
