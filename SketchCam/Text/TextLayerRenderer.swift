import AppKit
import CoreImage
import CoreText
import Foundation
import SketchCamCore

/// Confined to the camera processing queue, like the existing drawing
/// compositors. Glyphs are rasterized only when content/style changes; pop and
/// audio modulation transform the cached transparent image on the GPU.
final class TextLayerRenderer {
    private struct State {
        var units: [String] = []
        var content = ""
        var source = PortBinding.none
        var trigger = TextAdvanceTrigger.manual
        var cursor = -1
        var serial: UInt64 = 0
        var reset: UInt64 = 0
        var aboveThreshold = false
        var lastAdvance: Double = 0
        var changedAt: Double = 0
        var phraseID: UUID?
        var phraseText = ""
        var speechStyle: TextDrawingStyle?
        var speechTiming: TextSpeechTiming?
        var pacedUpdateAt: Double = 0
        var silence = TextSilenceGate()
        var voice = TextVoiceResponse()
        var timeline = TextWordTimeline()
        var wordRenderer: TextWordRenderer?
        var lastNonblank: TranscriptPhrase?
        var scriptPhraseID = UUID()
        var previousScriptCursor = -1
        var trail = FadingWordTrail()
        var speechWords = SpeechWordPlayback()
        var speechHistoryInitialized = false
        var ignoredSpeechIDs: Set<UUID> = []
        var speechInputs: [UUID: TranscriptPhrase] = [:]
        var speechFilterSignature = ""
        var cacheKey = ""
        var cached: CIImage?
    }
    private var states: [UUID: State] = [:]
    private var layoutCache: [String: String] = [:]
    func retainNodes(_ ids: Set<UUID>) { states = states.filter { ids.contains($0.key) } }

    func image(node: Node, script: String, snapshot: TemporalSnapshot,
               size: CGSize, now: Double) -> CIImage? {
        guard case .text(let config) = node.kind else { return nil }
        let content: PortBinding = (node.inputs.first == nil || node.inputs.first == PortBinding.none)
            ? .source(.script) : node.inputs[0]
        let audioBinding = node.inputs.count > 1 ? node.inputs[1] : .source(.microphone)
        let audioSource: AudioSourceStreamID = audioBinding == .source(.recordedAudio) ? .recordedAudio : .microphone
        let features = audioBinding == .none ? nil : snapshot.features[audioSource]
        let fresh = features.map { now - $0.timestamp < 0.3 } ?? false
        var state = states[node.id] ?? State(serial: snapshot.serial, reset: snapshot.resetRevision)
        if state.content != script || state.source != content || state.trigger != config.trigger || state.reset != snapshot.resetRevision {
            state = State(units: Self.scriptUnits(script), content: script, source: content, trigger: config.trigger,
                          serial: snapshot.serial, reset: snapshot.resetRevision)
        }
        let timing = config.speechTiming ?? .immediate
        if state.speechStyle != config.style || state.speechTiming != timing {
            state.speechWords = SpeechWordPlayback()
            state.speechHistoryInitialized = false; state.ignoredSpeechIDs = []
            state.speechInputs = [:]
            state.trail = FadingWordTrail()
            state.timeline = TextWordTimeline(); state.wordRenderer = nil
            state.speechStyle = config.style; state.speechTiming = timing
        }
        let envelope = TextWordEnvelope(config)
        let voiceLevel = state.voice.update(target: fresh ? Double(features?.rms ?? 0) * 5 : 0,
            at: now, rise: max(0, config.voiceRiseSeconds ?? 0), fall: max(0, config.voiceFallSeconds ?? 0))
        var text = ""
        var utterance: TranscriptPhrase?
        var placeholder = false
        if content == .source(.script) {
            let units = state.units
            let group = config.style == .subtitles ? max(1, config.wordsPerCue) : 1
            let cues = Int(ceil(Double(units.count) / Double(group)))
            if cues > 0 && state.cursor >= cues { state.cursor = cues - 1 }
            var advances = 0
            switch config.trigger {
            case .voice:
                let name = config.voiceEventName ?? "next"
                advances = snapshot.voiceEvents.filter {
                    $0.serial > state.serial && VoiceCommandText.normalized($0.name) == VoiceCommandText.normalized(name)
                }.count
            case .timer:
                if cues > 0 && now - state.lastAdvance >= max(0.05, config.interval) { advances = 1 }
            case .loudness:
                let level = fresh ? features?.rms ?? 0 : 0
                if !state.aboveThreshold && level >= config.threshold { advances = 1; state.aboveThreshold = true }
                if level < config.threshold * 0.65 { state.aboveThreshold = false }
            default:
                advances = snapshot.events.filter {
                    $0.serial > state.serial && $0.kind.rawValue == config.trigger.rawValue
                }.count
            }
            if advances > 0 && cues > 0 {
                state.cursor += advances
                state.cursor = config.loop ? state.cursor % cues : min(cues - 1, state.cursor)
                state.lastAdvance = now; state.changedAt = now
            }
            if state.cursor >= 0 && !units.isEmpty {
                let first = (config.style == .build || config.style == .trail || config.style == .typeOn) ? 0 :
                    config.style == .word ? max(0, state.cursor - max(1, config.wordCount ?? 1) + 1) : state.cursor * group
                let end = min(units.count, (state.cursor + 1) * group)
                text = units[first..<end].joined().trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            let source: AudioSourceStreamID? = content == .source(.microphoneText) ? .microphone :
                content == .source(.recordedAudioText) ? .recordedAudio : nil
            let recognized = source.flatMap { snapshot.phrases[$0] }
            let retainCaption = envelope.untilReplaced || config.silencePolicy == .keepLast
            if let recognized, !SpeechTextContent.isBlank(recognized.text) { state.lastNonblank = recognized }
            let candidate = retainCaption && recognized.map { SpeechTextContent.isBlank($0.text) } != false
                ? state.lastNonblank : recognized
            var phrase = candidate.map { value -> TranscriptPhrase in
                var value = value
                value.text = SpeechTextContent.cleaned(value.text)
                return SpeechCaptionFilter.apply(value, config: config)
            }
            if timing == .paced {
                let filterSignature = "\(config.filterFillers == true)|\(config.fillerWords ?? SpeechCaptionFilter.defaults)"
                if state.speechFilterSignature != filterSignature {
                    state.speechInputs = [:]; state.speechFilterSignature = filterSignature
                }
                // Capture all recent phrase IDs, including finals overwritten by
                // a new phrase before this layer received another render frame.
                let history = source.flatMap { snapshot.transcriptHistory[$0] } ?? []
                let inputs = history.isEmpty ? recognized.map({ [$0] }) ?? [] : history
                if !state.speechHistoryInitialized {
                    // Joining a running stream starts at its latest phrase.
                    state.ignoredSpeechIDs = Set(inputs.dropLast().map(\.id))
                    state.speechHistoryInitialized = true
                }
                let retainedIDs = Set(inputs.map(\.id))
                state.ignoredSpeechIDs.formIntersection(retainedIDs)
                state.speechInputs = state.speechInputs.filter { retainedIDs.contains($0.key) }
                for original in inputs where !state.ignoredSpeechIDs.contains(original.id) {
                    if state.speechInputs[original.id] == original { continue }
                    state.speechInputs[original.id] = original
                    var input = original
                    input.text = SpeechTextContent.cleaned(input.text)
                    input = SpeechCaptionFilter.apply(input, config: config)
                    if !input.text.isEmpty { state.speechWords.receive(input) }
                }
                // Blank/annotation-only results must never clear waiting words.
                let display = state.speechWords.display(at: now,
                    holdSeconds: retainCaption || config.style == .trail ? 0 : config.holdSeconds)
                if display.changed { state.pacedUpdateAt = now }
                phrase = display.phraseID.map { id in
                    TranscriptPhrase(id: id, text: display.phraseText, words: [],
                        language: candidate?.language ?? "", committed: false, updatedAt: state.pacedUpdateAt)
                }
            }
            if let phrase, !SpeechTextContent.isBlank(phrase.text) {
                utterance = phrase
                if config.style == .trail {
                    if state.trail.receive(phrase, at: now) { state.changedAt = now }
                } else if envelope.enabled || retainCaption || config.holdSeconds <= 0 || now - phrase.updatedAt <= config.holdSeconds {
                    if state.phraseID != phrase.id || state.phraseText != phrase.text {
                        state.phraseID = phrase.id; state.phraseText = phrase.text; state.changedAt = now
                    }
                    text = layoutText(phrase.text, config: config, size: size)
                }
            }
            let sourceFeatures = source.flatMap { snapshot.features[$0] }
            let silent = state.silence.isSilent(phrase: utterance, features: sourceFeatures,
                at: now, delay: config.silenceDelaySeconds ?? max(0.6, config.holdSeconds))
            if silent && !retainCaption && !(timing == .paced && state.speechWords.hasPending) {
                text = SpeechTextContent.placeholder(config)
                placeholder = !text.isEmpty
                utterance = nil
            }
        }
        if content == .source(.script) {
            if state.cursor >= 0 {
                if state.cursor < state.previousScriptCursor { state.scriptPhraseID = UUID() }
                state.previousScriptCursor = state.cursor
                let group = config.style == .subtitles ? max(1, config.wordsPerCue) : 1
                let end = min(state.units.count, (state.cursor + 1) * group)
                utterance = TranscriptPhrase(id: state.scriptPhraseID, text: state.units.prefix(end).joined(),
                    words: [], language: "", committed: false, updatedAt: state.lastAdvance)
            }
            if config.style == .build || config.style == .typeOn { text = layoutText(text, config: config, size: size) }
            if config.style == .trail, state.cursor >= 0 {
                let phrase = TranscriptPhrase(id: state.scriptPhraseID, text: text, words: [], language: "",
                    committed: false, updatedAt: state.lastAdvance)
                if state.trail.receive(phrase, at: now) { state.changedAt = now }
            }
        }
        if let utterance, content == .source(.script) || !SpeechTextContent.isBlank(utterance.text) {
            state.timeline.receive(id: utterance.id, text: utterance.text, at: now)
        }
        state.serial = snapshot.serial
        var image: CIImage?
        if placeholder {
            // A deliberate silence caption remains steady until speech resumes.
            let key = "silence|\(text)|\(size)|\(((try? JSONEncoder().encode(config)) ?? Data()).base64EncodedString())"
            if state.cacheKey != key { state.cached = Self.rasterize(text, config: config, size: size); state.cacheKey = key }
            image = state.cached
            if let renderer = state.wordRenderer,
               let outgoing = renderer.image(text: "", lives: [], config: config, size: size, now: now) {
                image = image?.composited(over: outgoing)
            }
        } else if config.style == .trail {
            // With no speech content, keep only the existing trail's releases.
            image = state.trail.image(config: config, size: size, now: now,
                                      retiring: content != .source(.script) && utterance == nil)
        } else if envelope.enabled {
            if state.wordRenderer == nil { state.wordRenderer = TextWordRenderer() }
            let visible = utterance == nil ? [] : state.timeline.visible(for: text)
            image = state.wordRenderer?.image(text: text, lives: visible, config: config, size: size, now: now)
        } else {
            state.wordRenderer = nil
            guard !text.isEmpty else { states[node.id] = state; return nil }
            let data = (try? JSONEncoder().encode(config)) ?? Data()
            let key = "\(size.width)x\(size.height)|\(text)|\(data.base64EncodedString())"
            if state.cacheKey != key {
                state.cached = Self.rasterize(text, config: config, size: size)
                state.cacheKey = key
            }
            image = state.cached
        }
        let age = max(0, now - state.changedAt)
        let pop = config.pop * exp(-age * 12) * sin(min(1, age * 5) * .pi)
        let scale = max(0.2, 1 + pop + voiceLevel * config.loudnessScale)
        if scale != 1 {
            let anchor = CGPoint(x: size.width * config.x, y: size.height * (1 - config.y))
            image = image?.transformed(by: CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y)))
        }
        states[node.id] = state
        guard let image else { return nil }
        // Crop alone keeps the glyph image's tight extent. Workspace fitting
        // would then stretch that short strip to the entire layer height,
        // cancelling font-height changes and discarding placement offsets.
        // Supply the full transparent canvas before the workspace fits it.
        let canvas = CGRect(origin: .zero, size: size)
        let transparent = CIImage(color: .clear).cropped(to: canvas)
        return image.composited(over: transparent).cropped(to: canvas)
    }

    /// Locale-aware boundaries retain source whitespace/punctuation and do not
    /// assume that Chinese text has spaces. Empty scripts produce no cues.
    static func scriptUnits(_ text: String) -> [String] {
        var starts: [String.Index] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { _, range, _, _ in
            starts.append(range.lowerBound)
        }
        guard !starts.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [text] }
        starts[0] = text.startIndex
        return starts.indices.map { index in
            String(text[starts[index]..<(index + 1 < starts.count ? starts[index + 1] : text.endIndex)])
        }
    }

    private func layoutText(_ text: String, config: TextLayerConfig, size: CGSize) -> String {
        let data = (try? JSONEncoder().encode(config)) ?? Data()
        let key = "\(size.width)x\(size.height)|\(text)|\(data.base64EncodedString())"
        if let cached = layoutCache[key] { return cached }
        let result = Self.speechText(text, config: config, size: size)
        if layoutCache.count >= 64 { layoutCache = [:] }
        layoutCache[key] = result
        return result
    }

    static func speechText(_ text: String, config: TextLayerConfig, size: CGSize) -> String {
        let units = scriptUnits(TextTypography.text(text, config: config))
        guard !units.isEmpty else { return "" }
        switch config.style {
        case .word:
            return units.suffix(max(1, config.wordCount ?? 1)).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        case .subtitles:
            let count = max(1, config.wordsPerCue)
            let first = ((units.count - 1) / count) * count
            return fittingPage(units[first...].joined(), config: config, size: size)
        case .build, .typeOn: return fittingPage(text, config: config, size: size)
        case .trail: return text
        }
    }

    /// Keep the newest page, starting a new page when its line capacity fills.
    /// Page boundaries depend on real glyph layout, not a guessed word count.
    static func fittingPage(_ text: String, config: TextLayerConfig, size: CGSize) -> String {
        guard !text.isEmpty, size.width > 0, size.height > 0 else { return "" }
        let styled = TextTypography.text(text, config: config)
        let metrics = TextTypography(text: styled, config: config, size: size)
        let string = NSAttributedString(string: String(styled.suffix(2000)), attributes: metrics.attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        let lines = metrics.rows(for: config)
        var offset = 0, pageStart = 0
        while offset < string.length {
            pageStart = offset
            for _ in 0..<lines where offset < string.length {
                offset += max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(metrics.availableWidth)))
            }
        }
        return (string.string as NSString).substring(from: pageStart).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func rasterize(_ text: String, config: TextLayerConfig, size: CGSize) -> CIImage? {
        TextGlyphLayout(text: text, config: config, size: size)?.image()
    }
}

/// Recognition delivers batches, not individual live word events. Keep a cursor
/// per phrase and revise only its unshown tail when a partial/final update lands.
/// Each render advances at most one word: slow frames must not skip queue items.
struct SpeechWordPlayback {
    private struct Word {
        var text: String
        var seconds: Double
        var unit: String
    }
    private struct Batch {
        var id: UUID
        var words: [Word]
        var shown = 0
        var text: String
        var timings: [TranscriptWord]
    }
    private var batches: [Batch] = []
    private var current = ""
    private var nextAt: Double = 0
    private var currentPhraseID: UUID?
    private var currentPhraseText = ""

    var hasPending: Bool { batches.contains { $0.shown < $0.words.count } }

    mutating func receive(_ phrase: TranscriptPhrase) {
        let existing = batches.firstIndex { $0.id == phrase.id }
        if let existing, batches[existing].text == phrase.text, batches[existing].timings == phrase.words { return }
        let units = TextLayerRenderer.scriptUnits(phrase.text)
        let words = units.enumerated().map { index, unit in
            let duration = phrase.words.count == units.count ? phrase.words[index].end - phrase.words[index].start : 0.22
            return Word(text: unit.trimmingCharacters(in: .whitespacesAndNewlines),
                        seconds: min(0.6, max(0.1, duration)), unit: unit)
        }
        let visible = words.filter { !$0.text.isEmpty }
        if let existing {
            let old = batches[existing]
            // Never reinterpret the numeric cursor in a revised transcript:
            // deleting an earlier token would otherwise skip an unshown word.
            // Keep delivered words, align the longest delivered suffix, and
            // replace only the not-yet-presented tail.
            var delivered = Array(old.words.prefix(old.shown))
            var start = 0
            if !delivered.isEmpty && !visible.isEmpty {
                search: for length in stride(from: min(delivered.count, visible.count), through: 1, by: -1) {
                    let suffix = delivered.suffix(length).map { Self.key($0.text) }
                    for index in 0...(visible.count - length) {
                        if visible[index..<(index + length)].map({ Self.key($0.text) }) == suffix {
                            // A formerly last partial word acquires its space
                            // when another word arrives. Keep that separator.
                            for offset in 0..<length {
                                delivered[delivered.count - length + offset].unit = visible[index + offset].unit
                            }
                            start = index + length; break search
                        }
                    }
                }
            }
            batches[existing].words = delivered + visible.dropFirst(start)
            batches[existing].text = phrase.text
            batches[existing].timings = phrase.words
        } else {
            batches.append(Batch(id: phrase.id, words: visible, text: phrase.text, timings: phrase.words))
        }
        // Retain recent completed IDs to suppress repeats on final revisions.
        // Never evict a phrase whose words are still waiting to be displayed.
        while batches.count > 64, let first = batches.first, first.shown >= first.words.count {
            batches.removeFirst()
        }
    }

    private static func key(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }

    mutating func display(at now: Double, holdSeconds: Double) -> (text: String, changed: Bool, phraseID: UUID?, phraseText: String) {
        if (current.isEmpty || now >= nextAt),
           let index = batches.firstIndex(where: { $0.shown < $0.words.count }) {
            let word = batches[index].words[batches[index].shown]
            batches[index].shown += 1
            current = word.text
            nextAt = now + word.seconds
            currentPhraseID = batches[index].id
            currentPhraseText = batches[index].words.prefix(batches[index].shown).map(\.unit).joined()
            return (current, true, currentPhraseID, currentPhraseText)
        }
        // Hold applies only after the queue drains, not to each ASR update.
        // Zero retains the last word, matching the other text drawing modes.
        let expired = holdSeconds > 0 && now >= nextAt + holdSeconds
        return (expired ? "" : current, false, currentPhraseID, expired ? "" : currentPhraseText)
    }
}

/// Each incoming word owns a birth time and a cached glyph tile. Only opacity
/// and placement change per frame; fading does not rerasterize the phrase.
final class FadingWordTrail {
    private struct Particle {
        var phrase: UUID
        var index: Int
        var text: String
        var born: Double
    }
    private struct Glyph {
        var image: CIImage
        var advance: CGFloat
    }
    private var particles: [Particle] = []
    private var seen: [(id: UUID, units: [String])] = []
    private var glyphs: [String: Glyph] = [:]
    private var glyphStyle = Data()
    private var metricsKey = ""
    private var cachedMetrics: TextTypography?

    @discardableResult
    func receive(_ phrase: TranscriptPhrase, at now: Double) -> Bool {
        let units = TextLayerRenderer.scriptUnits(phrase.text)
        let old = seen.firstIndex { $0.id == phrase.id }
        let previous = old.map { seen[$0].units } ?? []
        guard previous != units else { return false }
        var prefix = 0
        while prefix < min(previous.count, units.count),
              previous[prefix].trimmingCharacters(in: .whitespacesAndNewlines) == units[prefix].trimmingCharacters(in: .whitespacesAndNewlines) { prefix += 1 }
        for index in particles.indices where particles[index].phrase == phrase.id && particles[index].index < prefix {
            particles[index].text = units[particles[index].index]
        }
        particles.removeAll { $0.phrase == phrase.id && $0.index >= prefix }
        for index in prefix..<units.count {
            particles.append(Particle(phrase: phrase.id, index: index, text: units[index], born: now))
        }
        if let old { seen[old].units = units }
        else { seen.append((phrase.id, units)) }
        if seen.count > 64 { seen.removeFirst(seen.count - 64) }
        if particles.count > 128 { particles.removeFirst(particles.count - 128) }
        return true
    }

    func image(config: TextLayerConfig, size: CGSize, now: Double, retiring: Bool = false) -> CIImage? {
        let envelope = TextWordEnvelope(config)
        if retiring && envelope.fadeOut == 0 { particles = [] }
        particles.removeAll { now - $0.born >= envelope.lifetime }
        guard !particles.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let style = (try? JSONEncoder().encode(config)) ?? Data()
        if style != glyphStyle { glyphs = [:]; glyphStyle = style }
        let combined = TextTypography.text(particles.map(\.text).joined(), config: config)
        let nextMetricsKey = "\(size.width)x\(size.height)|\(combined)|\(style.base64EncodedString())"
        if metricsKey != nextMetricsKey {
            cachedMetrics = TextTypography(text: combined, config: config, size: size)
            metricsKey = nextMetricsKey
        }
        guard let metrics = cachedMetrics else { return nil }
        let font = metrics.font, fontSize = metrics.fontSize, lineHeight = metrics.lineHeight
        let available = metrics.availableWidth
        var positioned: [(particle: Particle, glyph: Glyph, x: CGFloat, row: Int)] = []
        var rowWidths: [CGFloat] = [0]
        var row = 0
        for particle in particles {
            let key = "\(fontSize)|\(TextTypography.text(particle.text, config: config))"
            if glyphs[key] == nil { glyphs[key] = Self.glyph(particle.text, font: font, config: config) }
            guard let glyph = glyphs[key] else { continue }
            if rowWidths[row] > 0 && rowWidths[row] + glyph.advance > available {
                row += 1; rowWidths.append(0)
            }
            positioned.append((particle, glyph, rowWidths[row], row))
            rowWidths[row] += glyph.advance
            if particle.text.contains("\n") { row += 1; rowWidths.append(0) }
        }
        if rowWidths.last == 0 && rowWidths.count > 1 { rowWidths.removeLast() }
        let rowCount = rowWidths.count
        let firstRow = max(0, rowCount - metrics.rows(for: config))
        let contentHeight = CGFloat(rowCount - firstRow) * lineHeight
        let height = metrics.fixedHeight ?? (contentHeight + metrics.paddingY * 2)
        let left = size.width * config.x - metrics.width / 2 + metrics.paddingX
        let boxBottom = size.height * (1 - config.y) - height / 2
        let top = boxBottom + TextTypography.top(contentHeight: contentHeight,
            boxHeight: height, padding: metrics.paddingY, config: config)
        let alignment = TextTypography.alignment(config)
        let canvas = CGRect(origin: .zero, size: size)
        var output = CIImage(color: .clear).cropped(to: canvas)
        for item in positioned where item.row >= firstRow && item.row < rowWidths.count {
            let age = max(0, now - item.particle.born)
            let alpha = envelope.opacity(age: age)
            let rowItems = positioned.filter { $0.row == item.row }
            let extra = max(0, available - rowWidths[item.row])
            let justify = alignment == .justified && (item.row < rowCount - 1 || config.justifyLastLine == true)
            let ordinal = rowItems.firstIndex { $0.particle.phrase == item.particle.phrase && $0.particle.index == item.particle.index } ?? 0
            let gap = justify && rowItems.count > 1 ? extra / CGFloat(rowItems.count - 1) : 0
            let flush: CGFloat = alignment == .right ? 1 : alignment == .center ? 0.5 : 0
            let x = left + (justify ? 0 : extra * flush) + item.x + gap * CGFloat(ordinal)
            let y = top - CGFloat(item.row - firstRow + 1) * lineHeight
            let tile = item.glyph.image.applyingFilter("CIColorMatrix", parameters: [
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))
            ]).transformed(by: CGAffineTransform(translationX: x, y: y))
            output = tile.composited(over: output)
        }
        // Keep the tile cache bounded over long speaking sessions.
        if glyphs.count > 256 { glyphs = [:] }
        guard particles.contains(where: { envelope.opacity(age: now - $0.born) > 0 }) else { return nil }
        return output.cropped(to: canvas)
    }

    private static func glyph(_ text: String, font: CTFont, config: TextLayerConfig) -> Glyph? {
        let line = CTLineCreateWithAttributedString(NSAttributedString(
            string: TextTypography.text(text, config: config), attributes: TextTypography.attributes(config, font: font)))
        let advance = max(1, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
        let padding: CGFloat = 3
        let width = Int(ceil(advance + padding * 2))
        let height = Int(ceil(CTFontGetAscent(font) + CTFontGetDescent(font) + padding * 2))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: CGFloat(config.background.red), green: CGFloat(config.background.green),
            blue: CGFloat(config.background.blue), alpha: CGFloat(config.background.alpha)))
        context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: padding, y: CTFontGetDescent(font) + padding)
        CTLineDraw(line, context)
        guard let image = context.makeImage() else { return nil }
        return Glyph(image: CIImage(cgImage: image), advance: advance)
    }
}
