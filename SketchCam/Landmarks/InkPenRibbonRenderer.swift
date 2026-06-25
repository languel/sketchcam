import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import SketchCamCore
import SketchCamShared

/// Turns PEN paths into smooth tessellated ribbons (tldraw-style filled outline,
/// MSAA) and DEPOSITS them into the ink dye, so once drawn a ribbon "is ink" that
/// the wash can push around. Committed strokes deposit ONCE (then the fluid sim
/// owns that pigment); the in-progress stroke deposits its growing ribbon every
/// frame. The watercolor WASH itself still runs in the engine.
final class InkPenRibbonRenderer {
    private let line = MetalLineRenderer()
    private let pool = PixelBufferPool()

    // The live stroke accumulates across frames: the live channel only delivers
    // the points captured since the last frame (a delta), so to re-tessellate the
    // WHOLE growing stroke every frame we keep the full in-progress path here.
    private var liveID: UUID?
    private var liveAccumPoints: [CGPoint] = []
    private var liveAccumTimes: [TimeInterval] = []
    /// Committed paths already deposited into the dye (deposit once, then the
    /// wash owns the pigment — re-depositing would fight the wash's displacement).
    private var depositedIDs: Set<UUID> = []

    /// The pen-ribbon coverage images to deposit into the ink dye this frame.
    func deposits(committed: [InkEditorPath], liveSample: InkLiveStrokeSample?, livePoints: [InkLiveStrokePoint],
                  settings: ProcessingSettings, outputSize: CGSize, canvas: CanvasRenderContext) -> [MetalInkPenDeposit] {
        guard line != nil else { return [] }
        let w = max(1, Int(outputSize.width.rounded()))
        let h = max(1, Int(outputSize.height.rounded()))
        func isPen(_ p: InkEditorPath) -> Bool { (p.brushMode ?? settings.landmarks.inkBrushMode ?? .pen) == .pen }
        var result: [MetalInkPenDeposit] = []

        // Committed pen strokes: deposit each ONCE.
        for path in committed where isPen(path) && !depositedIDs.contains(path.id) {
            depositedIDs.insert(path.id)
            if let s = stroke(points: path.points, times: path.sampleTimes,
                              uiSize: path.width ?? settings.landmarks.inkWidth,
                              space: path.brushSpace ?? .screen,
                              color: path.color ?? settings.landmarks.inkColor,
                              outW: w, outH: h, canvas: canvas),
               let buf = coverageBuffer([s], w: w, h: h) {
                result.append(MetalInkPenDeposit(coverage: buf, color: path.color ?? settings.landmarks.inkColor))
            }
        }
        // Forget ids no longer present (clear / undo) so a re-added path re-deposits.
        depositedIDs.formIntersection(Set(committed.map { $0.id }))

        // In-progress pen stroke: accumulate the per-frame point deltas and deposit
        // the whole growing ribbon every frame (re-depositing at the path while
        // drawing is fine — no wash competes during a pen gesture).
        if let liveSample, liveSample.brushMode == .pen {
            if liveID != liveSample.id { liveID = liveSample.id; liveAccumPoints = []; liveAccumTimes = [] }
            // Live points arrive normalized (worldPoint / worldHeight); un-normalize
            // to world space so they map identically to committed paths.
            let wh = CGFloat(max(0.000_001, canvas.worldHeight))
            liveAccumPoints.append(contentsOf: livePoints.map { CGPoint(x: $0.point.x * wh, y: $0.point.y * wh) })
            liveAccumTimes.append(contentsOf: livePoints.map { $0.time })
            if liveAccumPoints.count > 1,
               let s = stroke(points: liveAccumPoints, times: liveAccumTimes,
                              uiSize: liveSample.width, space: liveSample.brushSpace,
                              color: liveSample.color, outW: w, outH: h, canvas: canvas),
               let buf = coverageBuffer([s], w: w, h: h) {
                result.append(MetalInkPenDeposit(coverage: buf, color: liveSample.color))
            }
        } else {
            liveID = nil
            liveAccumPoints = []
            liveAccumTimes = []
        }
        return result
    }

    /// Render strokes WHITE (coverage = alpha) into a buffer for depositing.
    private func coverageBuffer(_ strokes: [StrokeTessellator.Stroke], w: Int, h: Int) -> CVPixelBuffer? {
        guard let line else { return nil }
        let white = strokes.map { s -> StrokeTessellator.Stroke in
            var s = s
            s.color = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
            return s
        }
        // Smooth filled ribbon (miter strip + round end caps) — NOT the beaded
        // per-segment quads+discs. Coverage is white, MAX-blended into the dye, so
        // self-overlap reads as a single flat fill (no double-blend, no beading).
        guard let buffer = try? pool.makeBuffer(format: FrameFormat(id: "pen-coverage", width: w, height: h)),
              line.render(strokes: white, ribbon: true, roundCaps: true, into: buffer) else { return nil }
        return buffer
    }

    /// Build one tessellator stroke: path points → output pixels, with per-point
    /// width from the brush size (literal pixels) modulated by a smoothed speed
    /// taper for a little life.
    private func stroke(points: [CGPoint], times: [TimeInterval]?, uiSize: Float, space: CanvasBrushSpace,
                        color: RGBAColor, outW: Int, outH: Int, canvas: CanvasRenderContext) -> StrokeTessellator.Stroke? {
        guard points.count > 1 else { return nil }
        // The coverage buffer maps 1:1 onto the ink dye, which lives in NORMALIZED
        // WORLD space [0,1]² (the full world); the engine's display applies the
        // camera crop/zoom. So we deposit in that same space — NOT through the
        // camera — exactly like the wash (whose live points are worldPoint /
        // worldHeight). Camera-mapping here is what offset + rescaled the stroke.
        // Path points are WORLD coords; live points arrive pre-un-normalized to
        // world by the caller, so both divide by worldHeight here.
        let worldHeight = Float(max(0.000_001, canvas.worldHeight))
        let wh = CGFloat(worldHeight)
        let mapped = points.map { p -> CGPoint in
            // normalized world (= dye uv); flip Y for the y-up line renderer so the
            // coverage texel (uv) matches how the dye samples it.
            return CGPoint(x: (p.x / wh) * CGFloat(outW), y: (1 - p.y / wh) * CGFloat(outH))
        }
        // Smooth the polyline into a flowing curve (Catmull-Rom resample) so the
        // stroke reads as a painterly line, not angular segments between samples.
        let (pts, times) = Self.smooth(mapped, times: times, subdivisions: 8)

        // Width in COVERAGE pixels (the full-world buffer). The display's camera
        // zoom (worldHeight / viewHeight) is applied later, so to land at the
        // intended APPARENT size (matching the brush cursor ring) we pre-divide by
        // it. World = world-backing px → fraction of the world; Screen = fixed
        // apparent px, so compensate by the current zoom.
        let viewHeight = Float(max(0.000_001, canvas.camera.viewHeight))
        let extent = Float(max(1, canvas.worldPixelExtent))
        let baseWidthPx: Float
        switch space {
        case .screen:
            baseWidthPx = max(0.5, uiSize * viewHeight / worldHeight)
        case .world:
            baseWidthPx = max(0.5, uiSize * Float(outH) / extent)
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
