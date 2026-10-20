import CoreGraphics
import CoreImage
import CoreText
import Foundation
import SketchCamCore

/// Frozen Core Text layout. The static and animated paths share the same line
/// origins, justification and box geometry, so enabling fades cannot reflow text.
final class TextGlyphLayout {
    struct WordTile { var index: Int; var image: CIImage }
    private struct Line { var value: CTLine; var origin: CGPoint }
    private let metrics: TextTypography
    private let config: TextLayerConfig
    private let string: String
    private let lines: [Line]
    private let height: CGFloat
    private let origin: CGPoint

    init?(text: String, config: TextLayerConfig, size: CGSize) {
        guard !text.isEmpty, size.width > 0, size.height > 0 else { return nil }
        let styled = String(TextTypography.text(text, config: config).suffix(2000))
        let metrics = TextTypography(text: styled, config: config, size: size)
        let attributed = NSAttributedString(string: styled, attributes: metrics.attributes)
        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let ns = styled as NSString
        var raw: [CTLine] = [], ends: [Bool] = []
        let limit = metrics.rows(for: config)
        var offset = 0
        while offset < attributed.length && raw.count < limit {
            let length = min(attributed.length - offset,
                max(1, CTTypesetterSuggestLineBreak(typesetter, offset, Double(metrics.availableWidth))))
            var line = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length))
            let end = ns.substring(with: NSRange(location: offset, length: length)).contains("\n")
            if raw.count == limit - 1 && offset + length < attributed.length {
                let remainder = CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: attributed.length - offset))
                let dots = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: metrics.attributes))
                line = CTLineCreateTruncatedLine(remainder, Double(metrics.availableWidth), .end, dots) ?? line
            }
            raw.append(line); ends.append(end); offset += length
        }
        let rows = config.style == .typeOn ? limit : raw.count
        let height = metrics.fixedHeight ?? (metrics.lineHeight * CGFloat(rows) + metrics.paddingY * 2)
        let top = TextTypography.top(contentHeight: CGFloat(rows) * metrics.lineHeight,
            boxHeight: height, padding: metrics.paddingY, config: config)
        let alignment = TextTypography.alignment(config)
        let positioned = raw.enumerated().map { index, original -> Line in
            var line = original
            if alignment == .justified && (config.justifyLastLine == true || (index < raw.count - 1 && !ends[index])) {
                line = CTLineCreateJustifiedLine(line, 1, Double(metrics.availableWidth)) ?? line
            }
            let flush: CGFloat = alignment == .right ? 1 : alignment == .center ? 0.5 : 0
            return Line(value: line, origin: CGPoint(
                x: metrics.paddingX + CGFloat(CTLineGetPenOffsetForFlush(line, flush, Double(metrics.availableWidth))),
                y: top - CTFontGetAscent(metrics.font) - CGFloat(index) * metrics.lineHeight))
        }
        self.metrics = metrics; self.config = config; self.string = styled
        self.lines = positioned; self.height = height
        self.origin = CGPoint(x: size.width * config.x - metrics.width / 2,
                              y: size.height * (1 - config.y) - height / 2)
    }

    func image(backgroundOnly: Bool = false) -> CIImage? {
        let width = max(1, Int(ceil(metrics.width))), height = max(1, Int(ceil(self.height)))
        guard let context = Self.context(width: width, height: height) else { return nil }
        let c = config.background
        context.setFillColor(CGColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha)))
        let radius = max(0, metrics.fontSize * CGFloat(config.cornerRadius ?? Double(metrics.paddingX / metrics.fontSize)))
        context.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: metrics.width, height: self.height),
            cornerWidth: radius, cornerHeight: radius, transform: nil)); context.fillPath()
        if !backgroundOnly {
            for line in lines { context.textPosition = line.origin; CTLineDraw(line.value, context) }
        }
        guard let image = context.makeImage() else { return nil }
        return CIImage(cgImage: image).transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
    }

    /// Rasterize only the glyph bounds for each run/word, retaining the exact
    /// Core Text glyph positions (including fallback fonts and justification).
    func wordTiles() -> [WordTile] {
        var ranges: [NSRange] = [], offset = 0
        for word in TextLayerRenderer.scriptUnits(string) {
            let count = (word as NSString).length
            ranges.append(NSRange(location: offset, length: count)); offset += count
        }
        var tiles: [WordTile] = []
        for line in lines {
            for run in CTLineGetGlyphRuns(line.value) as! [CTRun] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = attributes[kCTFontAttributeName] as! CTFont
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                var indices = [CFIndex](repeating: 0, count: count)
                CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
                CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
                CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
                var bounds = [CGRect](repeating: .zero, count: count)
                CTFontGetBoundingRectsForGlyphs(font, .default, glyphs, &bounds, count)
                var groups: [Int: [Int]] = [:]
                for index in 0..<count {
                    if let word = ranges.firstIndex(where: { NSLocationInRange(indices[index], $0) }) {
                        groups[word, default: []].append(index)
                    }
                }
                for word in groups.keys.sorted() {
                    let members = groups[word]!
                    var rect = CGRect.null
                    for index in members where !bounds[index].isEmpty {
                        rect = rect.union(bounds[index].offsetBy(dx: positions[index].x + line.origin.x,
                                                               dy: positions[index].y + line.origin.y))
                    }
                    guard !rect.isNull else { continue }
                    rect = rect.insetBy(dx: -2, dy: -2).integral
                    guard let context = Self.context(width: max(1, Int(rect.width)), height: max(1, Int(rect.height))) else { continue }
                    let c = config.color
                    context.setFillColor(CGColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue), alpha: CGFloat(c.alpha)))
                    let selected = members.map { glyphs[$0] }
                    let local = members.map { CGPoint(x: positions[$0].x + line.origin.x - rect.minX,
                                                       y: positions[$0].y + line.origin.y - rect.minY) }
                    CTFontDrawGlyphs(font, selected, local, members.count, context)
                    if let image = context.makeImage() {
                        tiles.append(WordTile(index: word, image: CIImage(cgImage: image).transformed(by:
                            CGAffineTransform(translationX: origin.x + rect.minX, y: origin.y + rect.minY))
                            .cropped(to: CGRect(x: origin.x, y: origin.y, width: ceil(metrics.width), height: ceil(height)))))
                    }
                }
            }
        }
        return tiles
    }
    private static func context(width: Int, height: Int) -> CGContext? {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.textMatrix = .identity
        return context
    }
}

/// GPU opacity over cached word tiles. Words replaced by the next cue can
/// finish their release without replaying or rerasterizing the previous cue.
final class TextWordRenderer {
    private struct LiveTile { var life: TextWordLife; var image: CIImage }
    private struct Retiring { var image: CIImage; var start: Double; var opacity: Double; var duration: Double }
    private var geometryKey = ""
    private var geometry: TextGlyphLayout?
    private var tiles: [TextGlyphLayout.WordTile] = []
    private var current: [LiveTile] = []
    private var retiring: [Retiring] = []
    private var background: CIImage?

    func image(text: String, lives: [TextWordLife], config: TextLayerConfig, size: CGSize, now: Double) -> CIImage? {
        let envelope = TextWordEnvelope(config)
        let ids = Set(lives.map(\.id))
        if envelope.fadeOut == 0 { retiring = [] }
        if envelope.fadeOut > 0 {
            for tile in current where !ids.contains(tile.life.id) {
                let age = max(0, now - tile.life.born)
                let alpha = envelope.opacity(age: age)
                let remaining = envelope.lifetime.isFinite ? max(0, envelope.lifetime - age) : envelope.fadeOut
                let duration = min(envelope.fadeOut, remaining)
                if alpha > 0 && duration > 0 { retiring.append(Retiring(image: tile.image, start: now, opacity: alpha, duration: duration)) }
            }
        }
        let data = (try? JSONEncoder().encode(config)) ?? Data()
        let key = "\(text)|\(size)|\(data.base64EncodedString())"
        if key != geometryKey {
            geometry = TextGlyphLayout(text: text, config: config, size: size)
            tiles = geometry?.wordTiles() ?? []
            if let next = geometry?.image(backgroundOnly: true) { background = next }
            geometryKey = key
        }
        current = tiles.compactMap { tile in
            guard lives.indices.contains(tile.index) else { return nil }
            return LiveTile(life: lives[tile.index], image: tile.image)
        }
        retiring.removeAll { now - $0.start >= $0.duration }
        if retiring.count > 256 { retiring.removeFirst(retiring.count - 256) }
        var visible: [(CIImage, Double)] = current.map { ($0.image, envelope.opacity(age: now - $0.life.born)) }
        visible += retiring.map { ($0.image, $0.opacity * TextWordEnvelope.smooth(1 - (now - $0.start) / $0.duration)) }
        let alpha = visible.map(\.1).max() ?? 0
        guard alpha > 0 else { return nil }
        let canvas = CGRect(origin: .zero, size: size)
        var output = background.map { Self.opacity($0, alpha) } ?? CIImage(color: .clear).cropped(to: canvas)
        for (image, alpha) in visible where alpha > 0 { output = Self.opacity(image, alpha).composited(over: output) }
        return output.cropped(to: canvas)
    }
    private static func opacity(_ image: CIImage, _ alpha: Double) -> CIImage {
        image.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
    }
}
