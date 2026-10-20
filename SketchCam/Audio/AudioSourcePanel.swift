import SwiftUI
import SketchCamCore

struct AudioSourcePanel: View {
    @ObservedObject var controller: AudioInputController
    let source: AudioSourceStreamID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if source == .microphone {
                Picker("Input", selection: $controller.microphoneID) {
                    Text("System default").tag(UInt32(0))
                    ForEach(controller.microphones) { Text($0.name).tag($0.id) }
                }
                .disabled(controller.microphoneRunning)
                .help("Microphone device for the shared audio stream. Stop capture before switching inputs. System default follows the Mac's selected input at start.")
                HStack {
                    Button(controller.microphoneRunning ? "Stop" : "Start") {
                        if controller.microphoneRunning { controller.stopMicrophone() }
                        else { controller.startMicrophone() }
                    }.help("Start or stop microphone capture and audio analysis. Starting requests microphone permission; it does not enable speech recognition.")
                    Button { controller.refreshMicrophones() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh the list of available microphone devices.")
                    Text(controller.microphoneStatus).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Button("Open…") { controller.chooseAudioFile() }.help("Choose local audio material for the same analysis and recognition contract as the microphone.")
                    Button(controller.fileRunning ? "Stop" : "Play from start") {
                        if controller.fileRunning { controller.stopFile() } else { controller.playFile() }
                    }.disabled(controller.fileURL == nil).help("Play the selected audio file from its beginning, or stop it. Analysis runs even with Listen disabled.")
                }
                Toggle("Listen", isOn: $controller.audible)
                    .help("Play the audio file through the system output. Microphone monitoring is always off.")
                Text(controller.fileStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            AudioFeatureReadout(store: controller.streams, source: source)
            Divider()
            SpeechControls(controller: controller)
            if source == .microphone { VoiceCommandPanel(controller: controller.voiceCommands) }
        }
        .controlSize(.small)
        .padding(8)
    }
}

private struct SpeechControls: View {
    @ObservedObject var controller: AudioInputController
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Speech language", selection: $controller.language) {
                Text("English").tag("en")
                Text("Chinese").tag("zh")
                Text("Bulgarian").tag("bg")
                Text("Detect").tag("")
            }.help("Applied when loading a model. Recognition runs locally after download.")
            Toggle("Translate into English", isOn: $controller.translateToEnglish)
                .help("Whisper translation is into English only; use a multilingual non-turbo model.")
            HStack {
                Menu("Enable speech") {
                    Button("Download base model & load") { controller.loadSpeechModel(download: true) }.help("Download/load a multilingual Whisper base model, then recognize active audio sources locally.")
                    Button("Load local Core ML model…") { controller.loadSpeechModel(download: false) }.help("Choose a WhisperKit Core ML model folder; GGUF and whisper.cpp models are not supported here.")
                }.help("Enable local speech recognition independently of microphone/file analysis. Language and translation options apply when loading.")
                Button("Off") { controller.stopSpeech() }.help("Stop speech recognition and clear transcripts; keep audio capture and feature analysis running.")
            }
            Text(controller.speechStatus).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                .help("Speech model/load status. Decode milliseconds measure the latest inference pass; Pending counts queued passes and helps diagnose recognition delay separately from word playback.")
        }
    }
}

private struct AudioFeatureReadout: View {
    let store: TemporalStreamStore
    let source: AudioSourceStreamID
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let snapshot = store.snapshot()
            let features = snapshot.features[source]
            let fresh = features.map { ProcessInfo.processInfo.systemUptime - $0.timestamp < 0.3 } ?? false
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(fresh ? String(format: "%.0f dBFS", features?.decibels ?? -120) : "— dBFS")
                        .help("RMS digital level in dBFS, not calibrated sound-pressure level or LUFS. Negative values are below full-scale amplitude.")
                    Spacer()
                    Text(fresh && features?.pitchHz != nil ? String(format: "%.0f Hz", features!.pitchHz!) : "— Hz")
                        .help("Voiced pitch estimate; unavailable for silence or low confidence.")
                }.font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                ProgressView(value: fresh ? Double(min(1, (features?.rms ?? 0) * 5)) : 0)
                    .help("RMS loudness × 5; amplitude 0…1 is available to consumers.")
                Canvas { context, size in
                    guard fresh, let features, !features.spectrum.isEmpty else { return }
                    let count = 48
                    let maxBin = features.spectrum.count - 1
                    for n in 0..<count {
                        let low = Int(pow(Double(maxBin), Double(n) / Double(count)))
                        let high = max(low + 1, Int(pow(Double(maxBin), Double(n + 1) / Double(count))))
                        let magnitude = features.spectrum[low..<min(high, maxBin + 1)].max() ?? 0
                        let height = CGFloat(max(0, min(1, (20 * log10(max(0.00001, magnitude)) + 70) / 70))) * size.height
                        let width = size.width / CGFloat(count)
                        let rect = CGRect(x: CGFloat(n) * width, y: size.height - height, width: max(1, width - 1), height: height)
                        context.fill(Path(rect), with: .color(.accentColor))
                    }
                }.frame(height: 42).accessibilityLabel("Live audio spectrum").help("Live frequency magnitudes from low to high frequencies, displayed in logarithmic bands. Empty when audio is stopped or stale.")
                if let phrase = snapshot.phrases[source] {
                    Text(phrase.text).font(.caption).lineLimit(3)
                        .foregroundStyle(phrase.committed ? Color.primary : Color.secondary)
                }
            }
        }
    }
}
