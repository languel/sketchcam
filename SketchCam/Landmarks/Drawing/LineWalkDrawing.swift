import AppKit
import CoreGraphics
import Foundation
import SketchCamCore

/// LineWalk: "taking a line for a walk." One or more continuous lines planned
/// through the landmark features (`LineWalk`, Core/pure), then rendered with a
/// selectable curve fit and calligraphic variable-width stroke. Continuity = 1
/// with zero wildness reproduces the original unicursal single line.
struct LineWalkDrawing: DrawingAlgorithm {
    let style: DrawingStyle = .lineWalk

    func render(groups: [MappedGroup], landmarks: LandmarkSettings, into context: CGContext) {
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
            seed: landmarks.seed
        )
        guard !paths.isEmpty else { return }

        let width = CGFloat(max(0.4, landmarks.lineWalkWidth))
        let palette = landmarks.drawingPalette.colors

        for (pathIndex, path) in paths.enumerated() {
            guard let first = path.first else { continue }
            let color = DrawingSupport.nsColor(pathColor(index: pathIndex, tag: first.tag, palette: palette, landmarks: landmarks))
            let pts = path.map(\.point)

            // Single-point paths (dropped/fragmented to a dot) render as a dot.
            if pts.count == 1 {
                context.setFillColor(color.cgColor)
                let r = width
                context.fillEllipse(in: CGRect(x: pts[0].x - r / 2, y: pts[0].y - r / 2, width: r, height: r))
                continue
            }

            let dense = DrawingSupport.curvePoints(pts, fit: landmarks.lineWalkCurveFit)
            DrawingSupport.strokeVariableWidth(
                dense,
                baseWidth: width,
                variation: landmarks.lineWalkWidthVariation,
                color: color,
                seed: landmarks.seed &+ pathIndex &* 131,
                into: context
            )
        }
    }

    private func pathColor(index: Int, tag: Int, palette: [RGBAColor], landmarks: LandmarkSettings) -> RGBAColor {
        if landmarks.drawingMatchesLandmarkColors {
            let region = LandmarkRegion.allCases[safe: tag] ?? .torso
            return landmarks.style(for: region).color
        }
        guard !palette.isEmpty else { return .ink }
        return palette[index % palette.count]
    }
}
