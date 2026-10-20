import AppKit
import SwiftUI
import SketchCamCore
import UniformTypeIdentifiers

struct ScriptSourcePanel: View {
    @ObservedObject var model: SketchCamViewModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button("Open text…") { openText() }.help("Load a UTF-8 plain-text file into the shared Script source.")
                Button("Reset") { model.audio.streams.resetText() }.help("Reset every Text playback cursor and word animation to its beginning.")
                Button("Next") { model.audio.streams.emit(.manual); model.audio.streams.emit(.gesture) }.help("Advance Text layers listening for the manual or gesture command.")
            }
            TextEditor(text: Binding(get: { model.settings.textScript ?? "" }, set: { model.settings.textScript = $0 }))
                .font(.system(size: 12)).frame(minHeight: 160)
                .help("Shared text source. Each Text layer has its own cursor and advance trigger.")
        }.controlSize(.small).padding(8)
    }
    private func openText() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.plainText]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            let scope = url.startAccessingSecurityScopedResource()
            defer { if scope { url.stopAccessingSecurityScopedResource() } }
            do { model.settings.textScript = try String(contentsOf: url, encoding: .utf8) }
            catch { NSAlert(error: error).runModal() }
        }
    }
}

struct TextDrawingPanel: View {
    @ObservedObject var model: SketchCamViewModel
    @State private var selected: UUID?
    private var nodes: [Node] { model.settings.layerGraph?.nodes.filter { $0.kind.family == "text" } ?? [] }
    private var selectedNode: Node? { nodes.first { $0.id == selected } ?? nodes.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if !nodes.isEmpty {
                    Picker("Layer", selection: Binding(get: { selectedNode?.id }, set: { selected = $0 })) {
                        ForEach(nodes) { Text($0.name).tag(Optional($0.id)) }
                    }.help("Choose which Text layer these controls and presets edit.")
                }
                Button { model.addTextLayer(); selected = nodes.last?.id } label: { Image(systemName: "plus") }
                    .help("Add Text drawing layer")
            }
            if let node = selectedNode, case .text = node.kind {
                controls(node)
            } else {
                Text("Add a Text layer").font(.caption).foregroundStyle(.secondary)
            }
            VoiceCommandPanel(controller: model.audio.voiceCommands, textLayers: nodes)
        }.controlSize(.small).padding(8)
    }

    @ViewBuilder private func controls(_ node: Node) -> some View {
        TextPresetPanel(configuration: config(node, \.self))
        Picker("Content", selection: input(node, index: 0)) {
            Text("Default (Script)").tag(PortBinding.none)
            Text("Script").tag(PortBinding.source(.script))
            Text("Microphone speech").tag(PortBinding.source(.microphoneText))
            Text("Audio File speech").tag(PortBinding.source(.recordedAudioText))
        }.help("Choose the script or speech stream that supplies words. This is separate from Audio control, which supplies loudness modulation.")
        Picker("Audio control", selection: input(node, index: 1)) {
            Text("None").tag(PortBinding.none)
            Text("Microphone").tag(PortBinding.source(.microphone))
            Text("Audio File").tag(PortBinding.source(.recordedAudio))
        }.help("Audio features for Voice scale and loudness-triggered script advances. It does not select the transcript; use Content for that.")
        Picker("Drawing", selection: config(node, \.style)) {
            Text("Subtitle cues").tag(TextDrawingStyle.subtitles)
            Text("N words").tag(TextDrawingStyle.word)
            Text("Build phrase").tag(TextDrawingStyle.build)
            Text("Type-on captions").tag(TextDrawingStyle.typeOn)
            Text("Fading words").tag(TextDrawingStyle.trail)
        }.help(drawingHelp(value(node).style))
        if node.inputs.first == .source(.script) || node.inputs.first == PortBinding.none {
            Picker("Advance on", selection: config(node, \.trigger)) {
                Text("Next button / command").tag(TextAdvanceTrigger.manual)
                Text("Gesture command").tag(TextAdvanceTrigger.gesture)
                Text("Stroke start").tag(TextAdvanceTrigger.strokeStart)
                Text("Stroke end").tag(TextAdvanceTrigger.strokeEnd)
                Text("Loudness crossing").tag(TextAdvanceTrigger.loudness)
                Text("Timer").tag(TextAdvanceTrigger.timer)
                Text("Voice event").tag(TextAdvanceTrigger.voice)
            }.help("The event that reveals the next script word/cue. Stroke edges, gesture commands and loudness use existing shared input streams.")
            if value(node).trigger == .voice {
                TextField("Event name", text: Binding(
                    get: { value(node).voiceEventName ?? "next" },
                    set: { config(node, \.voiceEventName).wrappedValue = $0 }
                )).help("Advance once per matching event: say ‘voice event next’, map a custom phrase, or use annotation.clicking / annotation.laughter for finalized model annotations. Annotation events work without arming voice commands and can come from microphone or file audio.")
            }
            if value(node).trigger == .loudness {
                HStack {
                    Text("Threshold")
                    Slider(value: config(node, \.threshold), in: 0.005...0.5)
                    Text(String(format: "%.3f", value(node).threshold)).monospacedDigit()
                }.help("RMS amplitude. Rearms below 65% of the threshold, preventing repeated cues from one sustained sound.")
            }
            if value(node).trigger == .timer {
                number("Seconds", binding: config(node, \.interval))
                    .help("Interval between timer-driven script advances. Each advance reveals one word, or Words/cue words in Subtitle cues mode.")
            }
            HStack {
                Button("Next") { model.audio.streams.emit(.manual); model.audio.streams.emit(.gesture) }.help("Advance Text layers listening for the manual or gesture command.")
                Button("Reset") { model.audio.streams.resetText() }.help("Reset every Text playback cursor and word animation to its beginning.")
                Toggle("Loop", isOn: config(node, \.loop)).help("After the final scripted cue, the next advance starts again at the beginning.")
            }
        } else {
            DisclosureGroup("Caption filter") {
                Toggle("Remove filler words", isOn: Binding(
                    get: { value(node).filterFillers ?? false },
                    set: { config(node, \.filterFillers).wrappedValue = $0 }
                )).help("Hide listed whole filler words in this layer only. Raw speech, voice commands and script text are unchanged. Off by default.")
                if value(node).filterFillers == true {
                    TextField("Comma-separated words", text: Binding(
                        get: { value(node).fillerWords ?? SpeechCaptionFilter.defaults },
                        set: { config(node, \.fillerWords).wrappedValue = $0 }
                    )).help("Whole words, ignoring case and surrounding punctuation. Defaults: um, uh, erm, er, hmm. Add words for your recognition language; common meaningful words such as ‘like’ are kept unless you list them.")
                }
            }
            Picker("Timing", selection: Binding(
                get: { value(node).speechTiming ?? .immediate },
                set: { config(node, \.speechTiming).wrappedValue = $0 }
            )) {
                Text("Immediate").tag(TextSpeechTiming.immediate)
                Text("Paced · show every word").tag(TextSpeechTiming.paced)
            }.help("Immediate adds no playback delay. Recognition can deliver several words together. Paced replays every received word, adding delay.")

        }
        if value(node).style == .word {
            Stepper("Words: \(value(node).wordCount ?? 1)", value: Binding(
                get: { value(node).wordCount ?? 1 },
                set: { config(node, \.wordCount).wrappedValue = $0 }
            ), in: 1...30).help("Number of recent words kept in the rolling window. One shows only the latest word; larger values retain more context.")
        }
        if value(node).style == .subtitles {
            Stepper("Words/cue: \(value(node).wordsPerCue)", value: config(node, \.wordsPerCue), in: 1...30).help("Maximum words in each subtitle cue. When that count is reached, the next word begins a new cue; width and line capacity can also start a new page.")
        }

        Divider()
        TextTypographyPanel(configuration: config(node, \.self))
        HStack {
            ColorPicker("Text", selection: color(node, \.color), supportsOpacity: true).help("Glyph color and base opacity. Word envelopes multiply this opacity.")
            ColorPicker("Box", selection: color(node, \.background), supportsOpacity: true).help("Caption background color and opacity; Fading words uses individual word tiles. Set alpha to zero for transparent text.")
        }
        TextMotionPanel(configuration: config(node, \.self),
            speech: node.inputs.first != .source(.script) && node.inputs.first != PortBinding.none)
    }
    private func drawingHelp(_ style: TextDrawingStyle) -> String {
        switch style {
        case .subtitles: return "Fixed-size word cues; replace the cue when Words/cue is reached."
        case .word: return "A rolling window of the latest N words. Set Words to 1 for a single word."
        case .build: return "Grow the phrase until a pause or the configured width/line capacity fills, then start a new page."
        case .trail: return "Each arriving word uses its own Fade in / Hold / Fade out envelope; new words don't reset earlier fades."
        case .typeOn: return "Fill a fixed caption area from its top-left, then start a new page when full or after a speech pause. Set Pop and Voice scale to zero for stationary lettering."
        }
    }

    private func value(_ node: Node) -> TextLayerConfig {
        guard case .text(let config) = model.settings.layerGraph?.node(node.id)?.kind else { return TextLayerConfig() }
        return config
    }
    private func config<T>(_ node: Node, _ key: WritableKeyPath<TextLayerConfig, T>) -> Binding<T> {
        Binding(get: { value(node)[keyPath: key] }, set: { next in
            guard var graph = model.settings.layerGraph, let index = graph.nodes.firstIndex(where: { $0.id == node.id }) else { return }
            var config = value(node); config[keyPath: key] = next
            graph.nodes[index].kind = .text(config); model.settings.layerGraph = graph
        })
    }
    private func input(_ node: Node, index: Int) -> Binding<PortBinding> {
        Binding(get: {
            let inputs = model.settings.layerGraph?.node(node.id)?.inputs ?? node.inputs
            return inputs.indices.contains(index) ? inputs[index] : .none
        }, set: { next in
            guard var graph = model.settings.layerGraph, let i = graph.nodes.firstIndex(where: { $0.id == node.id }),
                  graph.nodes[i].inputs.indices.contains(index) else { return }
            graph.nodes[i].inputs[index] = next; model.settings.layerGraph = graph
        })
    }
    private func color(_ node: Node, _ key: WritableKeyPath<TextLayerConfig, RGBAColor>) -> Binding<Color> {
        let binding = config(node, key)
        return Binding(get: {
            let c = binding.wrappedValue
            return Color(.sRGB, red: Double(c.red), green: Double(c.green), blue: Double(c.blue), opacity: Double(c.alpha))
        }, set: { next in
            guard let c = NSColor(next).usingColorSpace(.sRGB) else { return }
            binding.wrappedValue = RGBAColor(red: Float(c.redComponent), green: Float(c.greenComponent), blue: Float(c.blueComponent), alpha: Float(c.alphaComponent))
        })
    }
    private func number(_ label: String, binding: Binding<Double>) -> some View {
        HStack { Text(label); TextField(label, value: binding, format: .number).frame(width: 70) }
    }
}
