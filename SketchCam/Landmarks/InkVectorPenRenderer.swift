import CoreGraphics
import CoreImage
import Foundation
import SketchCamCore
import SketchCamShared

/// Renders the PEN as crisp VECTOR strokes with Core Graphics (a professional,
/// resolution-independent rasterizer with proper analytic anti-aliasing — the
/// same approach tldraw/Procreate/every drawing app use). The pen is a clean
/// layer composited over the wash; it does NOT go through the watercolor fluid
/// dye (whose paper-grain + edge-enhancement roughen a crisp line) or the Metal
/// SDF (whose supersampling under-resolves thin lines).
///
/// Strokes are stored as world-space paths; each frame they're mapped through the
/// camera to output pixels and stroked. Committed strokes are cached (re-rendered
/// only when the path set / camera / size changes); the in-progress stroke is
/// rendered every frame.
final class InkVectorPenRenderer {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Cache of committed strokes (the expensive part) keyed by a content signature.
    private var cachedCommitted: CIImage?
    private var cachedSignature: Int = 0

    // The live channel delivers only the points captured since the last frame, so
    // accumulate the whole in-progress stroke here (keyed by id, reset on end).
    private var liveID: UUID?
    private var liveAccumPoints: [CGPoint] = []

    /// A transparent CIImage with all pen strokes drawn, or nil if nothing to draw.
    func image(committed: [InkEditorPath], liveSample: InkLiveStrokeSample?, livePoints: [InkLiveStrokePoint],
               settings: ProcessingSettings, outputSize: CGSize, canvas: CanvasRenderContext) -> CIImage? {
        let w = max(1, Int(outputSize.width.rounded()))
        let h = max(1, Int(outputSize.height.rounded()))
        func isPen(_ p: InkEditorPath) -> Bool { (p.brushMode ?? settings.landmarks.inkBrushMode ?? .pen) == .pen }
        let penPaths = committed.filter(isPen)

        // ---- committed strokes (cached) ----
        let sig = committedSignature(penPaths, settings: settings, canvas: canvas, w: w, h: h)
        let committedImage: CIImage?
        if sig == cachedSignature, let cachedCommitted {
            committedImage = cachedCommitted
        } else {
            committedImage = render(strokes: penPaths.compactMap { strokeSpec($0, settings: settings) },
                                    w: w, h: h, canvas: canvas)
            cachedCommitted = committedImage
            cachedSignature = sig
        }

        // ---- in-progress stroke (accumulated, rendered every frame) ----
        var liveImage: CIImage?
        if let liveSample, liveSample.brushMode == .pen {
            if liveID != liveSample.id { liveID = liveSample.id; liveAccumPoints = [] }
            let wh = CGFloat(max(0.000_001, canvas.worldHeight))
            liveAccumPoints.append(contentsOf: livePoints.map { CGPoint(x: $0.point.x * wh, y: $0.point.y * wh) })
            if liveAccumPoints.count > 1 {
                let spec = StrokeSpec(points: liveAccumPoints, uiSize: liveSample.width,
                                      space: liveSample.brushSpace, color: liveSample.color)
                liveImage = render(strokes: [spec], w: w, h: h, canvas: canvas)
            }
        } else {
            liveID = nil
            liveAccumPoints = []
        }

        switch (committedImage, liveImage) {
        case let (c?, l?): return l.composited(over: c)
        case let (c?, nil): return c
        case let (nil, l?): return l
        case (nil, nil): return nil
        }
    }

    // MARK: - Stroke spec

    private struct StrokeSpec {
        var points: [CGPoint]   // WORLD coords
        var uiSize: Float
        var space: CanvasBrushSpace
        var color: RGBAColor
    }

    private func strokeSpec(_ path: InkEditorPath, settings: ProcessingSettings) -> StrokeSpec? {
        guard path.points.count > 1 else { return nil }
        return StrokeSpec(points: path.points,
                          uiSize: path.width ?? settings.landmarks.inkWidth,
                          space: path.brushSpace ?? .screen,
                          color: path.color ?? settings.landmarks.inkColor)
    }

    // MARK: - Rendering

    private func render(strokes: [StrokeSpec], w: Int, h: Int, canvas: CanvasRenderContext) -> CIImage? {
        guard !strokes.isEmpty else { return nil }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setAllowsAntialiasing(true)
        ctx.setShouldAntialias(true)
        ctx.interpolationQuality = .high
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        let aspect = CGFloat(w) / CGFloat(max(1, h))

        for spec in strokes {
            let mapped = spec.points.map { p -> CGPoint in
                let uv = canvas.camera.viewportUV(fromWorldPoint: p, aspect: aspect)
                return CGPoint(x: uv.x * CGFloat(w), y: uv.y * CGFloat(h))
            }
            let smoothed = PenStrokeGeometry.lowPass(mapped, passes: 1)
            guard let cgPath = PenStrokeGeometry.smoothPath(smoothed) else { continue }
            let width = lineWidth(spec, outH: h, canvas: canvas)
            let c = spec.color
            ctx.setStrokeColor(red: CGFloat(c.red), green: CGFloat(c.green), blue: CGFloat(c.blue),
                               alpha: CGFloat(c.alpha))
            ctx.setLineWidth(max(0.5, width))
            ctx.addPath(cgPath)
            ctx.strokePath()
        }

        guard let cgImage = ctx.makeImage() else { return nil }
        return CIImage(cgImage: cgImage)
    }

    /// Apparent stroke diameter in OUTPUT pixels (matches the brush cursor ring).
    private func lineWidth(_ spec: StrokeSpec, outH: Int, canvas: CanvasRenderContext) -> CGFloat {
        let uiSize = CGFloat(max(0, spec.uiSize))
        switch spec.space {
        case .screen:
            return uiSize
        case .world:
            let viewHeight = max(0.000_001, canvas.camera.viewHeight)
            let worldHeight = max(0.000_001, canvas.worldHeight)
            let extent = CGFloat(max(1, canvas.worldPixelExtent))
            return uiSize * CGFloat(outH) * worldHeight / (viewHeight * extent)
        }
    }

    private func committedSignature(_ paths: [InkEditorPath], settings: ProcessingSettings,
                                    canvas: CanvasRenderContext, w: Int, h: Int) -> Int {
        var hasher = Hasher()
        hasher.combine(w); hasher.combine(h)
        hasher.combine(canvas.camera.center.x); hasher.combine(canvas.camera.center.y)
        hasher.combine(canvas.camera.viewHeight); hasher.combine(canvas.camera.rotation)
        hasher.combine(canvas.worldHeight); hasher.combine(canvas.worldPixelExtent)
        hasher.combine(settings.landmarks.inkWidth)
        for p in paths {
            hasher.combine(p.id)
            hasher.combine(p.points.count)
            if let first = p.points.first { hasher.combine(first.x); hasher.combine(first.y) }
            if let last = p.points.last { hasher.combine(last.x); hasher.combine(last.y) }
            hasher.combine(p.width ?? 0)
        }
        return hasher.finalize()
    }
}
