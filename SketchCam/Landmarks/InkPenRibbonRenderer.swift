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

    // The live stroke accumulates across frames: the live channel only delivers
    // the points captured since the last frame (a delta), so to re-tessellate the
    // WHOLE growing stroke every frame (continuous, dynamic render) we keep the
    // full in-progress path here, keyed by the live stroke id, and reset on end.
    private var liveID: UUID?
    private var liveAccumPoints: [CGPoint] = []
    private var liveAccumTimes: [TimeInterval] = []

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
        // The in-progress pen stroke: accumulate the per-frame deltas into the
        // full path and re-tessellate the WHOLE thing every frame (continuous,
        // dynamic render — not just the latest segment).
        if let liveSample, liveSample.brushMode == .pen {
            if liveID != liveSample.id {
                liveID = liveSample.id
                liveAccumPoints = []
                liveAccumTimes = []
            }
            // Live points arrive normalized (worldPoint / worldHeight, clamped),
            // but committed path points are raw WORLD coords. Un-normalize the
            // live points to world space so BOTH map identically via the camera —
            // otherwise the live stroke maps off-screen and only the committed
            // path shows (the "only drawn at the end" bug).
            let wh = CGFloat(max(0.000_001, canvas.worldHeight))
            liveAccumPoints.append(contentsOf: livePoints.map { CGPoint(x: $0.point.x * wh, y: $0.point.y * wh) })
            liveAccumTimes.append(contentsOf: livePoints.map { $0.time })
            if liveAccumPoints.count > 1,
               let s = stroke(points: liveAccumPoints, times: liveAccumTimes,
                              uiSize: liveSample.width, space: liveSample.brushSpace,
                              color: liveSample.color, outW: w, outH: h, canvas: canvas) {
                strokes.append(s)
            }
        } else {
            liveID = nil
            liveAccumPoints = []
            liveAccumTimes = []
        }
        guard !strokes.isEmpty else { return nil }

        // Ribbon strip (clean continuous edges, no per-vertex seams) + round end
        // caps, so the stroke is smooth at any size.
        guard let buffer = try? pool.makeBuffer(format: FrameFormat(id: "pen-ribbon", width: w, height: h)),
              line.render(strokes: strokes, ribbon: true, roundCaps: true, into: buffer) else { return nil }
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
        let mapped = points.map { p -> CGPoint in
            let uv = canvas.camera.viewportUV(fromWorldPoint: p, aspect: aspect)
            // World y is up; output/Metal pixel y is down → flip.
            return CGPoint(x: uv.x * CGFloat(outW), y: (1 - uv.y) * CGFloat(outH))
        }
        // Smooth the polyline into a flowing curve (Catmull-Rom resample) so the
        // stroke reads as a painterly line, not angular segments between samples.
        let (pts, times) = Self.smooth(mapped, times: times, subdivisions: 8)

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

        // Per-point speed (px/sec) → gentle, smoothed width modulation (fast =
        // thinner), like simulated pressure.
        let n = pts.count
        var widths = [Float](repeating: baseWidthPx, count: n)
        if let times, times.count == n {
            var ema: Float = 0
            for i in 1..<n {
                let dt = max(Float(times[i] - times[i - 1]), 1.0 / 240.0)
                let d = Float(hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y))
                let speed = d / dt / Float(max(1, outH))   // normalized by frame height
                ema += (speed - ema) * 0.25
                let taper = min(max(1.05 - ema * 0.6, 0.7), 1.05)
                widths[i] = baseWidthPx * taper
            }
            widths[0] = n > 1 ? widths[1] : baseWidthPx
        }
        // Painterly end taper: ease the width down toward the very start/end over
        // a short run of points (perfect-freehand style) so the stroke has soft,
        // rounded ends instead of a blunt slab.
        let taperRun = max(1, min(n / 4, 6))
        for i in 0..<n {
            let dStart = Float(i) / Float(taperRun)
            let dEnd = Float(n - 1 - i) / Float(taperRun)
            let ends = min(1, min(dStart, dEnd))
            let ease = 0.35 + 0.65 * sin(ends * .pi / 2)   // 0.35 at the tip → 1.0
            widths[i] *= ease
        }
        return StrokeTessellator.Stroke(points: pts, color: color, baseWidth: baseWidthPx, widths: widths)
    }

    /// Uniform Catmull-Rom resample: turns a sparse polyline into a smooth,
    /// densely-sampled curve through the original points. Times (if given) are
    /// linearly interpolated so the per-point speed taper still works.
    private static func smooth(_ p: [CGPoint], times: [TimeInterval]?, subdivisions: Int) -> ([CGPoint], [TimeInterval]?) {
        let n = p.count
        guard n >= 3, subdivisions >= 2 else { return (p, times) }
        let haveTimes = (times?.count == n)
        var outPts: [CGPoint] = []
        var outTimes: [TimeInterval] = []
        outPts.reserveCapacity((n - 1) * subdivisions + 1)
        func pt(_ i: Int) -> CGPoint { p[min(max(i, 0), n - 1)] }
        func tm(_ i: Int) -> TimeInterval { times![min(max(i, 0), n - 1)] }
        for i in 0..<(n - 1) {
            let p0 = pt(i - 1), p1 = pt(i), p2 = pt(i + 1), p3 = pt(i + 2)
            let steps = (i == n - 2) ? subdivisions : subdivisions - 1
            for s in 0...steps {
                let t = CGFloat(s) / CGFloat(subdivisions)
                let t2 = t * t, t3 = t2 * t
                let x = 0.5 * ((2 * p1.x) + (-p0.x + p2.x) * t + (2*p0.x - 5*p1.x + 4*p2.x - p3.x) * t2 + (-p0.x + 3*p1.x - 3*p2.x + p3.x) * t3)
                let y = 0.5 * ((2 * p1.y) + (-p0.y + p2.y) * t + (2*p0.y - 5*p1.y + 4*p2.y - p3.y) * t2 + (-p0.y + 3*p1.y - 3*p2.y + p3.y) * t3)
                outPts.append(CGPoint(x: x, y: y))
                if haveTimes { outTimes.append(tm(i) + (tm(i + 1) - tm(i)) * Double(t)) }
            }
        }
        return (outPts, haveTimes ? outTimes : nil)
    }
}
