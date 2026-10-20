import AppKit
import AVFoundation
import Combine
import Foundation
import SketchCamCore
import UniformTypeIdentifiers

/// UI ownership only. High-rate PCM/features live in the shared store, outside
/// Published state. Microphone and file may run concurrently.
final class AudioInputController: ObservableObject {
    let streams = TemporalStreamStore()
    lazy var voiceCommands = VoiceCommandController(streams: streams)
    @Published private(set) var microphoneRunning = false
    @Published private(set) var fileRunning = false
    @Published private(set) var microphoneStatus = "Stopped"
    @Published private(set) var fileStatus = "No file"
    @Published private(set) var speechStatus = "Speech off"
    @Published private(set) var microphones: [MicrophoneDevice] = []
    @Published var microphoneID: UInt32 = 0
    @Published var audible = false { didSet { file.setAudible(audible) } }
    @Published var language = "en"
    @Published var translateToEnglish = false
    @Published private(set) var fileURL: URL?
    private lazy var microphone = AudioStreamSource(source: .microphone, store: streams)
    private lazy var file = AudioStreamSource(source: .recordedAudio, store: streams)
    private lazy var speech = SpeechTranscriptionService(store: streams)
    private var subscription: UUID?
    private var speechPump: Task<Void, Never>?
    private var continuation: AsyncStream<(AudioPacket, AudioFeatures)>.Continuation?
    private var modelScope: URL?
    private var micRequest = UUID()
    private var fileRequest = UUID()

    init() { refreshMicrophones() }
    deinit {
        speechPump?.cancel(); continuation?.finish()
        if let subscription { streams.unsubscribe(subscription) }
        modelScope?.stopAccessingSecurityScopedResource()
        fileURLScope?.stopAccessingSecurityScopedResource()
    }
    func refreshMicrophones() { microphones = AudioStreamSource.microphones() }
    func startMicrophone() {
        let token = UUID(); micRequest = token
        microphoneStatus = "Requesting microphone…"
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self, self.micRequest == token else { return }
                guard granted else { self.microphoneStatus = "Microphone access denied · enable in System Settings"; return }
                Task {
                    await self.speech.invalidate(.microphone)
                    await MainActor.run {
                        guard self.micRequest == token else { return }
                        do {
                            self.microphone.onStopped = { [weak self] error in
                                self?.microphoneRunning = false; self?.microphoneStatus = error ?? "Stopped"
                                if let self { Task { await self.speech.finish(.microphone) } }
                            }
                            try self.microphone.startMicrophone(deviceID: self.microphoneID == 0 ? nil : self.microphoneID)
                            self.microphoneRunning = true; self.microphoneStatus = "Live"
                        } catch { self.microphoneStatus = error.localizedDescription; self.microphoneRunning = false }
                    }
                }
            }
        }
    }
    func stopMicrophone() {
        voiceCommands.armed = false
        micRequest = UUID(); microphone.stop(); microphoneRunning = false; microphoneStatus = "Stopped"
        Task { await speech.finish(.microphone) }
    }
    func chooseAudioFile() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            self.fileRequest = UUID()
            self.file.stop(); self.fileRunning = false
            Task { await self.speech.invalidate(.recordedAudio) }
            self.fileURL = url; self.fileStatus = url.lastPathComponent
            // Access remains scoped while this file is selected; playback owns
            // an additional balanced scope for each run.
            self.fileURLScope?.stopAccessingSecurityScopedResource()
            self.fileURLScope = url.startAccessingSecurityScopedResource() ? url : nil
        }
    }
    private var fileURLScope: URL?
    func playFile() {
        guard let fileURL else { return }
        let token = UUID(); fileRequest = token
        Task {
            await speech.invalidate(.recordedAudio)
            await MainActor.run {
                guard self.fileRequest == token else { return }
                do {
                    self.file.onStopped = { [weak self] error in
                        guard let self else { return }
                        self.fileRunning = false; self.fileStatus = error ?? "Finished"
                        Task { await self.speech.finish(.recordedAudio) }
                    }
                    try self.file.playFile(fileURL, audible: self.audible)
                    self.fileRunning = true; self.fileStatus = fileURL.lastPathComponent
                } catch { self.fileRunning = false; self.fileStatus = error.localizedDescription }
            }
        }
    }
    func stopFile() {
        fileRequest = UUID()
        file.stop(); fileRunning = false; fileStatus = fileURL?.lastPathComponent ?? "No file"
        Task { await speech.finish(.recordedAudio) }
    }
    func loadSpeechModel(download: Bool) {
        if download { beginSpeech(folder: nil); return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.message = "Choose a WhisperKit Core ML model folder (not a GGUF/whisper.cpp model)."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.beginSpeech(folder: url)
        }
    }
    private func beginSpeech(folder: URL?) {
        if speechPump == nil {
            let stream = AsyncStream<(AudioPacket, AudioFeatures)>(bufferingPolicy: .bufferingNewest(4)) {
                self.continuation = $0
            }
            let continuation = self.continuation!
            subscription = streams.subscribe { packet, features in continuation.yield((packet, features)) }
            let speech = self.speech
            speechPump = Task.detached {
                for await (packet, features) in stream {
                    guard !Task.isCancelled else { break }
                    await speech.accept(packet, features: features)
                }
            }
        }
        modelScope?.stopAccessingSecurityScopedResource()
        modelScope = folder.flatMap { $0.startAccessingSecurityScopedResource() ? $0 : nil }
        let language = language, translate = translateToEnglish
        let modeLabel = " · \(language.isEmpty ? "detect" : language)\(translate ? " → English" : "")"
        Task {
            await speech.setFinalHandler { [weak self] phrase, source in
                DispatchQueue.main.async {
                    guard let self, self.microphoneRunning else { return }
                    self.voiceCommands.receive(phrase, source: source)
                }
            }
            await speech.setStatusHandler { [weak self] message in
                DispatchQueue.main.async { self?.speechStatus = message + (message.hasPrefix("Ready") ? modeLabel : "") }
            }
            await speech.load(folder: folder, language: language, translate: translate)
        }
    }
    func stopSpeech() { voiceCommands.listening = false; Task { await speech.stop() } }
    func stop() { stopMicrophone(); stopFile(); stopSpeech() }
}
