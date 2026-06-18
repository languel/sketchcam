import CoreGraphics
import CoreImage
import SketchCamCore

/// Retained acrylic renderer. Each node is cached independently; ordered,
/// premultiplied coats preserve opaque overpainting while the Metal wet solver
/// evolves behind the same node interface.
final class AcrylicLayerCompositor {
    private struct Entry { var config: AcrylicConfig; var size: CGSize; var image: CIImage }
    private var cache: [UUID: Entry] = [:]

    func layer(nodeID: UUID, config: AcrylicConfig, outputSize: CGSize) -> CIImage? {
        if let entry = cache[nodeID], entry.config == config, entry.size == outputSize { return entry.image }
        guard config.enabled, !config.strokes.isEmpty else { cache[nodeID] = nil; return nil }
        let width = max(1, Int(outputSize.width.rounded())), height = max(1, Int(outputSize.height.rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setLineCap(.round); context.setLineJoin(.round)
        for stroke in config.strokes where stroke.points.count > 1 {
            let alpha = min(max(stroke.loading * config.pigmentOpacity, 0), 1)
            context.setStrokeColor(red: CGFloat(stroke.color.red), green: CGFloat(stroke.color.green),
                                   blue: CGFloat(stroke.color.blue), alpha: CGFloat(alpha))
            context.setLineWidth(CGFloat(max(0.001, stroke.width)) * CGFloat(min(width, height)))
            context.beginPath()
            context.move(to: CGPoint(x: stroke.points[0].x * CGFloat(width), y: stroke.points[0].y * CGFloat(height)))
            for point in stroke.points.dropFirst() { context.addLine(to: CGPoint(x: point.x * CGFloat(width), y: point.y * CGFloat(height))) }
            context.strokePath()
        }
        guard let cg = context.makeImage() else { return nil }
        let image = CIImage(cgImage: cg)
        cache[nodeID] = Entry(config: config, size: outputSize, image: image)
        cache = cache.filter { $0.key == nodeID || $0.value.config.enabled }
        return image
    }

    func retainOnly(_ ids: Set<UUID>) { cache = cache.filter { ids.contains($0.key) } }
}
