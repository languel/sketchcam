import XCTest
@testable import SketchCamCore

final class TemporalStreamTests: XCTestCase {
    func testTextRoutesValidateBySignalTypeAndSurviveSerialization() throws {
        let node = Node(name: "Poem", kind: .text(TextLayerConfig()), managed: false)
        let graph = LayerGraph(nodes: [node], layers: [Layer(node: node.id)])
        try graph.validate()
        XCTAssertEqual(try JSONDecoder().decode(LayerGraph.self, from: JSONEncoder().encode(graph)), graph)
        var invalid = graph
        invalid.nodes[0].inputs[0] = .source(.microphone)
        XCTAssertThrowsError(try invalid.validate())
        invalid.nodes[0].inputs = [.source(.microphoneText), .source(.recordedAudio)]
        try invalid.validate()
    }

    func testRawConsumersDoNotConsumeEachOthersPacketsAndHistoryIsBounded() {
        let store = TemporalStreamStore()
        let first = Counter(), second = Counter()
        let a = store.subscribe { _, _ in first.increment() }
        let b = store.subscribe { _, _ in second.increment() }
        let packet = AudioPacket(source: .microphone, session: UUID(), timestamp: 1,
            mediaTime: 0, sampleRate: 10, samples: Array(repeating: 0.25, count: 100))
        store.publish(packet, features: AudioFeatures())
        XCTAssertEqual(first.value, 1); XCTAssertEqual(second.value, 1)
        XCTAssertEqual(store.recentAudio(.microphone).samples.count, 80)
        XCTAssertTrue(store.recentAudio(.recordedAudio).samples.isEmpty)
        store.unsubscribe(a)
        store.publish(packet, features: AudioFeatures())
        XCTAssertEqual(first.value, 1); XCTAssertEqual(second.value, 2)
        store.unsubscribe(b)
        store.clear(.microphone)
        XCTAssertTrue(store.recentAudio(.microphone).samples.isEmpty)
    }

    func testEventsAreNonConsumingAndBounded() {
        let store = TemporalStreamStore()
        for _ in 0..<300 { store.emit(.strokeStart, at: 1) }
        let a = store.snapshot(), b = store.snapshot()
        XCTAssertEqual(a.events.count, 256)
        XCTAssertEqual(a.serial, b.serial)
        store.resetText()
        XCTAssertNotEqual(a.resetRevision, store.snapshot().resetRevision)
    }

    func testOlderTextStylesDecodeWithImmediateDefaults() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(TextLayerConfig())) as? [String: Any])
        for key in ["speechTiming", "wordCount", "fadeSeconds", "alignment", "verticalAlignment", "letterCase", "bold", "italic", "paddingHorizontal", "paddingVertical", "letterSpacing", "lineSpacing", "justifyLastLine", "height", "fontFit", "cornerRadius", "silencePolicy", "silenceText", "silenceDelaySeconds", "fadeInSeconds", "wordHoldSeconds", "fadeOutSeconds", "voiceRiseSeconds", "voiceFallSeconds"] { json.removeValue(forKey: key) }
        let config = try JSONDecoder().decode(TextLayerConfig.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(config.speechTiming)
        XCTAssertNil(config.wordCount)
        XCTAssertNil(config.fadeSeconds)
        XCTAssertNil(config.alignment)
        XCTAssertNil(config.height)
        XCTAssertNil(config.paddingHorizontal)
        XCTAssertNil(config.fadeInSeconds)
        XCTAssertNil(config.silencePolicy)
        XCTAssertNil(config.filterFillers)
        XCTAssertNil(config.fillerWords)
        XCTAssertNil(config.voiceEventName)
        XCTAssertNil(config.captionLifetime)
    }

    func testSettingsWithoutScriptStillDecode() throws {
        let settings = ProcessingSettings()
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json.removeValue(forKey: "textScript")
        let decoded = try JSONDecoder().decode(ProcessingSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.textScript)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
