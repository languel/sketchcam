import AppKit
import CoreGraphics
import Foundation
import SketchCamCore

/// LineWalk: "taking a line for a walk." One or more continuous lines planned
/// through the landmark features (`LineWalk`, Core/pure), then rendered with a
/// selectable curve fit and calligraphic variable-width stroke. Continuity = 1
/// with zero wildness reproduces the original unicursal single line.
///
/// `strokes(...)` produces the curve-fit, colored strokes; both the CPU
/// `CGContext` renderer here and the GPU `MetalLineRenderer` consume them.
struct LineWalkDrawing: DrawingAlgorithm {
    func isEnabled(_ landmarks: LandmarkSettings) -> Bool { landmarks.lineWalkEnabled }

    func render(groups: [MappedGroup], landmarks: LandmarkSettings, into context: CGContext) {
        for stroke in strokes(groups: groups, landmarks: landmarks) {
            DrawingSupport.renderStroke(stroke, bead: landmarks.beadStroke, into: context)
        }
    }

    /// The curve-fit, colored strokes this algorithm would draw. Pure data —
    /// shared by the CPU CGContext render (above) and the GPU path.
    func strokes(groups: [MappedGroup], landmarks: LandmarkSettings) -> [StrokeTessellator.Stroke] {
        let regions = LandmarkRegion.allCases
        let shapes = groups.map { group in
            LineWalk.Shape(
                points: group.points,
                edges: group.edges,
                tag: regions.firstIndex(of: group.region) ?? 0
            )
        }
        let paths = LineWalk.build(
            shapes: shapes,
            density: landmarks.lineWalkDensity,
            continuity: landmarks.lineWalkContinuity,
            wildnessAlong: landmarks.lineWalkWildnessAlong,
            wildnessOrtho: landmarks.lineWalkWildnessOrtho,
            scale: landmarks.lineWalkScale,
            seed: landmarks.lineWalkSeed
        )
        guard !paths.isEmpty else { return [] }

        let width = max(0.4, landmarks.lineWalkWidth)
        let palette = landmarks.lineWalkPalette.colors
        var result: [StrokeTessellator.Stroke] = []
        result.reserveCapacity(paths.count)
        for (pathIndex, path) in paths.enumerated() {
            guard let first = path.first else { continue }
            let color = pathColor(index: pathIndex, tag: first.tag, palette: palette, landmarks: landmarks)
            let pts = path.map(\.point)
            let seed = landmarks.lineWalkSeed &+ pathIndex &* 131
            if pts.count <= 2 {
                result.append(StrokeTessellator.Stroke(points: pts, color: color, baseWidth: width, widthVariation: landmarks.lineWalkWidthVariation, seed: seed))
            } else {
                let dense = DrawingSupport.curvePoints(pts, fit: landmarks.lineWalkCurveFit)
                result += DrawingSupport.ribbonStrokes(dense, color: color, baseWidth: CGFloat(width), widthVariation: landmarks.lineWalkWidthVariation, halo: landmarks.lineWalkHalo, seed: seed)
            }
        }
        return result
    }

    private func pathColor(index: Int, tag: Int, palette: [RGBAColor], landmarks: LandmarkSettings) -> RGBAColor {
        if landmarks.lineWalkMatchesLandmarkColors {
            let region = LandmarkRegion.allCases[safe: tag] ?? .torso
            return landmarks.style(for: region).color
        }
        guard !palette.isEmpty else { return .ink }
        return palette[index % palette.count]
    }
}
