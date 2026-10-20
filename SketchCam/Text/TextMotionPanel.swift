import SwiftUI
import SketchCamCore

struct TextMotionPanel: View {
    @Binding var configuration: TextLayerConfig
    var speech: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if speech {
                DisclosureGroup("Silence") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("When blank", selection: option(\.silencePolicy, fallback: .hidden)) {
                            Text("Show nothing").tag(TextSilencePolicy.hidden)
                            Text("…").tag(TextSilencePolicy.ellipsis)
                            Text("[blank audio]").tag(TextSilencePolicy.label)
                            Text("Custom phrase").tag(TextSilencePolicy.custom)
                            Text("Keep last caption").tag(TextSilencePolicy.keepLast)
                        }.help("Show nothing is the default. Recognizer annotations are treated as metadata, not spoken words. Keep last caption overrides idle clearing, but timed word fades still apply. Word envelope → Hold until replaced overrides both idle clearing and word expiry.")
                        if configuration.silencePolicy == .custom {
                            TextField("Silence phrase", text: option(\.silenceText, fallback: ""))
                                .help("Your literal replacement text while speech is idle; it uses this layer's font and layout and remains until words return.")
                        }
                        row("Idle delay", value: option(\.silenceDelaySeconds, fallback: max(0.6, configuration.holdSeconds)), range: 0...15,
                            help: "Seconds without active audio or newly arriving words before the silence policy applies. Defaults to at least 0.6 seconds and the caption hold. Fades can finish after this delay. Activity uses an energy gate, not a neural speech detector.")
                    }.padding(.top, 4)
                }
            }
            DisclosureGroup("Word envelope") {
                VStack(alignment: .leading, spacing: 4) {
                    if configuration.style != .trail {
                        Picker("Lifetime", selection: option(\.captionLifetime, fallback: .timed)) {
                            Text("Timed / auto-fade").tag(TextCaptionLifetime.timed)
                            Text("Hold until replaced").tag(TextCaptionLifetime.untilReplaced)
                        }.help("Hold until replaced keeps the current caption and every visible word until incoming text changes the cue/page. It overrides idle/blank clearing and timed Hold expiry. Fade in still applies to arrivals; Fade out applies only to replaced words. Timed mode uses the full Fade in / Hold / Fade out envelope and Silence policy.")
                    }
                    row("Fade in", value: option(\.fadeInSeconds, fallback: 0), range: 0...10,
                        help: "Seconds for each new word to fade from transparent to full opacity. Zero appears instantly. Independent of font size and voice loudness.")
                    row("Hold", value: Binding(get: {
                        configuration.wordHoldSeconds ?? (configuration.style == .trail ? 0 : configuration.holdSeconds)
                    }, set: {
                        configuration.wordHoldSeconds = min(120, max(0, $0))
                        if configuration.style != .trail { configuration.holdSeconds = min(120, max(0, $0)) }
                    }), range: 0...30,
                        help: "Seconds each word stays fully visible between its fades in Timed mode. With fades off, retains the speech-caption tail behavior; zero retains the caption until a new cue or silence policy. Ignored in Hold until replaced. A zero hold with Fade out enabled starts releasing immediately after Fade in.")
                        .disabled(configuration.style != .trail && configuration.captionLifetime == .untilReplaced)
                    row("Fade out", value: option(\.fadeOutSeconds, fallback: configuration.style == .trail ? (configuration.fadeSeconds ?? 2.5) : 0), range: 0...15,
                        help: "Seconds for each word to become transparent after Hold, or when replaced by a new cue. Zero switches instantly. Word fades work in subtitle cues, N words, Build phrase, Type-on and Fading words.")
                }.padding(.top, 4)
            }
            DisclosureGroup("Motion response") {
                VStack(alignment: .leading, spacing: 4) {
                    row("Pop", value: $configuration.pop, range: 0...1,
                        help: "Size of a brief bounce when a word/cue arrives or a script advances. This is a text-arrival animation, not a loudness response. Zero disables the bounce.")
                    row("Voice scale", value: $configuration.loudnessScale, range: 0...1,
                        help: "Continuously enlarge text according to RMS loudness from Audio control. Independent of recognition and Pop. Zero disables it; choose None under Audio control to disconnect audio modulation.")
                    row("Voice rise", value: option(\.voiceRiseSeconds, fallback: 0), range: 0...3,
                        help: "Inertia when the voice-scale target increases. Time in seconds to travel 90% toward the louder target. Zero follows loudness immediately. Does not delay words or opacity fades.")
                    row("Voice fall", value: option(\.voiceFallSeconds, fallback: 0), range: 0...3,
                        help: "Inertia when the voice-scale target decreases or audio stops. Time in seconds to travel 90% toward the quieter target. A longer fall makes size settle gently. Zero is immediate.")
                }.padding(.top, 4)
            }
        }
    }
    private func option<T>(_ key: WritableKeyPath<TextLayerConfig, T?>, fallback: T) -> Binding<T> {
        Binding(get: { configuration[keyPath: key] ?? fallback }, set: { configuration[keyPath: key] = $0 })
    }
    private func row(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, help: String) -> some View {
        HStack(spacing: 4) {
            Text(label).frame(width: 72, alignment: .leading)
            Slider(value: value, in: range)
            TextField(label, value: value, format: .number.precision(.fractionLength(2)))
                .frame(width: 48).multilineTextAlignment(.trailing)
        }.help(help)
    }
}
