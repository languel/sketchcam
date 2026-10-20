import Foundation
import SketchCamCore

/// Presentation-only: commands, raw transcripts and audio retain their source data.
enum SpeechCaptionFilter {
    static let defaults = "um, uh, erm, er, hmm"

    static func apply(_ phrase: TranscriptPhrase, config: TextLayerConfig) -> TranscriptPhrase {
        guard config.filterFillers == true, !SpeechTextContent.isBlank(phrase.text) else { return phrase }
        let words = Set((config.fillerWords ?? defaults).split(separator: ",").map { normalized(String($0)) }.filter { !$0.isEmpty })
        var result = phrase
        result.text = TextLayerRenderer.scriptUnits(phrase.text)
            .filter { !words.contains(normalized($0)) }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        result.words = phrase.words.filter { !words.contains(normalized($0.text)) }
        return result
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters)).lowercased()
    }
}
