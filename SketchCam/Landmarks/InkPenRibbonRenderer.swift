import CoreGraphics
import Foundation
import SketchCamCore
import SketchCamShared

/// Turns PEN paths into a smoothed centerline and DEPOSITS them into the ink dye
/// as a CAPSULE CHAIN (the wash's `ink_splat_capsule` — a distance-field /
/// Minkowski stroke), so once drawn a pen mark "is ink" the wash can push.
///
/// Using the same SDF primitive as the wash is what makes the pen smooth at any
/// width/zoom: a capsule union has no miter scallops, beads, or tessellation
/// artifacts. The engine resolves the radius from the brush size exactly like the
/// wash, so pen and wash share one sizing model. Committed strokes deposit ONCE
/// (then the fluid sim owns that pigment); the in-progress stroke deposits its
/// growing centerline every frame.
final class InkPenRibbonRenderer {
    // The live stroke accumulates across frames: the live channel only delivers
    // the points captured since the last frame (a delta), so we keep the full
    // in-progress path here, keyed by the live stroke id, and reset on end.
    private var liveID: UUID?
    private var liveAccumPoints: [CGPoint] = []
    /// Committed paths already deposited into the dye (deposit once, then the
    /// wash owns the pigment — re-depositing would fight its displacement).
    private var depositedIDs: Set<UUID> = []

    /// The pen capsule-chain deposits to lay into the ink dye this frame.
    func deposits(committed: [InkEditorPath], liveSample: InkLiveStrokeSample?, livePoints: [InkLiveStrokePoint],
                  settings: ProcessingSettings, outputSize: CGSize, canvas: CanvasRenderContext) -> [MetalInkPenDeposit] {
        func isPen(_ p: InkEditorPath) -> Bool { (p.brushMode ?? settings.landmarks.inkBrushMode ?? .pen) == .pen }
        let wh = CGFloat(max(0.000_001, canvas.worldHeight))
        var result: [MetalInkPenDeposit] = []

        // Committed pen strokes: deposit each ONCE.
        for path in committed where isPen(path) && !depositedIDs.contains(path.id) {
            depositedIDs.insert(path.id)
            if let pts = Self.centerline(path.points, worldHeight: wh) {
                result.append(MetalInkPenDeposit(points: pts,
                                                 uiSize: path.width ?? settings.landmarks.inkWidth,
                                                 space: path.brushSpace ?? .screen,
                                                 color: path.color ?? settings.landmarks.inkColor))
            }
        }
        // Forget ids no longer present (clear / undo) so a re-added path re-deposits.
        depositedIDs.formIntersection(Set(committed.map { $0.id }))

        // In-progress pen stroke: accumulate the per-frame point deltas and deposit
        // the whole growing centerline every frame (re-depositing while drawing is
        // fine — no wash competes during a pen gesture).
        if let liveSample, liveSample.brushMode == .pen {
            if liveID != liveSample.id { liveID = liveSample.id; liveAccumPoints = [] }
            // Live points arrive normalized (worldPoint / worldHeight); un-normalize
            // to world so they share the committed paths' coordinate space.
            liveAccumPoints.append(contentsOf: livePoints.map { CGPoint(x: $0.point.x * wh, y: $0.point.y * wh) })
            if let pts = Self.centerline(liveAccumPoints, worldHeight: wh) {
                result.append(MetalInkPenDeposit(points: pts,
                                                 uiSize: liveSample.width,
                                                 space: liveSample.brushSpace,
                                                 color: liveSample.color))
            }
        } else {
            liveID = nil
            liveAccumPoints = []
        }
        return result
    }

    /// Smooth the raw WORLD points and return the NORMALIZED-world centerline
    /// (worldPoint / worldHeight — the dye's coordinate space, same as the wash).
    private static func centerline(_ worldPoints: [CGPoint], worldHeight: CGFloat) -> [SIMD2<Float>]? {
        guard worldPoints.count > 1 else { return nil }
        // Low-pass the raw samples (removes sub-pixel jitter), then Chaikin
        // corner-cutting to round the curve. Chaikin stays INSIDE the polyline's
        // hull (no overshoot), unlike Catmull-Rom — overshoot bulges of ~the thin
        // radius are exactly what pearled the capsule chain. A single capsule per
        // segment covers its full length, so no spacing/salami either.
        let lp = lowPass(worldPoints, passes: 2)
        let pts = chaikin(lp, iterations: 2)
        let wh = worldHeight
        return pts.map { SIMD2<Float>(Float($0.x / wh), Float($0.y / wh)) }
    }

    /// Chaikin corner-cutting: replace each segment with points at 1/4 and 3/4,
    /// keeping the endpoints. Non-overshooting → no bulges around a thin stroke.
    private static func chaikin(_ p: [CGPoint], iterations: Int) -> [CGPoint] {
        guard p.count > 2, iterations > 0 else { return p }
        var pts = p
        for _ in 0..<iterations {
            var next: [CGPoint] = [pts[0]]
            next.reserveCapacity(pts.count * 2)
            for i in 0..<(pts.count - 1) {
                let a = pts[i], b = pts[i + 1]
                next.append(CGPoint(x: a.x * 0.75 + b.x * 0.25, y: a.y * 0.75 + b.y * 0.25))
                next.append(CGPoint(x: a.x * 0.25 + b.x * 0.75, y: a.y * 0.25 + b.y * 0.75))
            }
            next.append(pts[pts.count - 1])
            pts = next
        }
        return pts
    }

    /// Iterated binomial [0.25, 0.5, 0.25] low-pass that removes sub-pixel jitter
    /// from raw input samples (endpoints fixed).
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

}
