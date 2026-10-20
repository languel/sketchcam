import Foundation

/// Shared temporal sources. Audio packets are mono PCM; timestamps use host
/// uptime, while mediaTime locates the packet in its live/file source timeline.
public enum AudioSourceStreamID: String, Codable, CaseIterable, Sendable {
    case microphone, recordedAudio
}

public struct AudioPacket: Sendable {
    public var source: AudioSourceStreamID
    public var session: UUID
    public var timestamp: TimeInterval
    public var mediaTime: TimeInterval
    public var sampleRate: Double
    public var samples: [Float]
    public init(source: AudioSourceStreamID, session: UUID, timestamp: TimeInterval,
                mediaTime: TimeInterval, sampleRate: Double, samples: [Float]) {
        self.source = source; self.session = session; self.timestamp = timestamp
        self.mediaTime = mediaTime; self.sampleRate = sampleRate; self.samples = samples
    }
}

public struct AudioFeatures: Equatable, Sendable {
    public var timestamp: TimeInterval = 0
    public var rms: Float = 0
    public var peak: Float = 0
    public var decibels: Float = -120
    public var pitchHz: Float? = nil
    public var pitchConfidence: Float = 0
    /// Linear magnitudes, DC to Nyquist; spectrumHzPerBin describes the axis.
    public var spectrum: [Float] = []
    public var spectrumHzPerBin: Float = 0
    /// Windowed spectral energy in <250 Hz, 250–2000 Hz, and >2000 Hz bands.
    public var bands: [Float] = [0, 0, 0]
    public var speechActive = false
    public init() {}
}

public struct TranscriptWord: Equatable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float
    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float) {
        self.text = text; self.start = start; self.end = end; self.confidence = confidence
    }
}

public struct TranscriptAnnotation: Equatable, Sendable {
    public var name: String
    public var label: String
    public var rawText: String
    public init(name: String, label: String, rawText: String) {
        self.name = name; self.label = label; self.rawText = rawText
    }
}

public struct TranscriptPhrase: Equatable, Sendable {
    public var id: UUID
    public var text: String
    public var words: [TranscriptWord]
    public var language: String
    public var committed: Bool
    public var updatedAt: TimeInterval
    public var annotations: [TranscriptAnnotation]
    public var rawText: String?
    public init(id: UUID, text: String, words: [TranscriptWord], language: String,
                committed: Bool, updatedAt: TimeInterval,
                annotations: [TranscriptAnnotation] = [], rawText: String? = nil) {
        self.id = id; self.text = text; self.words = words; self.language = language
        self.committed = committed; self.updatedAt = updatedAt
        self.annotations = annotations; self.rawText = rawText
    }
}

public enum TextAdvanceEvent: String, Codable, Sendable {
    case manual, gesture, strokeStart, strokeEnd
}

public enum TextDrawingStyle: String, Codable, CaseIterable, Sendable {
    case subtitles, word, build, trail, typeOn
}

public enum TextHorizontalAlignment: String, Codable, CaseIterable, Sendable {
    case automatic, left, center, right, justified
}
public enum TextVerticalAlignment: String, Codable, CaseIterable, Sendable {
    case top, center, bottom
}
public enum TextLetterCase: String, Codable, CaseIterable, Sendable {
    case original, uppercase, lowercase
}
public enum TextFontFit: String, Codable, CaseIterable, Sendable {
    case fixed, shrink, fit
}

public enum TextSilencePolicy: String, Codable, CaseIterable, Sendable {
    case hidden, ellipsis, label, custom, keepLast
}

public enum TextSpeechTiming: String, Codable, CaseIterable, Sendable {
    case immediate, paced
}

public enum TextCaptionLifetime: String, Codable, CaseIterable, Sendable {
    case timed, untilReplaced
}

public enum TextAdvanceTrigger: String, Codable, CaseIterable, Sendable {
    case manual, gesture, strokeStart, strokeEnd, loudness, timer, voice
}

/// A pixel-producing drawing algorithm. Content, audio modulation and events
/// are separate inputs; a script need not be driven by its own source clock.
public struct TextLayerConfig: Codable, Sendable, Equatable {
    public var style: TextDrawingStyle = .subtitles
    public var trigger: TextAdvanceTrigger = .manual
    public var fontName = "Helvetica Neue"
    /// Relative to output height (0.055 is about 40 pt at 720p).
    public var fontSize: Double = 0.055
    public var color = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    public var background = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0.65)
    public var x: Double = 0.5
    public var y: Double = 0.85 // measured down from top
    public var width: Double = 0.85
    public var lineLimit: Int = 2
    public var wordsPerCue: Int = 6
    public var holdSeconds: Double = 4
    /// Optional additions preserve decoding of saved Text layers.
    public var alignment: TextHorizontalAlignment?
    public var verticalAlignment: TextVerticalAlignment?
    public var letterCase: TextLetterCase?
    public var bold: Bool?
    public var italic: Bool?
    /// Em units: proportional to the selected font size.
    public var paddingHorizontal: Double?
    public var paddingVertical: Double?
    public var letterSpacing: Double?
    public var lineSpacing: Double?
    public var justifyLastLine: Bool?
    /// Fraction of output height. Nil retains content/row-based height.
    public var height: Double?
    public var fontFit: TextFontFit?
    /// Radius in em units; nil preserves the original rounded box.
    public var cornerRadius: Double?
    public var silencePolicy: TextSilencePolicy?
    public var silenceText: String?
    public var silenceDelaySeconds: Double?
    public var fadeInSeconds: Double?
    public var wordHoldSeconds: Double?
    public var captionLifetime: TextCaptionLifetime?
    public var fadeOutSeconds: Double?
    public var voiceRiseSeconds: Double?
    public var voiceFallSeconds: Double?
    public var filterFillers: Bool?
    /// Comma-separated whole words; nil uses conservative English fillers.
    public var fillerWords: String?
    public var voiceEventName: String?
    public var speechTiming: TextSpeechTiming?
    public var wordCount: Int?
    public var fadeSeconds: Double?
    public var interval: Double = 0.5
    public var threshold: Float = 0.08
    public var loop = false
    public var pop: Double = 0
    public var loudnessScale: Double = 0
    public init() {}
}

public struct TemporalEvent: Sendable {
    public var serial: UInt64
    public var kind: TextAdvanceEvent
    public var timestamp: TimeInterval
}

public struct VoiceStreamEvent: Sendable {
    public var serial: UInt64
    public var name: String
    public var text: String
    public var phraseID: UUID
    public var timestamp: TimeInterval
    public var source: AudioSourceStreamID? = nil
    public var annotation: TranscriptAnnotation? = nil
}

/// Lock-bounded handoff for multiple consumers, independent of camera frames.
/// Subscriptions receive raw audio on the producer's analysis queue. Consumers
/// must enqueue expensive work, and can unsubscribe without consuming samples
/// belonging to another subsystem. No PCM/transcripts are serialized to disk.
public final class TemporalStreamStore: @unchecked Sendable {
    private let lock = NSLock()
    private var features: [AudioSourceStreamID: AudioFeatures] = [:]
    private var phrases: [AudioSourceStreamID: TranscriptPhrase] = [:]
    private var transcriptHistory: [AudioSourceStreamID: [TranscriptPhrase]] = [:]
    private var pcm: [AudioSourceStreamID: [Float]] = [:]
    private var rates: [AudioSourceStreamID: Double] = [:]
    private var events: [TemporalEvent] = []
    private var voiceEvents: [VoiceStreamEvent] = []
    private var annotationPublications: [String] = []
    private var serial: UInt64 = 0
    private var resetRevision: UInt64 = 0
    private var subscribers: [UUID: @Sendable (AudioPacket, AudioFeatures) -> Void] = [:]

    public init() {}
    public func subscribe(_ receive: @escaping @Sendable (AudioPacket, AudioFeatures) -> Void) -> UUID {
        lock.withLock { let id = UUID(); subscribers[id] = receive; return id }
    }
    public func unsubscribe(_ id: UUID) { lock.withLock { _ = subscribers.removeValue(forKey: id) } }
    public func publish(_ packet: AudioPacket, features value: AudioFeatures) {
        let callbacks = lock.withLock { () -> [@Sendable (AudioPacket, AudioFeatures) -> Void] in
            features[packet.source] = value
            rates[packet.source] = packet.sampleRate
            var buffer = pcm[packet.source] ?? []
            buffer.append(contentsOf: packet.samples)
            let capacity = Int(packet.sampleRate * 8)
            if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
            pcm[packet.source] = buffer
            return Array(subscribers.values)
        }
        callbacks.forEach { $0(packet, value) }
    }
    public func publish(_ phrase: TranscriptPhrase, source: AudioSourceStreamID) {
        lock.withLock {
            phrases[source] = phrase
            var history = transcriptHistory[source] ?? []
            if let index = history.firstIndex(where: { $0.id == phrase.id }) { history[index] = phrase }
            else { history.append(phrase) }
            if history.count > 64 { history.removeFirst(history.count - 64) }
            transcriptHistory[source] = history
            guard phrase.committed else { return }
            let key = source.rawValue + ":" + phrase.id.uuidString
            guard !annotationPublications.contains(key) else { return }
            annotationPublications.append(key)
            if annotationPublications.count > 256 { annotationPublications.removeFirst(annotationPublications.count - 256) }
            for annotation in phrase.annotations {
                serial &+= 1
                voiceEvents.append(VoiceStreamEvent(serial: serial, name: "annotation." + annotation.name,
                    text: annotation.rawText, phraseID: phrase.id, timestamp: phrase.updatedAt,
                    source: source, annotation: annotation))
            }
            if voiceEvents.count > 256 { voiceEvents.removeFirst(voiceEvents.count - 256) }
        }
    }
    public func clearTranscript(_ source: AudioSourceStreamID) {
        lock.withLock { phrases[source] = nil; transcriptHistory[source] = nil }
    }
    public func clear(_ source: AudioSourceStreamID) {
        lock.withLock { features[source] = nil; phrases[source] = nil; transcriptHistory[source] = nil; pcm[source] = nil; rates[source] = nil }
    }
    public func recentAudio(_ source: AudioSourceStreamID) -> (samples: [Float], sampleRate: Double) {
        lock.withLock { (pcm[source] ?? [], rates[source] ?? 0) }
    }
    public func emit(_ kind: TextAdvanceEvent, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.withLock {
            serial &+= 1
            events.append(TemporalEvent(serial: serial, kind: kind, timestamp: time))
            if events.count > 256 { events.removeFirst(events.count - 256) }
        }
    }
    public func resetText() { lock.withLock { resetRevision &+= 1 } }
    public func emitVoice(name: String, phrase: TranscriptPhrase) {
        lock.withLock {
            serial &+= 1
            voiceEvents.append(VoiceStreamEvent(serial: serial, name: name, text: phrase.text,
                phraseID: phrase.id, timestamp: ProcessInfo.processInfo.systemUptime))
            if voiceEvents.count > 256 { voiceEvents.removeFirst(voiceEvents.count - 256) }
        }
    }
    public func snapshot() -> TemporalSnapshot {
        lock.withLock { TemporalSnapshot(features: features, phrases: phrases, events: events,
                                         serial: serial, resetRevision: resetRevision, voiceEvents: voiceEvents,
                                         transcriptHistory: transcriptHistory) }
    }
}

public struct TemporalSnapshot: Sendable {
    public var features: [AudioSourceStreamID: AudioFeatures]
    public var phrases: [AudioSourceStreamID: TranscriptPhrase]
    public var events: [TemporalEvent]
    public var serial: UInt64
    public var resetRevision: UInt64
    public var voiceEvents: [VoiceStreamEvent] = []
    public var transcriptHistory: [AudioSourceStreamID: [TranscriptPhrase]] = [:]
}
