import AppKit
import SwiftUI
import SketchCamCore
import UniformTypeIdentifiers

struct TextPresetPanel: View {
    @Binding var configuration: TextLayerConfig
    @StateObject private var store = TextPresetStore()
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        DisclosureGroup("Text presets") {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Menu("Built-in looks") {
                        ForEach(TextPresetStore.builtins) { preset in
                            Button(preset.name) { configuration = preset.configuration }.help("Apply this built-in Text look to the selected layer, preserving its content and audio bindings.")
                        }
                    }.help("Apply typography, drawing and timing to this Text layer; keep its source bindings.")
                    Button("Import…") { importPreset() }.help("Import a SketchCam Text JSON preset under a unique name and apply it to this layer.")
                }
                HStack {
                    TextField("Name this look", text: $name).onSubmit(save).help("Name for saving this layer's typography, timing, silence and motion configuration.")
                    Button("Save", action: save).help("Save this Text look locally. The same name replaces its earlier save; other layers, source bindings and script text are not saved.")
                }
                ForEach(store.presets) { preset in
                    HStack(spacing: 6) {
                        Button(preset.name) { configuration = preset.configuration }.buttonStyle(.borderless).help("Apply this saved Text configuration to the selected layer; source bindings and other layers are preserved.")
                        Spacer(minLength: 2)
                        Button { store.save(name: preset.name, configuration: configuration) } label: {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }.help("Replace this saved Text look with the current settings.")
                        Button { exportPreset(preset) } label: { Image(systemName: "square.and.arrow.up") }
                            .help("Export Text preset as JSON.")
                        Button { store.delete(preset) } label: { Image(systemName: "trash") }
                            .help("Delete saved Text preset.")
                    }.buttonStyle(.borderless)
                }
            }.padding(.top, 4)
        }
        .alert("Text preset", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }
    private func save() { store.save(name: name, configuration: configuration); name = "" }
    private func exportPreset(_ preset: TextPreset) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = preset.name + ".json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try store.export(preset).write(to: url, options: .atomic) }
        catch { self.error = error.localizedDescription }
    }
    private func importPreset() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do { configuration = try store.importPreset(Data(contentsOf: url)).configuration }
        catch { self.error = error.localizedDescription }
    }
}
