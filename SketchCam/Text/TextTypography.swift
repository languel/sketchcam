import CoreGraphics
import CoreText
import Foundation
import SketchCamCore

/// One typography contract for page fitting, glyph drawing and word particles.
/// Case conversion is presentation-only; source scripts/transcripts stay intact.
struct TextTypography {
    let font: CTFont
    let fontSize: CGFloat
    let width: CGFloat
    let paddingX: CGFloat
    let paddingY: CGFloat
    let lineHeight: CGFloat
    let fixedHeight: CGFloat?
    let attributes: [NSAttributedString.Key: Any]
    var availableWidth: CGFloat { max(1, width - paddingX * 2) }

    static func text(_ text: String, config: TextLayerConfig) -> String {
        switch config.letterCase ?? .original {
        case .original: return text
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        }
    }

    init(text: String, config: TextLayerConfig, size: CGSize) {
        let requested = max(6, size.height * min(0.5, max(0.005, config.fontSize)))
        let boxWidth = size.width * max(0.05, min(1, config.width))
        let boxHeight = config.height.map { size.height * min(1, max(0.02, $0)) }
        var resolved = requested
        if let boxHeight, config.fontFit != nil, config.fontFit != .fixed, !text.isEmpty {
            var low: CGFloat = 6
            var high: CGFloat = config.fontFit == .shrink ? requested : max(6, size.height)
            for _ in 0..<12 {
                let candidate = (low + high) / 2
                if Self.fits(text, config: config, fontSize: candidate, width: boxWidth, height: boxHeight) {
                    low = candidate
                } else { high = candidate }
            }
            resolved = low
        }
        fontSize = resolved
        let resolvedFont = Self.makeFont(config, size: resolved)
        font = resolvedFont
        width = boxWidth
        let defaultPadding = config.style == .trail ? 0.15 : 0.25
        paddingX = min(boxWidth / 4, resolved * min(4, max(0, config.paddingHorizontal ?? defaultPadding)))
        paddingY = resolved * min(4, max(0, config.paddingVertical ?? defaultPadding))
        lineHeight = Self.lineHeight(resolvedFont, config: config)
        fixedHeight = boxHeight
        attributes = Self.attributes(config, font: resolvedFont)
    }

    func rows(for config: TextLayerConfig) -> Int {
        let requested = max(1, min(12, config.lineLimit))
        guard let fixedHeight else { return requested }
        return max(1, min(requested, Int(floor(max(0, fixedHeight - paddingY * 2) / lineHeight))))
    }

    static func makeFont(_ config: TextLayerConfig, size: CGFloat) -> CTFont {
        let base = CTFontCreateWithName(config.fontName as CFString, size, nil)
        var traits: CTFontSymbolicTraits = []
        if config.bold == true { traits.insert(.traitBold) }
        if config.italic == true { traits.insert(.traitItalic) }
        guard !traits.isEmpty else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, traits, traits) ?? base
    }

    static func attributes(_ config: TextLayerConfig, font: CTFont) -> [NSAttributedString.Key: Any] {
        let c = config.color
        var result: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
                red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha))
        ]
        if let tracking = config.letterSpacing, tracking != 0 {
            result[NSAttributedString.Key(kCTTrackingAttributeName as String)] = CTFontGetSize(font) * min(1, max(-0.1, tracking))
        }
        return result
    }

    static func lineHeight(_ font: CTFont, config: TextLayerConfig) -> CGFloat {
        let natural = CTFontGetAscent(font) + CTFontGetDescent(font) + max(CTFontGetLeading(font), CTFontGetSize(font) * 0.15)
        return natural * CGFloat(min(3, max(0.6, config.lineSpacing ?? 1)))
    }

    static func alignment(_ config: TextLayerConfig) -> TextHorizontalAlignment {
        let value = config.alignment ?? .automatic
        return value == .automatic ? (config.style == .typeOn ? .left : .center) : value
    }

    static func top(contentHeight: CGFloat, boxHeight: CGFloat, padding: CGFloat,
                    config: TextLayerConfig) -> CGFloat {
        switch config.verticalAlignment ?? .top {
        case .top: return boxHeight - padding
        case .center: return (boxHeight + contentHeight) / 2
        case .bottom: return padding + contentHeight
        }
    }

    private static func fits(_ text: String, config: TextLayerConfig, fontSize: CGFloat,
                             width: CGFloat, height: CGFloat) -> Bool {
        let font = makeFont(config, size: fontSize)
        let paddingX = min(width / 4, fontSize * CGFloat(min(4, max(0, config.paddingHorizontal ?? 0.25))))
        let paddingY = fontSize * CGFloat(min(4, max(0, config.paddingVertical ?? 0.25)))
        let string = NSAttributedString(string: String(text.suffix(2000)), attributes: attributes(config, font: font))
        let typesetter = CTTypesetterCreateWithAttributedString(string)
        var offset = 0, rows = 0
        while offset < string.length && rows <= max(1, min(12, config.lineLimit)) {
            offset += max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(max(1, width - paddingX * 2))))
            rows += 1
        }
        return offset >= string.length && rows <= max(1, min(12, config.lineLimit)) &&
            CGFloat(rows) * lineHeight(font, config: config) + paddingY * 2 <= height
    }
}
