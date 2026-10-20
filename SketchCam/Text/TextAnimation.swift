import Foundation
import SketchCamCore

struct TextWordEnvelope {
    var fadeIn: Double
    var hold: Double
    var fadeOut: Double
    var legacyTrail: Bool
    var untilReplaced: Bool
    init(_ config: TextLayerConfig) {
        untilReplaced = config.style != .trail && config.captionLifetime == .untilReplaced
        fadeIn = max(0, min(30, config.fadeInSeconds ?? 0))
        hold = max(0, min(120, config.wordHoldSeconds ?? (config.style == .trail ? 0 : config.holdSeconds)))
        fadeOut = max(0, min(30, config.fadeOutSeconds ?? (config.style == .trail ? (config.fadeSeconds ?? 2.5) : 0)))
        legacyTrail = config.style == .trail && config.fadeInSeconds == nil && config.wordHoldSeconds == nil && config.fadeOutSeconds == nil
    }
    var enabled: Bool { fadeIn > 0 || fadeOut > 0 }
    var lifetime: Double {
        guard !untilReplaced else { return .infinity }
        return (fadeOut > 0 || (fadeIn > 0 && hold > 0)) ? fadeIn + hold + fadeOut : .infinity
    }
    func opacity(age: Double) -> Double {
        let age = max(0, age)
        if fadeIn > 0, age < fadeIn { return Self.smooth(age / fadeIn) }
        if untilReplaced { return 1 }
        guard fadeOut > 0 else { return fadeIn > 0 && hold > 0 && age >= fadeIn + hold ? 0 : 1 }
        let releaseAge = age - fadeIn - hold
        guard releaseAge > 0 else { return 1 }
        let remaining = max(0, 1 - releaseAge / fadeOut)
        return legacyTrail ? remaining * remaining : Self.smooth(remaining)
    }
    static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value)); return t * t * (3 - 2 * t)
    }
}

/// Asymmetric envelope follower: Rise/Fall specify time to travel 90% toward
/// a new RMS target. Zero is an immediate response, matching earlier versions.
struct TextVoiceResponse {
    private(set) var value: Double = 0
    private var previousTime: Double?
    mutating func update(target: Double, at now: Double, rise: Double, fall: Double) -> Double {
        let target = min(1, max(0, target))
        let dt = max(0, now - (previousTime ?? now))
        previousTime = now
        let seconds = max(0, target > value ? rise : fall)
        if seconds == 0 { value = target }
        else { value += (target - value) * (1 - exp(-log(10) * dt / seconds)) }
        return value
    }
}

enum SpeechTextContent {
    static func isBlank(_ text: String) -> Bool {
        cleaned(text).isEmpty
    }

    // Recognizer bracket/parenthesis spans are annotation candidates. This is
    // a presentation convention, not an acoustic event classifier.
    private static let annotationPattern = #"\[[^\[\]\r\n]{0,160}\]|\([^()\r\n]{0,160}\)|<\|nospeech\|>"#
    private static let annotationExpression = try? NSRegularExpression(pattern: annotationPattern, options: .caseInsensitive)

    static func parsed(_ text: String, trim: Bool = true) -> (text: String, annotations: [TranscriptAnnotation]) {
        let ns = text as NSString
        let matches = annotationMatches(text)
        let annotations = matches.map { match -> TranscriptAnnotation in
            let raw = ns.substring(with: match.range)
            let label = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[]()<>| \t\r\n"))
            let slug = label.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: "_")
            return TranscriptAnnotation(name: slug.isEmpty ? "blank_audio" : slug, label: label, rawText: raw)
        }
        let output = NSMutableString(string: text)
        for match in matches.reversed() { output.replaceCharacters(in: match.range, with: " ") }
        var value = output as String
        // A live callback may end at '(' or '(click', before its closing token.
        // Hold that suffix out of captions; only complete final spans emit events.
        if let start = value.lastIndex(where: { "[(<".contains($0) }) {
            let tail = value[start...]
            let fragment = tail.lowercased().filter { !$0.isWhitespace && $0 != "_" && $0 != "." && $0 != "…" }
            let unfinishedBracket = (tail.first == "[" && !tail.contains("]")) ||
                (tail.first == "(" && !tail.contains(")"))
            let punctuationOnly = !fragment.isEmpty && fragment.allSatisfy { "[]()<>|".contains($0) }
            if (unfinishedBracket && tail.count <= 161 && !tail.contains("\n")) ||
                punctuationOnly || "<|nospeech|>".hasPrefix(fragment) {
                value = String(value[..<start])
            }
        }
        value = value.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return (trim ? value.trimmingCharacters(in: .whitespacesAndNewlines) : value, annotations)
    }

    static func cleaned(_ text: String, trim: Bool = true) -> String { parsed(text, trim: trim).text }

    /// Alignment words can split an annotation across several entries. Exclude
    /// all intersecting entries so annotation timestamps don't pace spoken text.
    static func displayWords(_ words: [TranscriptWord]) -> [TranscriptWord] {
        let matches = annotationMatches(words.map(\.text).joined())
        guard !matches.isEmpty else { return words }
        var offset = 0
        return words.filter { word in
            let range = NSRange(location: offset, length: (word.text as NSString).length)
            offset += range.length
            return !matches.contains { NSIntersectionRange(range, $0.range).length > 0 }
        }
    }

    private static func annotationMatches(_ text: String) -> [NSTextCheckingResult] {
        guard let expression = annotationExpression else { return [] }
        return expression.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
    static func placeholder(_ config: TextLayerConfig) -> String {
        switch config.silencePolicy ?? .hidden {
        case .hidden, .keepLast: return ""
        case .ellipsis: return "…"
        case .label: return "[blank audio]"
        case .custom: return config.silenceText ?? ""
        }
    }
}

struct TextSilenceGate {
    private var lastActivity: Double?
    private var phraseID: UUID?
    private var phraseText = ""
    mutating func isSilent(phrase: TranscriptPhrase?, features: AudioFeatures?, at now: Double, delay: Double) -> Bool {
        if let features, features.speechActive {
            lastActivity = max(lastActivity ?? 0, features.timestamp)
        }
        guard let phrase, !SpeechTextContent.isBlank(phrase.text) else { return true }
        if phrase.id != phraseID || phrase.text != phraseText {
            lastActivity = now; phraseID = phrase.id; phraseText = phrase.text
        }
        return now - (lastActivity ?? now) >= max(0, delay)
    }
}

/// Stable word identities survive appended words, duplicate finals and case
/// transforms. Corrected words receive new identities and animation lifetimes.
struct TextWordLife: Equatable {
    var id: UUID
    var text: String
    var born: Double
}
struct TextWordTimeline {
    private var phraseID: UUID?
    private var words: [TextWordLife] = []
    mutating func receive(id: UUID, text: String, at now: Double) {
        let units = TextLayerRenderer.scriptUnits(text)
        if phraseID != id { words = []; phraseID = id }
        var prefix = 0
        while prefix < min(words.count, units.count),
              words[prefix].text.trimmingCharacters(in: .whitespacesAndNewlines) == units[prefix].trimmingCharacters(in: .whitespacesAndNewlines) { prefix += 1 }
        var next = Array(words.prefix(prefix))
        for index in 0..<prefix { next[index].text = units[index] }
        for index in prefix..<units.count { next.append(TextWordLife(id: UUID(), text: units[index], born: now)) }
        words = next
    }
    func visible(for text: String) -> [TextWordLife] {
        // All current layouts show a suffix: latest N, current cue, or page.
        Array(words.suffix(TextLayerRenderer.scriptUnits(text).count))
    }
}
