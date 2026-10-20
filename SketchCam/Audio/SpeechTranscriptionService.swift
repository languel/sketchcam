import AVFoundation
import Foundation
import SketchCamCore
import WhisperKit

/// Rolling partial phrases and silence-finalized phrases. All sources share
/// one decoder; pending partials coalesce and final jobs are bounded. Audio
/// analysis continues during model loading and decoding.
actor SpeechTranscriptionService {
    private struct Phrase {
        var session: UUID
        var id = UUID()
        var samples: [Float] = []
        var start: Double = 0
        var lastVoice: Double = 0
        var lastPartial: Double = 0
        var converter: AVAudioConverter?
        var inputRate: Double = 0
        var expectedTime: Double?
    }
    private struct Job: Sendable {
        var source: AudioSourceStreamID
        var session: UUID
        var id: UUID
        var samples: [Float]
        var start: Double
        var committed: Bool
    }
    private let store: TemporalStreamStore
    private var kit: WhisperKit?
    private var enabled = false
    private var generation = UUID()
    private var phrases: [AudioSourceStreamID: Phrase] = [:]
    private var sessions: [AudioSourceStreamID: UUID] = [:]
    private var jobs: [Job] = []
    private var decoding = false
    private var activeDecode: UUID?
    private var progressTokenCount = 0
    private var language = "en"
    private var translate = false
    var onStatus: (@Sendable (String) -> Void)?
    private var onFinal: (@Sendable (TranscriptPhrase, AudioSourceStreamID) -> Void)?

    init(store: TemporalStreamStore) { self.store = store }
    func setStatusHandler(_ callback: @escaping @Sendable (String) -> Void) { onStatus = callback }
    func setFinalHandler(_ callback: @escaping @Sendable (TranscriptPhrase, AudioSourceStreamID) -> Void) { onFinal = callback }

    func load(folder: URL?, language: String, translate: Bool) async {
        let token = UUID(); generation = token
        enabled = false; kit = nil; jobs = []; phrases = [:]; sessions = [:]
        self.language = language; self.translate = translate
        onStatus?(folder == nil ? "Downloading/loading multilingual base…" : "Loading local speech model…")
        do {
            let model = try await WhisperKit(WhisperKitConfig(
                model: folder == nil ? "openai_whisper-base" : nil,
                modelFolder: folder?.path, verbose: false, prewarm: true, load: true, download: folder == nil))
            guard generation == token else { return }
            kit = model; enabled = true
            onStatus?("Ready · on-device speech")
        } catch {
            guard generation == token else { return }
            kit = nil; onStatus?("Speech: \(error.localizedDescription)")
        }
    }
    func stop() {
        generation = UUID(); enabled = false; kit = nil; jobs = []; phrases = [:]; sessions = [:]
        store.clearTranscript(.microphone); store.clearTranscript(.recordedAudio)
        onStatus?("Speech off")
    }
    func finish(_ source: AudioSourceStreamID) {
        guard let phrase = phrases[source], enabled, phrase.samples.count >= 4000 else { return }
        enqueue(Job(source: source, session: phrase.session, id: phrase.id, samples: phrase.samples,
                    start: phrase.start, committed: true))
        phrases[source] = nil
        kickDecoder()
    }
    func invalidate(_ source: AudioSourceStreamID) {
        sessions[source] = nil; phrases[source] = nil; jobs.removeAll { $0.source == source }
        store.clearTranscript(source)
    }

    func accept(_ packet: AudioPacket, features: AudioFeatures) {
        guard enabled, kit != nil else { return }
        var phrase = phrases[packet.source] ?? Phrase(session: packet.session)
        if phrase.session != packet.session {
            phrase = Phrase(session: packet.session)
            jobs.removeAll { $0.source == packet.source }
        }
        if let expected = phrase.expectedTime, abs(packet.mediaTime - expected) > 0.1 {
            if phrase.samples.count >= 4000 {
                enqueue(Job(source: packet.source, session: phrase.session, id: phrase.id,
                    samples: phrase.samples, start: phrase.start, committed: true))
            }
            phrase = Phrase(session: packet.session)
        }
        phrase.expectedTime = packet.mediaTime + Double(packet.samples.count) / packet.sampleRate
        sessions[packet.source] = packet.session
        let samples = resample(packet, phrase: &phrase)
        let end = packet.mediaTime + Double(packet.samples.count) / packet.sampleRate
        if features.speechActive || !phrase.samples.isEmpty {
            if phrase.samples.isEmpty { phrase.start = packet.mediaTime }
            phrase.samples.append(contentsOf: samples)
            if features.speechActive { phrase.lastVoice = end }
            let final = end - phrase.lastVoice > 0.6 || phrase.samples.count >= 16000 * 15
            if phrase.samples.count >= 6400 && (final || end - phrase.lastPartial >= 0.5) {
                let job = Job(source: packet.source, session: packet.session, id: phrase.id,
                    samples: phrase.samples, start: phrase.start, committed: final)
                enqueue(job)
                phrase.lastPartial = end
            }
            if final { phrase.samples = []; phrase.id = UUID() }
        }
        phrases[packet.source] = phrase
        kickDecoder()
    }

    private func enqueue(_ job: Job) {
        // Retain final jobs and only the newest partial for each phrase.
        jobs.removeAll { $0.source == job.source && $0.id == job.id && !$0.committed }
        jobs.append(job)
        if jobs.count > 8 {
            jobs.remove(at: jobs.firstIndex(where: { !$0.committed }) ?? 0)
            onStatus?("Speech is falling behind; some phrases were skipped.")
        }
    }
    private func kickDecoder() {
        guard !decoding, !jobs.isEmpty, enabled, let kit else { return }
        decoding = true
        let token = generation
        let job = jobs.removeFirst()
        let decodeID = UUID(); activeDecode = decodeID; progressTokenCount = 0
        let language = self.language, translate = self.translate
        Task {
            let decodeStarted = ProcessInfo.processInfo.systemUptime
            do {
                let options = DecodingOptions(task: translate ? .translate : .transcribe,
                    language: language.isEmpty ? nil : language, temperatureFallbackCount: 0,
                    skipSpecialTokens: true, wordTimestamps: job.committed)
                let results = try await kit.transcribe(audioArray: job.samples, decodeOptions: options, callback: { progress in
                    Task { await self.publishProgress(progress, job: job, generation: token, decodeID: decodeID) }
                    return nil
                })
                // Late progress callbacks must never overwrite the completed result.
                self.activeDecode = nil
                if self.generation == token && self.sessions[job.source] == job.session && self.enabled {
                    let text = results.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
                        TranscriptWord(text: $0.word, start: job.start + Double($0.start),
                            end: job.start + Double($0.end), confidence: $0.probability)
                    }
                    let elapsed = ProcessInfo.processInfo.systemUptime - decodeStarted
                    self.onStatus?(String(format: "Ready · %.0f ms decode · %d pending", elapsed * 1000, self.jobs.count))
                    let parsed = SpeechTextContent.parsed(text)
                    let phrase = TranscriptPhrase(id: job.id, text: parsed.text,
                        words: parsed.text.isEmpty ? [] : SpeechTextContent.displayWords(words),
                        language: translate ? "en" : (results.first?.language ?? language), committed: job.committed,
                        updatedAt: ProcessInfo.processInfo.systemUptime, annotations: parsed.annotations, rawText: text)
                    self.store.publish(phrase, source: job.source)
                    if job.committed { self.onFinal?(phrase, job.source) }
                }
            } catch {
                if self.generation == token { self.onStatus?("Speech: \(error.localizedDescription)") }
            }
            self.activeDecode = nil
            self.decoding = false
            self.kickDecoder()
        }
    }

    private func publishProgress(_ progress: TranscriptionProgress, job: Job,
                                 generation token: UUID, decodeID: UUID) {
        guard generation == token, activeDecode == decodeID, enabled,
              sessions[job.source] == job.session, progress.tokens.count > progressTokenCount else { return }
        progressTokenCount = progress.tokens.count
        let parsed = SpeechTextContent.parsed(progress.text, trim: false)
        let text = Self.completeProgressText(parsed.text)
        guard !text.isEmpty else { return }
        // Rolling decoding starts again at the phrase's beginning. Don't rewind
        // already visible text while the next pass catches up to its old prefix.
        if let previous = store.snapshot().phrases[job.source], previous.id == job.id,
           previous.text.count >= text.count { return }
        store.publish(TranscriptPhrase(id: job.id, text: text, words: [],
            language: translate ? "en" : language, committed: false,
            updatedAt: ProcessInfo.processInfo.systemUptime, annotations: parsed.annotations,
            rawText: progress.text), source: job.source)
    }

    /// Keep an unfinished final word out of paced queues and word lifetimes.
    /// CJK text has no required spaces, so its arriving characters stay live.
    nonisolated static func completeProgressText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let cjk = trimmed.unicodeScalars.contains { (0x3400...0x9FFF).contains(Int($0.value)) }
        let punctuation = trimmed.unicodeScalars.last.map { CharacterSet.punctuationCharacters.contains($0) } ?? false
        if cjk || text.last?.isWhitespace == true || punctuation { return trimmed }
        guard let boundary = text.lastIndex(where: { $0.isWhitespace }) else { return "" }
        return String(text[..<boundary]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func resample(_ packet: AudioPacket, phrase: inout Phrase) -> [Float] {
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: packet.sampleRate, channels: 1),
              let outputFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(packet.samples.count)) else { return [] }
        if phrase.inputRate != packet.sampleRate {
            phrase.converter = AVAudioConverter(from: inputFormat, to: outputFormat)
            phrase.inputRate = packet.sampleRate
        }
        guard let converter = phrase.converter,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat,
                frameCapacity: AVAudioFrameCount(ceil(Double(packet.samples.count) * 16000 / packet.sampleRate) + 128)) else { return [] }
        input.frameLength = AVAudioFrameCount(packet.samples.count)
        packet.samples.withUnsafeBufferPointer {
            input.floatChannelData![0].update(from: $0.baseAddress!, count: packet.samples.count)
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return input
        }
        guard error == nil else { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
