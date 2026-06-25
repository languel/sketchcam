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
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

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
        // Render coverage at the DYE resolution so the deposit into the dye is 1:1
        // (no downsample → no bead-chain aliasing on thin strokes).
        let dye = MetalInkEngine.dyePixelSize(forOutput: outputSize)
        let w = max(1, Int(dye.width.rounded()))
        let h = max(1, Int(dye.height.rounded()))
        let outH = max(1, Int(outputSize.height.rounded()))
        func isPen(_ p: InkEditorPath) -> Bool { (p.brushMode ?? settings.landmarks.inkBrushMode ?? .pen) == .pen }
        var result: [MetalInkPenDeposit] = []

        // Committed pen strokes: deposit each ONCE.
        for path in committed where isPen(path) && !depositedIDs.contains(path.id) {
            depositedIDs.insert(path.id)
            if let s = stroke(points: path.points, times: path.sampleTimes,
                              uiSize: path.width ?? settings.landmarks.inkWidth,
                              space: path.brushSpace ?? .screen,
                              color: path.color ?? settings.landmarks.inkColor,
                              bufW: w, bufH: h, outH: outH, canvas: canvas),
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
                              color: liveSample.color, bufW: w, bufH: h, outH: outH, canvas: canvas),
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

    /// 2× supersample so a ~1px dye line gets real anti-aliasing; the deposit's
    /// linear sample then box-downsamples it to dye res cleanly.
    private static let superSample = 2

    /// Render strokes WHITE (coverage = alpha) into a SUPERSAMPLED buffer and
    /// lightly feather it. The deposit samples this by uv, downsampling to dye res.
    private func coverageBuffer(_ strokes: [StrokeTessellator.Stroke], w: Int, h: Int) -> CVPixelBuffer? {
        guard let line else { return nil }
        let ss = Self.superSample
        let sw = w * ss, sh = h * ss
        let f = Float(ss)
        // White, scaled into the supersampled buffer (points + widths × ss).
        let white = strokes.map { s -> StrokeTessellator.Stroke in
            var s = s
            s.color = RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
            s.points = s.points.map { CGPoint(x: $0.x * CGFloat(ss), y: $0.y * CGFloat(ss)) }
            s.widths = s.widths?.map { $0 * f }
            s.baseWidth *= f
            return s
        }
        // Smooth filled ribbon (miter strip + round end caps), rendered hard at ss res.
        guard let hard = try? pool.makeBuffer(format: FrameFormat(id: "pen-coverage-hard", width: sw, height: sh)),
              line.render(strokes: white, ribbon: true, roundCaps: true, into: hard) else { return nil }
        // FEATHER lightly (the watercolor display edge-enhances density gradients;
        // a hard thin ink line would read as a "pixelated caterpillar"). Sigma is in
        // ss-pixels → ~0.6 dye px, just enough to soften the per-texel gradient.
        guard let soft = try? pool.makeBuffer(format: FrameFormat(id: "pen-coverage", width: sw, height: sh)) else { return hard }
        let rect = CGRect(x: 0, y: 0, width: sw, height: sh)
        let blurred = CIImage(cvPixelBuffer: hard)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: Double(ss) * 0.9)
            .cropped(to: rect)
        ciContext.render(blurred, to: soft)
        return soft
    }

    /// Build one tessellator stroke: path points → output pixels, with per-point
    /// width from the brush size (literal pixels) modulated by a smoothed speed
    /// taper for a little life.
    private func stroke(points: [CGPoint], times: [TimeInterval]?, uiSize: Float, space: CanvasBrushSpace,
                        color: RGBAColor, bufW: Int, bufH: Int, outH: Int, canvas: CanvasRenderContext) -> StrokeTessellator.Stroke? {
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
            return CGPoint(x: (p.x / wh) * CGFloat(bufW), y: (1 - p.y / wh) * CGFloat(bufH))
        }
        // Low-pass the centerline FIRST. Raw drag samples carry ~sub-pixel jitter;
        // a thin ribbon (~1px) around a jittery path serrates because the jitter
        // amplitude ≈ the half-width (it's swamped only at large widths). A few
        // binomial [0.25,0.5,0.25] passes remove the jitter so the thin ribbon is
        // a clean line, then Catmull-Rom resamples it into a flowing curve.
        let lp = Self.lowPass(mapped, passes: 3)
        let (smoothPts, _) = Self.smooth(lp, times: times, subdivisions: 8)

        // Width: first the intended APPARENT diameter in OUTPUT pixels (identical
        // to the brush cursor ring), then convert to dye-buffer pixels. The display
        // magnifies the buffer by outH·worldHeight/(viewHeight·bufH), so divide by
        // that = multiply by (bufH/outH)·viewHeight/worldHeight.
        let viewHeight = Float(max(0.000_001, canvas.camera.viewHeight))
        let extent = Float(max(1, canvas.worldPixelExtent))
        let apparentOutPx: Float
        switch space {
        case .screen:
            apparentOutPx = uiSize
        case .world:
            apparentOutPx = uiSize * Float(outH) * worldHeight / (viewHeight * extent)
        }
        let dyeScale = Float(bufH) / Float(max(1, outH))
        // Floor at ~1 dye px (a true hairline). The coverage is supersampled +
        // lightly feathered (see coverageBuffer) so even a 1px line stays smooth
        // instead of aliasing into a dashed core.
        let baseWidthPx = max(1, apparentOutPx * dyeScale * viewHeight / worldHeight)

        // Keep the DENSE smoothed centerline: at dense spacing the angle between
        // consecutive segments is tiny (cosA≈1), so the miter offset never bumps
        // the width — no per-vertex bead-chain. (Decimating to sparse points made
        // each vertex a visible miter bump.) Thin-line aliasing is handled by the
        // supersample + feather in coverageBuffer, not by point spacing.
        let pts = smoothPts
        guard pts.count > 1 else { return nil }

        // CONSTANT width along the body. (A per-point speed→width taper was keyed
        // to the Catmull-Rom resampled points, whose spacing is non-uniform — the
        // curve slows at each original sample — so the width oscillated once per
        // segment and pinched a thin ribbon into a regular bead-chain. A uniform
        // width keeps the thin ribbon continuous; the wash adds organic variation.)
        let n = pts.count
        var widths = [Float](repeating: baseWidthPx, count: n)
        // Painterly end taper only: ease the width down toward the very start/end
        // over a short run of points so the stroke has soft, rounded ends. This is
        // monotonic at the ends (no mid-stroke oscillation → no beading).
        let taperRun = max(1, min(n / 4, 6))
        for i in 0..<n {
            let dStart = Float(i) / Float(taperRun)
            let dEnd = Float(n - 1 - i) / Float(taperRun)
            let ends = min(1, min(dStart, dEnd))
            let ease = 0.55 + 0.45 * sin(ends * .pi / 2)   // 0.55 at the tip → 1.0
            widths[i] *= ease
        }
        return StrokeTessellator.Stroke(points: pts, color: color, baseWidth: baseWidthPx, widths: widths)
    }

    /// Iterated binomial [0.25, 0.5, 0.25] low-pass that removes sub-pixel jitter
    /// from raw input samples (endpoints fixed). Keeps a thin ribbon from
    /// serrating without rounding the stroke's overall shape.
    private static func lowPass(_ p: [CGPoint], passes: Int) -> [CGPoint] {
        guard p.count > 2, passes > 0 else { return p }
        var pts = p
        for _ in 0..<passes {
            var next = pts
            for i in 1..<(pts.count - 1) {
                next[i] = CGPoint(x: pts[i - 1].x * 0.25 + pts[i].x * 0.5 + pts[i + 1].x * 0.25,
                                  y: pts[i - 1].y * 0.25 + pts[i].y * 0.5 + pts[i + 1].y * 0.25)
            }
            pts = next
        }
        return pts
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
