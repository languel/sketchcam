import XCTest
import CoreGraphics
import CoreImage
import SketchCamCore
@testable import SketchCam

final class AudioTextTests: XCTestCase {
    func testToneProducesLoudnessPitchAndSpectrum() throws {
        let samples = (0..<4096).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 48000)) }
        let packet = AudioPacket(source: .microphone, session: UUID(), timestamp: 1,
            mediaTime: 0, sampleRate: 48000, samples: samples)
        let features = AudioFeatureAnalyzer().analyze(packet)
        XCTAssertEqual(features.rms, 0.3535, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(features.pitchHz), 440, accuracy: 12)
        XCTAssertGreaterThan(features.pitchConfidence, 0.7)
        let bin = try XCTUnwrap(features.spectrum.indices.max(by: { features.spectrum[$0] < features.spectrum[$1] }))
        XCTAssertEqual(Float(bin) * features.spectrumHzPerBin, 440, accuracy: 25)
        let silence = AudioPacket(source: .microphone, session: UUID(), timestamp: 2,
            mediaTime: 1, sampleRate: 48000, samples: Array(repeating: 0, count: 4096))
        XCTAssertNil(AudioFeatureAnalyzer().analyze(silence).pitchHz)
    }

    func testScriptSegmentationPreservesChineseAndBulgarian() {
        for text in ["Hello, world!\nNext line.", "你好世界，这是一个测试。", "Здравей, свят!"] {
            let units = TextLayerRenderer.scriptUnits(text)
            XCTAssertFalse(units.isEmpty)
            XCTAssertEqual(units.joined(), text)
        }
    }

    func testStrokeEventsRevealTextForIndependentConsumersAndResetClearsIt() {
        let store = TemporalStreamStore(), renderer = TextLayerRenderer()
        var config = TextLayerConfig(); config.style = .word; config.trigger = .strokeStart
        let a = Node(name: "A", kind: .text(config), managed: false)
        let b = Node(name: "B", kind: .text(config), managed: false)
        let size = CGSize(width: 640, height: 360)
        func render(_ node: Node) -> Bool {
            renderer.image(node: node, script: "one two", snapshot: store.snapshot(), size: size, now: 1) != nil
        }
        XCTAssertFalse(render(a)); XCTAssertFalse(render(b))
        store.emit(.strokeEnd)
        XCTAssertFalse(render(a))
        store.emit(.strokeStart)
        XCTAssertTrue(render(a)); XCTAssertTrue(render(b))
        store.resetText()
        XCTAssertFalse(render(a)); XCTAssertFalse(render(b))
    }

    func testSpeechWordBatchesDisplayEveryWordEvenAfterPhraseHoldExpires() {
        for hold in [0.0, 1.0] {
            var playback = SpeechWordPlayback()
            playback.receive(phrase("one two three", id: UUID()))
            XCTAssertEqual(playback.display(at: 10, holdSeconds: hold).text, "one")
            XCTAssertEqual(playback.display(at: 10.05, holdSeconds: hold).text, "one")
            // Even a long frame stall must show the next queued word.
            XCTAssertEqual(playback.display(at: 20, holdSeconds: hold).text, "two")
            XCTAssertEqual(playback.display(at: 30, holdSeconds: hold).text, "three")
            XCTAssertEqual(playback.display(at: 40, holdSeconds: hold).text, hold == 0 ? "three" : "")
        }
    }

    func testPartialRevisionsReplaceUnshownWordsAndFinalDoesNotReplayThem() {
        var playback = SpeechWordPlayback()
        let id = UUID()
        playback.receive(phrase("one wrong", id: id))
        XCTAssertEqual(playback.display(at: 0, holdSeconds: 1).text, "one")
        playback.receive(phrase("one two three", id: id))
        XCTAssertEqual(playback.display(at: 1, holdSeconds: 1).text, "two")
        var final = phrase("one two three", id: id); final.committed = true
        playback.receive(final)
        XCTAssertEqual(playback.display(at: 2, holdSeconds: 1).text, "three")
        playback.receive(final)
        XCTAssertEqual(playback.display(at: 10, holdSeconds: 1).text, "")
    }

    func testNewSpeechPhraseDoesNotDiscardPendingWords() {
        var playback = SpeechWordPlayback()
        playback.receive(phrase("one two", id: UUID()))
        XCTAssertEqual(playback.display(at: 0, holdSeconds: 1).text, "one")
        playback.receive(phrase("three four", id: UUID()))
        XCTAssertEqual(playback.display(at: 1, holdSeconds: 1).text, "two")
        XCTAssertEqual(playback.display(at: 2, holdSeconds: 1).text, "three")
        XCTAssertEqual(playback.display(at: 3, holdSeconds: 1).text, "four")
    }

    func testPacedPartialAppendKeepsWordSeparatorsAndRevisionsDoNotSkipTail() {
        var playback = SpeechWordPlayback()
        let id = UUID()
        playback.receive(phrase("one", id: id))
        XCTAssertEqual(playback.display(at: 0, holdSeconds: 0).phraseText, "one")
        playback.receive(phrase("one two three", id: id))
        XCTAssertEqual(playback.display(at: 1, holdSeconds: 0).phraseText, "one two ")
        XCTAssertEqual(playback.display(at: 2, holdSeconds: 0).text, "three")
        // A final decoder revision removes an already delivered word. The new
        // fourth word must not be skipped by reusing the old numeric index.
        playback.receive(phrase("one three four", id: id))
        XCTAssertEqual(playback.display(at: 3, holdSeconds: 0).text, "four")
        XCTAssertEqual(playback.display(at: 3.1, holdSeconds: 0).phraseText, "one two three four")
    }

    func testPacedRendererDrainsHistoryEvenWhenLatestResultIsBlank() {
        let store = TemporalStreamStore(), renderer = TextLayerRenderer()
        var config = TextLayerConfig(); config.speechTiming = .paced; config.style = .word
        config.fontSize = 0.08; config.background.alpha = 0; config.captionLifetime = .untilReplaced
        let node = Node(name: "Speech", kind: .text(config),
            inputs: [.source(.microphoneText), .source(.microphone)], managed: false)
        let size = CGSize(width: 640, height: 360)
        func render(_ time: Double) -> CIImage? {
            renderer.image(node: node, script: "", snapshot: store.snapshot(), size: size, now: time)
        }
        XCTAssertNil(render(0)) // Join before recognition publishes any words.
        store.publish(phrase("one two", id: UUID()), source: .microphone)
        store.publish(phrase("three four", id: UUID()), source: .microphone)
        store.publish(phrase("[BLANK_AUDIO]", id: UUID()), source: .microphone)
        XCTAssertEqual(store.snapshot().transcriptHistory[.microphone]?.count, 3)
        for time in [1.0, 2.0, 3.0, 4.0] { XCTAssertNotNil(render(time)) }
        XCTAssertNotNil(render(500))
    }

    func testHoldUntilReplacedOverridesWordExpiryAndBlankClearing() {
        var config = TextLayerConfig()
        config.captionLifetime = .untilReplaced; config.fadeInSeconds = 0.1
        config.wordHoldSeconds = 0.01; config.fadeOutSeconds = 0.2
        config.silenceDelaySeconds = 0; config.silencePolicy = .hidden
        XCTAssertTrue(TextWordEnvelope(config).lifetime.isInfinite)
        XCTAssertEqual(TextWordEnvelope(config).opacity(age: 500), 1)
        let store = TemporalStreamStore(), renderer = TextLayerRenderer()
        let node = Node(name: "Headline", kind: .text(config),
            inputs: [.source(.microphoneText), .source(.microphone)], managed: false)
        let size = CGSize(width: 640, height: 360)
        store.publish(phrase("one two", id: UUID()), source: .microphone)
        _ = renderer.image(node: node, script: "", snapshot: store.snapshot(), size: size, now: 0)
        store.publish(phrase("(clicking)", id: UUID()), source: .microphone)
        XCTAssertNotNil(renderer.image(node: node, script: "", snapshot: store.snapshot(), size: size, now: 500))
        config.captionLifetime = .timed
        XCTAssertEqual(TextWordEnvelope(config).opacity(age: 500), 0)
        XCTAssertEqual(TextPresetStore.builtins.first { $0.name == "Justified headline" }?.configuration.captionLifetime, .untilReplaced)
    }

    func testImmediateLayoutsUseCurrentWordsWithoutReplay() {
        var config = TextLayerConfig()
        config.style = .word; config.wordCount = 2
        let size = CGSize(width: 1920, height: 1080)
        XCTAssertEqual(TextLayerRenderer.speechText("one two three", config: config, size: size), "two three")
        XCTAssertEqual(TextLayerRenderer.speechText("one two three four", config: config, size: size), "three four")
        config.wordCount = 1
        XCTAssertEqual(TextLayerRenderer.speechText("one two three", config: config, size: size), "three")
        config.style = .subtitles; config.wordsPerCue = 3
        XCTAssertEqual(TextLayerRenderer.speechText("one two three four", config: config, size: size), "four")
        config.style = .build
        XCTAssertEqual(TextLayerRenderer.speechText("one two three four", config: config, size: size), "one two three four")
    }

    func testBuildPhraseStartsANewPageWhenAreaFills() {
        var config = TextLayerConfig(); config.style = .build
        config.width = 0.2; config.fontSize = 0.1; config.lineLimit = 1
        let text = "one two three four five six seven eight nine ten"
        let size = CGSize(width: 640, height: 360)
        let page = TextLayerRenderer.fittingPage(text, config: config, size: size)
        XCTAssertNotEqual(page, text)
        XCTAssertTrue(page.hasSuffix("ten"))
        XCTAssertEqual(TextLayerRenderer.fittingPage(page, config: config, size: size), page)
    }

    func testWordFadeIsIndependentOfNewArrivals() {
        let trail = FadingWordTrail(), id = UUID()
        var config = TextLayerConfig(); config.style = .trail; config.fadeSeconds = 1
        let size = CGSize(width: 640, height: 360)
        XCTAssertTrue(trail.receive(phrase("one", id: id), at: 0))
        XCTAssertTrue(trail.receive(phrase("one two", id: id), at: 0.75))
        XCTAssertNotNil(trail.image(config: config, size: size, now: 1.1))
        XCTAssertFalse(trail.receive(phrase("one two", id: id), at: 1.7))
        XCTAssertNil(trail.image(config: config, size: size, now: 1.8))
    }

    func testProgressDoesNotEnqueueHalfWords() {
        XCTAssertEqual(SpeechTranscriptionService.completeProgressText("hello wor"), "hello")
        XCTAssertEqual(SpeechTranscriptionService.completeProgressText("hello world "), "hello world")
        XCTAssertEqual(SpeechTranscriptionService.completeProgressText("hello world!"), "hello world!")
        XCTAssertEqual(SpeechTranscriptionService.completeProgressText("你好世界"), "你好世界")
    }

    func testTypeOnKeepsItsTopLeftGlyphsFixedAsRowsFill() throws {
        var config = TextLayerConfig(); config.style = .typeOn
        config.lineLimit = 2; config.fontSize = 0.08; config.width = 0.8
        config.background = RGBAColor(red: 0, green: 0, blue: 0, alpha: 0)
        let size = CGSize(width: 640, height: 360)
        let first = try XCTUnwrap(TextLayerRenderer.rasterize("one", config: config, size: size))
        let context = CIContext()
        // Inspect the same leading glyph patch for horizontal recentering and
        // vertical movement when a second row becomes occupied.
        let patch = CGRect(x: first.extent.minX, y: first.extent.maxY - first.extent.height / 3,
                           width: 30, height: first.extent.height / 3).integral
        func pixels(_ image: CIImage) throws -> Data {
            let cg = try XCTUnwrap(context.createCGImage(image, from: patch, format: .RGBA8,
                                                       colorSpace: CGColorSpaceCreateDeviceRGB()))
            return try XCTUnwrap(cg.dataProvider?.data) as Data
        }
        let reference = try pixels(first)
        XCTAssertTrue(reference.contains { $0 != 0 })
        for text in ["one two", "one\ntwo"] {
            let next = try XCTUnwrap(TextLayerRenderer.rasterize(text, config: config, size: size))
            XCTAssertEqual(next.extent, first.extent)
            XCTAssertEqual(try pixels(next), reference)
        }
    }

    func testTypeOnPaginatesWithoutChangingOtherDrawingStyles() {
        var config = TextLayerConfig(); config.style = .typeOn
        config.width = 0.2; config.fontSize = 0.1; config.lineLimit = 2
        let text = "one two three four five six seven eight nine ten"
        let size = CGSize(width: 640, height: 360)
        let page = TextLayerRenderer.speechText(text, config: config, size: size)
        XCTAssertNotEqual(page, text)
        XCTAssertTrue(page.hasSuffix("ten"))
        config.style = .build
        XCTAssertEqual(TextLayerRenderer.speechText(text, config: config, size: size), page)
    }

    func testTypographyCasePaddingAndFitAreSharedByMeasurement() {
        var config = TextLayerConfig()
        let source = "Hello, свят!"
        config.letterCase = .uppercase
        XCTAssertEqual(TextTypography.text(source, config: config), "HELLO, СВЯТ!")
        XCTAssertEqual(source, "Hello, свят!")
        config.paddingHorizontal = 1; config.paddingVertical = 0.5
        config.fontSize = 0.1
        let size = CGSize(width: 1000, height: 500)
        let normal = TextTypography(text: source, config: config, size: size)
        XCTAssertEqual(normal.paddingX, normal.fontSize, accuracy: 0.01)
        XCTAssertEqual(normal.paddingY, normal.fontSize * 0.5, accuracy: 0.01)
        config.height = 0.1; config.fontFit = .shrink
        let fitted = TextTypography(text: String(repeating: source, count: 5), config: config, size: size)
        XCTAssertLessThanOrEqual(fitted.fontSize, normal.fontSize)
        XCTAssertLessThanOrEqual(fitted.rows(for: config), config.lineLimit)
        config.style = .typeOn; config.alignment = nil
        XCTAssertEqual(TextTypography.alignment(config), .left)
        config.alignment = .right
        XCTAssertEqual(TextTypography.alignment(config), .right)
    }

    func testTextPresetPersistenceReplaceAndImportCollision() throws {
        let suite = "sketchcam.text.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TextPresetStore(defaults: defaults)
        var config = TextLayerConfig(); config.letterCase = .uppercase; config.paddingHorizontal = 0.7
        let first = store.save(name: "My look", configuration: config)
        config.alignment = .justified
        let replaced = store.save(name: "MY LOOK", configuration: config)
        XCTAssertEqual(first.id, replaced.id)
        XCTAssertEqual(store.presets.count, 1)
        let reopened = TextPresetStore(defaults: defaults)
        XCTAssertEqual(reopened.presets.first?.configuration, config)
        let imported = try reopened.importPreset(store.export(replaced))
        XCTAssertEqual(imported.name, "My look 2")
        XCTAssertEqual(imported.configuration, config)
        XCTAssertNotEqual(imported.id, first.id)
        reopened.delete(imported)
        XCTAssertEqual(reopened.presets.count, 1)
        var file = try XCTUnwrap(JSONSerialization.jsonObject(with: store.export(replaced)) as? [String: Any])
        file["format"] = "SketchCamPortrait"
        XCTAssertThrowsError(try store.importPreset(JSONSerialization.data(withJSONObject: file)))
    }

    func testWordEnvelopeAttackHoldReleaseAndZeroCompatibility() {
        var config = TextLayerConfig()
        XCTAssertFalse(TextWordEnvelope(config).enabled)
        XCTAssertEqual(TextWordEnvelope(config).opacity(age: 100), 1)
        config.fadeInSeconds = 0.2; config.wordHoldSeconds = 0.5; config.fadeOutSeconds = 0.3
        let envelope = TextWordEnvelope(config)
        XCTAssertEqual(envelope.opacity(age: 0), 0)
        XCTAssertEqual(envelope.opacity(age: 0.1), 0.5, accuracy: 0.001)
        XCTAssertEqual(envelope.opacity(age: 0.5), 1)
        XCTAssertEqual(envelope.opacity(age: 0.85), 0.5, accuracy: 0.001)
        XCTAssertEqual(envelope.opacity(age: 1.1), 0)
        config.style = .trail; config.fadeInSeconds = nil; config.wordHoldSeconds = nil; config.fadeOutSeconds = nil
        XCTAssertEqual(TextWordEnvelope(config).opacity(age: 1.25), 0.25, accuracy: 0.001)
    }

    func testVoiceResponseHasIndependentRiseFallAndZeroIsImmediate() {
        var response = TextVoiceResponse()
        _ = response.update(target: 0, at: 0, rise: 1, fall: 2)
        XCTAssertEqual(response.update(target: 1, at: 1, rise: 1, fall: 2), 0.9, accuracy: 0.001)
        XCTAssertEqual(response.update(target: 0, at: 3, rise: 1, fall: 2), 0.09, accuracy: 0.001)
        XCTAssertEqual(response.update(target: 0.7, at: 3.1, rise: 0, fall: 0), 0.7)
    }

    func testSilenceGateAndMarkerPolicies() {
        var gate = TextSilenceGate()
        let id = UUID()
        var input = phrase("hello", id: id)
        var features = AudioFeatures(); features.speechActive = true; features.timestamp = 0
        XCTAssertFalse(gate.isSilent(phrase: input, features: features, at: 0, delay: 0.5))
        features.speechActive = false; features.timestamp = 1
        input.updatedAt = 1 // duplicate decoding does not prolong the caption.
        XCTAssertTrue(gate.isSilent(phrase: input, features: features, at: 1, delay: 0.5))
        input.text = "hello world"
        XCTAssertFalse(gate.isSilent(phrase: input, features: features, at: 1.1, delay: 0.5))
        input.text = "[BLANK_AUDIO]"
        XCTAssertTrue(gate.isSilent(phrase: input, features: features, at: 1.2, delay: 0.5))
        var config = TextLayerConfig()
        XCTAssertEqual(SpeechTextContent.placeholder(config), "")
        config.silencePolicy = .ellipsis; XCTAssertEqual(SpeechTextContent.placeholder(config), "…")
        config.silencePolicy = .label; XCTAssertEqual(SpeechTextContent.placeholder(config), "[blank audio]")
        config.silencePolicy = .custom; config.silenceText = "listening"
        XCTAssertEqual(SpeechTextContent.placeholder(config), "listening")
        XCTAssertFalse(SpeechTextContent.isBlank("I said blank audio"))
    }

    func testPartialSilenceMarkersCannotBecomeCaptionWords() {
        for marker in ["[", "[ ...", "[ … ]", "[BL", "[BLANK_", "[BLANK AUDIO", "(blank", "<|no", "[BLANK_AUDIO]"] {
            XCTAssertTrue(SpeechTextContent.isBlank(marker), marker)
            XCTAssertEqual(SpeechTextContent.cleaned("hello " + marker), "hello", marker)
        }
        XCTAssertEqual(SpeechTextContent.cleaned("hello [BLANK_AUDIO] world"), "hello world")
        XCTAssertEqual(SpeechTextContent.parsed("[hello]").annotations.first?.name, "hello")
        XCTAssertEqual(SpeechTextContent.cleaned("I said blank audio"), "I said blank audio")
        // Retain trailing whitespace: it marks a completed word in live decoding.
        let progress = SpeechTextContent.cleaned("hello ", trim: false)
        XCTAssertEqual(SpeechTranscriptionService.completeProgressText(progress), "hello")
        XCTAssertEqual(SpeechTranscriptionService.completeProgressText(
            SpeechTextContent.cleaned("hello [", trim: false)), "hello")
    }

    func testRecognitionAnnotationsAreMetadataAndFinalOnlyEvents() {
        let raw = "Hello (clicking) world [LAUGHTER] (door slams)"
        let parsed = SpeechTextContent.parsed(raw)
        XCTAssertEqual(parsed.text, "Hello world")
        XCTAssertEqual(parsed.annotations.map(\.name), ["clicking", "laughter", "door_slams"])
        XCTAssertEqual(parsed.annotations.first?.rawText, "(clicking)")
        XCTAssertTrue(SpeechTextContent.isBlank("(clicking)"))
        XCTAssertEqual(SpeechTextContent.cleaned("hello (click", trim: false), "hello ")
        let store = TemporalStreamStore()
        var input = TranscriptPhrase(id: UUID(), text: parsed.text, words: [], language: "en",
            committed: false, updatedAt: 1, annotations: parsed.annotations, rawText: raw)
        store.publish(input, source: .microphone)
        XCTAssertTrue(store.snapshot().voiceEvents.isEmpty)
        input.committed = true
        store.publish(input, source: .microphone)
        store.publish(input, source: .microphone)
        let snapshot = store.snapshot()
        XCTAssertEqual(snapshot.voiceEvents.map(\.name), ["annotation.clicking", "annotation.laughter", "annotation.door_slams"])
        XCTAssertEqual(snapshot.voiceEvents.first?.annotation, parsed.annotations.first)
        XCTAssertEqual(snapshot.voiceEvents.first?.source, .microphone)
        XCTAssertEqual(snapshot.phrases[.microphone]?.rawText, raw)
        input.id = UUID()
        store.publish(input, source: .recordedAudio)
        XCTAssertEqual(store.snapshot().voiceEvents.count, 6)
        XCTAssertEqual(store.snapshot().voiceEvents.last?.source, .recordedAudio)

        let words = ["Hello", " (", "clicking", ")", " world"].enumerated().map { index, text in
            TranscriptWord(text: text, start: Double(index), end: Double(index + 1), confidence: 1)
        }
        XCTAssertEqual(SpeechTextContent.displayWords(words).map(\.text), ["Hello", " world"])
    }

    func testAnnotationEventsCanAdvanceLiteralScriptText() {
        let store = TemporalStreamStore(), renderer = TextLayerRenderer()
        var config = TextLayerConfig(); config.trigger = .voice; config.voiceEventName = "annotation.clicking"
        config.fadeInSeconds = 0.1
        let node = Node(name: "Poem", kind: .text(config), managed: false)
        let size = CGSize(width: 640, height: 360)
        XCTAssertNil(renderer.image(node: node, script: "(clicking)", snapshot: store.snapshot(), size: size, now: 0))
        let parsed = SpeechTextContent.parsed("(clicking)")
        store.publish(TranscriptPhrase(id: UUID(), text: parsed.text, words: [], language: "en",
            committed: true, updatedAt: 1, annotations: parsed.annotations), source: .microphone)
        _ = renderer.image(node: node, script: "(clicking)", snapshot: store.snapshot(), size: size, now: 1)
        XCTAssertNotNil(renderer.image(node: node, script: "(clicking)", snapshot: store.snapshot(), size: size, now: 1.2))
    }

    func testWordIdentityAndReleaseAcrossCueReplacement() {
        var timeline = TextWordTimeline()
        let id = UUID()
        timeline.receive(id: id, text: "one", at: 0)
        let first = timeline.visible(for: "one")[0]
        timeline.receive(id: id, text: "one two", at: 1)
        let both = timeline.visible(for: "one two")
        XCTAssertEqual(both[0].id, first.id)
        XCTAssertEqual(both[0].born, 0)
        XCTAssertEqual(both[1].born, 1)
        var config = TextLayerConfig(); config.wordHoldSeconds = 5; config.fadeOutSeconds = 0.2
        let renderer = TextWordRenderer(), size = CGSize(width: 640, height: 360)
        XCTAssertNotNil(renderer.image(text: "one", lives: [first], config: config, size: size, now: 0))
        XCTAssertNotNil(renderer.image(text: "two", lives: [both[1]], config: config, size: size, now: 1))
        XCTAssertNotNil(renderer.image(text: "", lives: [], config: config, size: size, now: 1.1))
        XCTAssertNil(renderer.image(text: "", lives: [], config: config, size: size, now: 1.4))
    }

    func testBlankTranscriptIsHiddenUnlessPlaceholderIsSelected() {
        let store = TemporalStreamStore(), renderer = TextLayerRenderer()
        store.publish(phrase("[BLANK_AUDIO]", id: UUID()), source: .microphone)
        var config = TextLayerConfig(); config.style = .build
        var node = Node(name: "Speech", kind: .text(config),
            inputs: [.source(.microphoneText), .source(.microphone)], managed: false)
        let size = CGSize(width: 640, height: 360)
        XCTAssertNil(renderer.image(node: node, script: "", snapshot: store.snapshot(), size: size, now: 10))
        config.silencePolicy = .label; node.kind = .text(config)
        XCTAssertNotNil(renderer.image(node: node, script: "", snapshot: store.snapshot(), size: size, now: 11))
    }

    func testFillerFilterIsOptionalAndPreservesRawPhrase() {
        let original = phrase("Um, hello uh world! Like this.", id: UUID())
        var config = TextLayerConfig()
        XCTAssertEqual(SpeechCaptionFilter.apply(original, config: config), original)
        config.filterFillers = true
        XCTAssertEqual(SpeechCaptionFilter.apply(original, config: config).text, "hello world! Like this.")
        XCTAssertEqual(original.text, "Um, hello uh world! Like this.")
        config.fillerWords = "hello"
        XCTAssertEqual(SpeechCaptionFilter.apply(original, config: config).text, "Um, uh world! Like this.")
    }

    func testVoiceCommandsRequireArmedFinalMicSpeechAndDeduplicate() throws {
        let suite = "SketchCamVoiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = TemporalStreamStore()
        let commands = VoiceCommandController(streams: store, defaults: defaults)
        commands.mappings = [VoiceCommandMapping(phrase: "turn the page", value: "poem.next")]
        func final(_ text: String) -> TranscriptPhrase {
            var result = phrase(text, id: UUID()); result.committed = true; return result
        }
        commands.receive(final("voice MCP on"), source: .microphone)
        XCTAssertFalse(commands.armed)
        commands.listening = true
        commands.receive(final("voice MCP on"), source: .recordedAudio)
        XCTAssertFalse(commands.armed)
        commands.receive(phrase("voice MCP on", id: UUID()), source: .microphone)
        XCTAssertFalse(commands.armed)
        commands.receive(final("Voice M. C. P. on!"), source: .microphone)
        XCTAssertTrue(commands.armed)
        let event = final("Turn the page!")
        commands.receive(event, source: .microphone)
        commands.receive(event, source: .microphone)
        XCTAssertEqual(store.snapshot().voiceEvents.count, 1)
        XCTAssertEqual(store.snapshot().voiceEvents.first?.name, "poem.next")
        commands.receive(final("voice MCP off"), source: .microphone)
        commands.receive(final("turn the page"), source: .microphone)
        XCTAssertEqual(store.snapshot().voiceEvents.count, 1)
        XCTAssertEqual(VoiceCommandController(streams: store, defaults: defaults).mappings, commands.mappings)
        XCTAssertFalse(VoiceCommandController(streams: store, defaults: defaults).listening)
    }

    func testVoiceEventsAdvanceScriptWithoutConsumingOtherEvents() {
        let store = TemporalStreamStore(), renderer = TextLayerRenderer()
        var config = TextLayerConfig(); config.trigger = .voice; config.voiceEventName = "poem.next"
        let node = Node(name: "Poem", kind: .text(config), managed: false)
        func render() -> Bool {
            renderer.image(node: node, script: "one two", snapshot: store.snapshot(),
                size: CGSize(width: 640, height: 360), now: 1) != nil
        }
        XCTAssertFalse(render())
        store.emitVoice(name: "different", phrase: phrase("hello", id: UUID()))
        XCTAssertFalse(render())
        store.emitVoice(name: "poem next", phrase: phrase("turn the page", id: UUID()))
        XCTAssertTrue(render())
        XCTAssertEqual(store.snapshot().voiceEvents.count, 2)
    }

    private func phrase(_ text: String, id: UUID) -> TranscriptPhrase {
        TranscriptPhrase(id: id, text: text, words: [], language: "en", committed: false, updatedAt: 0)
    }

}
