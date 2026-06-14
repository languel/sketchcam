import AppKit
import CoreGraphics
import Foundation
import SketchCamCore

/// One landmark region's points already mapped into overlay-canvas pixel space,
/// with its structural edges. Drawing algorithms consume these; the compositor
/// owns the mapping.
struct MappedGroup {
    let region: LandmarkRegion
    let points: [CGPoint]
    let edges: [(Int, Int)]
}

/// A self-contained art algorithm for the Drawing tab. Each algorithm is an
/// independent module; algorithms toggle independently and the compositor
/// layers every enabled one (back-to-front) per frame.
///
/// Add a new algorithm by conforming a new type and registering it in
/// `LandmarkOverlayCompositor.algorithms` — no other code changes required.
protocol DrawingAlgorithm {
    /// Whether this algorithm should draw this frame.
    func isEnabled(_ landmarks: LandmarkSettings) -> Bool

    /// Draws into the (already-cleared, canvas-space) context using every
    /// region's mapped landmarks.
    func render(groups: [MappedGroup], landmarks: LandmarkSettings, into context: CGContext)

    /// GPU path: the same drawing expressed as tessellatable strokes (canvas
    /// space). The compositor gathers these from every enabled algorithm and
    /// rasterizes them in one Metal pass. Default `[]` = CPU-only.
    func strokes(groups: [MappedGroup], landmarks: LandmarkSettings) -> [StrokeTessellator.Stroke]
}

extension DrawingAlgorithm {
    func strokes(groups: [MappedGroup], landmarks: LandmarkSettings) -> [StrokeTessellator.Stroke] { [] }
}

/// Drawing primitives shared by the algorithm modules (and the Marks renderers
/// in the compositor): color conversion, the smooth "hobby" path, palette/match
/// stroke resolution, and per-region PRNG offsets.
enum DrawingSupport {
    static func nsColor(_ color: RGBAColor, alpha: CGFloat? = nil, alphaScale: CGFloat = 1) -> NSColor {
        NSColor(
            calibratedRed: CGFloat(color.red),
            green: CGFloat(color.green),
            blue: CGFloat(color.blue),
            alpha: alpha ?? min(1, CGFloat(color.alpha) * alphaScale)
        )
    }

    /// Resolves a drawing stroke: per-region landmark style when "match
    /// landmark colors" is set, otherwise the shared palette's primary color
    /// with the algorithm's own width.
    static func stroke(for region: LandmarkRegion, landmarks: LandmarkSettings, matchColors: Bool, palette: DrawingPalette, width: Float) -> (color: RGBAColor, width: CGFloat) {
        if matchColors {
            let style = landmarks.style(for: region)
            return (style.color, CGFloat(max(0.7, style.size)))
        }
        return (palette.primary, CGFloat(max(0.7, width)))
    }

    /// Smooth Catmull-style path through `points`. Closed paths curve through
    /// the wrap segment; open paths stop at the last vertex. `weave` bends each
    /// segment along its normal (yarn); 0 = clean curve (unicursal).
    static func hobbyPath(points: [CGPoint], weave: CGFloat, pass: Int, closed: Bool = true) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        let segmentCount = closed ? points.count : points.count - 1
        for segment in 0..<max(0, segmentCount) {
            let previous = points[segment]
            let current = points[(segment + 1) % points.count]
            let dx = current.x - previous.x
            let dy = current.y - previous.y
            let distance = max(1, hypot(dx, dy))
            let normal = CGPoint(x: -dy / distance, y: dx / distance)
            let wave = sin(CGFloat(segment + pass) * 1.618) * distance * 0.18 * weave
            let c1 = CGPoint(x: previous.x + dx * 0.42 + normal.x * wave, y: previous.y + dy * 0.42 + normal.y * wave)
            let c2 = CGPoint(x: previous.x + dx * 0.68 - normal.x * wave, y: previous.y + dy * 0.68 - normal.y * wave)
            path.addCurve(to: current, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
        return path
    }

    /// Per-region PRNG offset so each region weaves/varies independently.
    static func seedOffset(for region: LandmarkRegion) -> Int {
        switch region {
        case .jaw: return 101
        case .nose: return 103
        case .mouth: return 107
        case .leftBrow: return 109
        case .rightBrow: return 113
        case .leftEye: return 127
        case .rightEye: return 131
        case .head: return 211
        case .torso: return 223
        case .leftArm: return 227
        case .rightArm: return 229
        case .leftLeg: return 233
        case .rightLeg: return 239
        case .hands: return 307
        case .contour: return 503
        case .bodyHull: return 521
        }
    }

    // MARK: - Curve fitting

    /// Densely samples a polyline through `points` per the chosen `CurveFit`,
    /// returning a flattened polyline (so a variable-width stroker can follow
    /// the curve). Shared by all drawing algorithms.
    static func curvePoints(_ points: [CGPoint], fit: CurveFit, samplesPerSegment: Int = 8) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        switch fit {
        case .polyline:
            return points
        case .catmull:
            return cardinal(points, tension: 0, samples: samplesPerSegment)
        case .hobby:
            // True Hobby spline is involved; a looser cardinal spline gives the
            // rounder, "taut and pleasing" feel as a stand-in for now.
            return cardinal(points, tension: -0.25, samples: samplesPerSegment)
        case .bezier:
            return quadMidpoint(points, samples: samplesPerSegment)
        }
    }

    /// Cardinal (Catmull-Rom family) spline sampled to points. `tension` 0 =
    /// Catmull-Rom; negative = looser/rounder; positive = tighter toward the
    /// polyline.
    private static func cardinal(_ pts: [CGPoint], tension: CGFloat, samples: Int) -> [CGPoint] {
        let n = pts.count
        var out: [CGPoint] = []
        let scale = (1 - tension) * 0.5
        for i in 0..<(n - 1) {
            let p0 = pts[max(0, i - 1)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(n - 1, i + 2)]
            let m1 = CGPoint(x: (p2.x - p0.x) * scale, y: (p2.y - p0.y) * scale)
            let m2 = CGPoint(x: (p3.x - p1.x) * scale, y: (p3.y - p1.y) * scale)
            for s in 0..<samples {
                let t = CGFloat(s) / CGFloat(samples)
                let t2 = t * t, t3 = t2 * t
                let h00 = 2 * t3 - 3 * t2 + 1
                let h10 = t3 - 2 * t2 + t
                let h01 = -2 * t3 + 3 * t2
                let h11 = t3 - t2
                out.append(CGPoint(
                    x: h00 * p1.x + h10 * m1.x + h01 * p2.x + h11 * m2.x,
                    y: h00 * p1.y + h10 * m1.y + h01 * p2.y + h11 * m2.y
                ))
            }
        }
        out.append(pts[n - 1])
        return out
    }

    /// Quadratic corner-cutting: passes near each point through midpoints —
    /// softer than a polyline, looser than a spline.
    private static func quadMidpoint(_ pts: [CGPoint], samples: Int) -> [CGPoint] {
        let n = pts.count
        var out: [CGPoint] = [pts[0]]
        for i in 1..<(n - 1) {
            let start = i == 1 ? pts[0] : midpoint(pts[i - 1], pts[i])
            let end = midpoint(pts[i], pts[i + 1])
            let ctrl = pts[i]
            for s in 1...samples {
                let t = CGFloat(s) / CGFloat(samples)
                let mt = 1 - t
                out.append(CGPoint(
                    x: mt * mt * start.x + 2 * mt * t * ctrl.x + t * t * end.x,
                    y: mt * mt * start.y + 2 * mt * t * ctrl.y + t * t * end.y
                ))
            }
        }
        out.append(pts[n - 1])
        return out
    }

    private static func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Strokes a polyline with width that varies along its length: an end-taper
    /// times a seeded-noise swell (calligraphic). `variation` 0 = constant
    /// width (single cheap stroke). Round caps blend the sub-segments.
    static func strokeVariableWidth(
        _ pts: [CGPoint],
        baseWidth: CGFloat,
        variation: Float,
        color: NSColor,
        seed: Int,
        into context: CGContext
    ) {
        guard pts.count >= 2 else { return }
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(color.cgColor)

        if variation <= 0.001 {
            let path = CGMutablePath()
            path.addLines(between: pts)
            context.addPath(path)
            context.setLineWidth(baseWidth)
            context.strokePath()
            return
        }

        let n = pts.count
        for i in 0..<(n - 1) {
            let t = Double(i) / Double(max(1, n - 1))
            let taper = 0.55 + 0.45 * sin(.pi * t)              // thinner at ends
            let swell = 1 + Double(variation) * LineWalk.valueNoise1D(Double(i) * 0.25, seed, 7)
            let w = max(0.2, baseWidth * CGFloat(taper * max(0.1, swell)))
            context.setLineWidth(w)
            context.move(to: pts[i])
            context.addLine(to: pts[i + 1])
            context.strokePath()
        }
    }

    /// A variable-width **ribbon** (calligraphic taper/swell, like LineWalk) as
    /// GPU strokes, with an optional glow **halo** (wide dark underlay + soft
    /// color + white highlight). Shared by every algorithm's GPU path.
    static func ribbonStrokes(_ points: [CGPoint], color: RGBAColor, baseWidth: CGFloat, widthVariation: Float, halo: Bool, seed: Int) -> [StrokeTessellator.Stroke] {
        guard points.count >= 2 else { return [] }
        let w = Float(baseWidth)
        let opacity = Float(min(1, max(0, color.alpha)))
        var out: [StrokeTessellator.Stroke] = []
        if halo {
            var dark = RGBAColor.black; dark.alpha = 0.16 * opacity
            out.append(.init(points: points, color: dark, baseWidth: w * 4.5, widthVariation: widthVariation, seed: seed))
            var soft = color; soft.alpha = 0.28 * opacity
            out.append(.init(points: points, color: soft, baseWidth: w * 2.3, widthVariation: widthVariation, seed: seed))
        }
        out.append(.init(points: points, color: color, baseWidth: w, widthVariation: widthVariation, seed: seed))
        if halo {
            var hi = RGBAColor.white; hi.alpha = 0.5 * opacity
            out.append(.init(points: points, color: hi, baseWidth: w * 0.4, widthVariation: widthVariation, seed: seed))
        }
        return out
    }

    /// CPU render of a single tessellatable stroke — the same `Stroke` the GPU
    /// path consumes — as either a filled ribbon (default, clean under alpha) or
    /// the legacy bead stroke. Both paths share `StrokeTessellator.ribbonBoundary`.
    static func renderStroke(_ stroke: StrokeTessellator.Stroke, bead: Bool, into context: CGContext) {
        let pts = stroke.points
        guard !pts.isEmpty else { return }
        let color = nsColor(stroke.color)
        if pts.count == 1 {
            let r = CGFloat(max(0.4, stroke.baseWidth))
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: pts[0].x - r / 2, y: pts[0].y - r / 2, width: r, height: r))
            return
        }
        if bead {
            strokeVariableWidth(pts, baseWidth: CGFloat(stroke.baseWidth), variation: stroke.widthVariation, color: color, seed: stroke.seed, into: context)
            return
        }
        let (left, right) = StrokeTessellator.ribbonBoundary(stroke)
        guard left.count >= 2 else { return }
        let path = CGMutablePath()
        path.move(to: left[0])
        for p in left.dropFirst() { path.addLine(to: p) }
        for p in right.reversed() { path.addLine(to: p) }
        path.closeSubpath()
        context.addPath(path)
        context.setFillColor(color.cgColor)
        context.fillPath()
    }
}
