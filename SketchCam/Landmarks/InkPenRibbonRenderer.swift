import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import SketchCamCore
import SketchCamShared

/// Renders the PEN strokes as crisp, vector ribbons (tldraw-style filled polygon
/// around the path) via `StrokeTessellator` + `MetalLineRenderer` (MSAA), instead
/// of stamping nibs into the watercolor dye. ALL pen strokes — committed plus the
/// one in progress — are re-tessellated every frame, so committed strokes stay
/// crisp at any zoom (re-rasterized from the path, never baked) and the live
/// stroke is just another path. The watercolor WASH still goes through the fluid
/// engine; this only handles the pen.
final class InkPenRibbonRenderer {
    private let line = MetalLineRenderer()
    private let pool = PixelBufferPool()

    /// Produce a transparent BGRA image with every pen stroke drawn as a ribbon,
    /// or nil if there is nothing to draw / on failure.
    func image(committed: [InkEditorPath], liveSample: InkLiveStrokeSample?, livePoints: [InkLiveStrokePoint],
               settings: ProcessingSettings, outputSize: CGSize, canvas: CanvasRenderContext) -> CIImage? {
        guard let line else { return nil }
        let w = max(1, Int(outputSize.width.rounded()))
        let h = max(1, Int(outputSize.height.rounded()))

        var strokes: [StrokeTessellator.Stroke] = []
        for path in committed where (path.brushMode ?? settings.landmarks.inkBrushMode ?? .pen) == .pen {
            if let s = stroke(points: path.points, times: path.sampleTimes,
                              uiSize: path.width ?? settings.landmarks.inkWidth,
                              space: path.brushSpace ?? .screen,
                              color: path.color ?? settings.landmarks.inkColor,
                              outW: w, outH: h, canvas: canvas) {
                strokes.append(s)
            }
        }
        // The in-progress pen stroke (live), rendered every frame.
        if let liveSample, liveSample.brushMode == .pen, livePoints.count > 1 {
            if let s = stroke(points: livePoints.map { $0.point }, times: livePoints.map { $0.time },
                              uiSize: liveSample.width, space: liveSample.brushSpace,
                              color: liveSample.color, outW: w, outH: h, canvas: canvas) {
                strokes.append(s)
            }
        }
        guard !strokes.isEmpty else { return nil }

        guard let buffer = try? pool.makeBuffer(format: FrameFormat(id: "pen-ribbon", width: w, height: h)),
              line.render(strokes: strokes, ribbon: true, into: buffer) else { return nil }
        return CIImage(cvPixelBuffer: buffer).cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// Build one tessellator stroke: path points → output pixels, with per-point
    /// width from the brush size (literal pixels) modulated by a smoothed speed
    /// taper for a little life.
    private func stroke(points: [CGPoint], times: [TimeInterval]?, uiSize: Float, space: CanvasBrushSpace,
                        color: RGBAColor, outW: Int, outH: Int, canvas: CanvasRenderContext) -> StrokeTessellator.Stroke? {
        guard points.count > 1 else { return nil }
        // Path points are in WORLD coordinates; map each through the camera to
        // viewport UV (same as the wash engine), then to output pixels. This is
        // what makes committed strokes re-rasterize crisp at the current zoom.
        let aspect = CGFloat(outW) / CGFloat(max(1, outH))
        let pts = points.map { p -> CGPoint in
            let uv = canvas.camera.viewportUV(fromWorldPoint: p, aspect: aspect)
            return CGPoint(x: uv.x * CGFloat(outW), y: uv.y * CGFloat(outH))
        }

        // Width in OUTPUT pixels. Screen = literal apparent pixels (zoom-independent);
        // World = world-backing pixels mapped through the camera (rescales on zoom).
        let baseWidthPx: Float
        switch space {
        case .screen:
            baseWidthPx = max(0.5, uiSize)
        case .world:
            let viewHeight = Float(max(0.000_001, canvas.camera.viewHeight))
            let worldHeight = Float(max(0.000_001, canvas.worldHeight))
            let extent = Float(max(1, canvas.worldPixelExtent))
            baseWidthPx = max(0.5, uiSize * Float(outH) * worldHeight / (viewHeight * extent))
        }

        // Per-point speed (px/sec) → gentle, smoothed width taper (fast = thinner).
        var widths = [Float](repeating: baseWidthPx, count: pts.count)
        if let times, times.count == pts.count {
            var ema: Float = 0
            for i in 1..<pts.count {
                let dt = max(Float(times[i] - times[i - 1]), 1.0 / 240.0)
                let d = Float(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
                let speed = d / dt / Float(max(1, outH))   // normalized by frame height
                ema += (speed - ema) * 0.25
                let taper = min(max(1.05 - ema * 0.6, 0.8), 1.05)
                widths[i] = baseWidthPx * taper
            }
            widths[0] = widths.count > 1 ? widths[1] : baseWidthPx
        }
        return StrokeTessellator.Stroke(points: pts, color: color, baseWidth: baseWidthPx, widths: widths)
    }
}
