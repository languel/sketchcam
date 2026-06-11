import AppKit
import CoreGraphics
import CoreImage
import CoreText
import Foundation
import SketchCamCore

/// Renders the landmark doodle into a transparent layer and hands it to the
/// frame processor as a cached `CIImage` for GPU compositing.
///
/// Phase 2 design (notes/performance-plan.md): the CPU vector drawing happens
/// only when a NEW detection (or a relevant settings/size change) arrives —
/// at detection cadence (~10 Hz), not frame cadence (30 Hz) — and at a capped
/// resolution. Every published frame then pays only a GPU source-over of the
/// cached layer. The yarn-branch renderer did the inverse (full-res CPU
/// redraw + GPU→CPU readback of the processed frame, every frame), which is
/// what made the overlay unaffordable.
final class LandmarkOverlayCompositor {
    /// The overlay is vector art; 720p is visually indistinguishable after
    /// GPU upscale and keeps the CPU draw ~2.25x cheaper than 1080p.
    private static let maxOverlayHeight: CGFloat = 720

    private struct CacheKey: Equatable {
        var detectionID: UInt64
        var landmarks: LandmarkSettings
        var mirror: Bool
        var outputSize: CGSize
    }

    private var cachedImage: CIImage?
    private var cachedKey: CacheKey?

    func overlay(
        detection: LandmarkDetection?,
        settings: ProcessingSettings,
        outputSize: CGSize
    ) -> CIImage? {
        guard settings.landmarks.enabled, let detection, !detection.groups.isEmpty else {
            cachedImage = nil
            cachedKey = nil
            return nil
        }

        let key = CacheKey(
            detectionID: detection.detectionID,
            landmarks: settings.landmarks,
            mirror: settings.mirror,
            outputSize: outputSize
        )
        if key == cachedKey, let cachedImage {
            return cachedImage
        }

        let image = render(detection: detection, settings: settings, outputSize: outputSize)
        cachedImage = image
        cachedKey = image == nil ? nil : key
        return image
    }

    private func render(
        detection: LandmarkDetection,
        settings: ProcessingSettings,
        outputSize: CGSize
    ) -> CIImage? {
        let scaleDown = min(1, Self.maxOverlayHeight / max(1, outputSize.height))
        let canvasSize = CGSize(
            width: (outputSize.width * scaleDown).rounded(.down),
            height: (outputSize.height * scaleDown).rounded(.down)
        )
        guard let cgContext = CGContext(
            data: nil,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else {
            return nil
        }

        cgContext.setAllowsAntialiasing(true)
        cgContext.setShouldAntialias(true)

        for group in detection.groups {
            let mapped = group.points.map {
                LandmarkCoordinateMapper.map(
                    $0.point,
                    sourceSize: detection.sourceSize,
                    outputSize: canvasSize,
                    mirrored: settings.mirror
                )
            }
            let landmarks = settings.landmarks
            let selected = LandmarkYarnWeaver.seededSubset(
                mapped,
                seed: landmarks.seed + seedOffset(for: group.region),
                ratio: landmarks.subsetRatio
            )

            switch landmarks.visualizationMode {
            case .raw:
                drawRaw(mapped, region: group.region, in: cgContext, landmarks: landmarks)
            case .yarn:
                drawYarn(selected, region: group.region, in: cgContext, landmarks: landmarks)
            case .rawAndYarn:
                drawYarn(selected, region: group.region, in: cgContext, landmarks: landmarks)
                drawRaw(mapped, region: group.region, in: cgContext, landmarks: landmarks)
            case .skeleton:
                drawSkeleton(mapped, edges: group.edges, region: group.region, in: cgContext, landmarks: landmarks)
            }

            if landmarks.showIDs {
                drawLabels(mapped, points: group.points, in: cgContext)
            }
        }

        guard let cgImage = cgContext.makeImage() else { return nil }
        let upscale = 1 / scaleDown
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: upscale, y: upscale))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    private func drawRaw(_ points: [CGPoint], region: LandmarkRegion, in context: CGContext, landmarks: LandmarkSettings) {
        let opacity = CGFloat(min(1, max(0, landmarks.rawLandmarkOpacity)))
        let color = paletteColor(for: region, alpha: 0.88 * opacity)
        context.setFillColor(color.cgColor)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.45 * opacity).cgColor)
        context.setLineWidth(0.8)
        let radius = CGFloat(max(1.6, landmarks.rawLandmarkSize))
        for point in points {
            let rect = CGRect(x: point.x - radius / 2, y: point.y - radius / 2, width: radius, height: radius)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }

    /// MediaPipe-docs-style structural rendering: connection lines (face
    /// outline, eye shapes, finger chains, body skeleton) over joint dots.
    private func drawSkeleton(_ points: [CGPoint], edges: [(Int, Int)], region: LandmarkRegion, in context: CGContext, landmarks: LandmarkSettings) {
        let width = CGFloat(max(0.7, landmarks.yarnStrokeWidth))
        let opacity = CGFloat(min(1, max(0, landmarks.yarnStrokeOpacity)))

        let path = CGMutablePath()
        for edge in edges {
            guard points.indices.contains(edge.0), points.indices.contains(edge.1) else { continue }
            path.move(to: points[edge.0])
            path.addLine(to: points[edge.1])
        }

        // dark halo under the colored bones
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.55 * opacity).cgColor)
        context.setLineWidth(width * 2.4)
        context.strokePath()
        context.addPath(path)
        context.setStrokeColor(paletteColor(for: region, alpha: opacity).cgColor)
        context.setLineWidth(width)
        context.strokePath()

        // joints
        let radius = max(2, width * 1.6)
        context.setFillColor(NSColor.white.withAlphaComponent(0.92 * opacity).cgColor)
        context.setStrokeColor(paletteColor(for: region, alpha: opacity).cgColor)
        context.setLineWidth(max(0.8, width * 0.4))
        for point in points {
            let rect = CGRect(x: point.x - radius / 2, y: point.y - radius / 2, width: radius, height: radius)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }

    private func drawLabels(_ mapped: [CGPoint], points: [LandmarkPoint], in context: CGContext) {
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2, color: NSColor.black.cgColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        for (index, point) in mapped.enumerated() {
            guard let label = points[safe: index]?.label else { continue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            context.textPosition = CGPoint(x: point.x + 4, y: point.y + 3)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    private func drawYarn(_ points: [CGPoint], region: LandmarkRegion, in context: CGContext, landmarks: LandmarkSettings) {
        guard points.count > 2 else { return }
        let ordered = LandmarkYarnWeaver.wovenOrder(points, seed: landmarks.seed + seedOffset(for: region))
        let width = CGFloat(max(0.7, landmarks.yarnStrokeWidth))
        let weave = CGFloat(landmarks.yarnWeaveAmount)
        let opacity = CGFloat(min(1, max(0, landmarks.yarnStrokeOpacity)))

        for pass in 0..<4 {
            let path = hobbyPath(points: ordered, weave: weave, pass: pass)
            let alpha = CGFloat([0.18, 0.22, 0.84, 0.46][pass]) * opacity
            let passWidth = width * CGFloat([7.5, 4.2, 1.0, 2.0][pass])
            let color: NSColor
            switch pass {
            case 0:
                color = NSColor.black.withAlphaComponent(alpha * 0.45)
            case 1:
                color = paletteColor(for: region, alpha: alpha * 0.38)
            case 2:
                color = paletteColor(for: region, alpha: alpha)
            default:
                color = NSColor.white.withAlphaComponent(alpha * 0.48)
            }
            context.addPath(path)
            context.setStrokeColor(color.cgColor)
            context.setLineWidth(passWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
    }

    private func hobbyPath(points: [CGPoint], weave: CGFloat, pass: Int) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: first)
        for segment in 0..<points.count {
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
        path.closeSubpath()
        return path
    }

    private func paletteColor(for region: LandmarkRegion, alpha: CGFloat) -> NSColor {
        switch region {
        case .face: return NSColor(calibratedRed: 0.95, green: 0.33, blue: 0.48, alpha: alpha)
        case .body: return NSColor(calibratedRed: 0.23, green: 0.78, blue: 0.64, alpha: alpha)
        case .hands: return NSColor(calibratedRed: 0.98, green: 0.78, blue: 0.28, alpha: alpha)
        case .eyes: return NSColor(calibratedRed: 0.42, green: 0.68, blue: 1.0, alpha: alpha)
        }
    }

    private func seedOffset(for region: LandmarkRegion) -> Int {
        switch region {
        case .face: return 101
        case .body: return 211
        case .hands: return 307
        case .eyes: return 409
        }
    }
}

enum LandmarkCoordinateMapper {
    /// Maps a normalized (Vision, bottom-left origin) point into output pixel
    /// space, matching the aspect-fill + mirroring the processor applies to
    /// the camera frame.
    static func map(_ point: CGPoint, sourceSize: CGSize, outputSize: CGSize, mirrored: Bool) -> CGPoint {
        let x = (mirrored ? 1 - point.x : point.x) * sourceSize.width
        let y = point.y * sourceSize.height
        let scale = max(outputSize.width / sourceSize.width, outputSize.height / sourceSize.height)
        let scaledWidth = sourceSize.width * scale
        let scaledHeight = sourceSize.height * scale
        return CGPoint(
            x: x * scale + (outputSize.width - scaledWidth) / 2,
            y: y * scale + (outputSize.height - scaledHeight) / 2
        )
    }
}

enum LandmarkYarnWeaver {
    static func seededSubset(_ points: [CGPoint], seed: Int, ratio: Float) -> [CGPoint] {
        guard points.count > 3 else { return points }
        let clamped = min(1, max(0.12, ratio))
        let target = max(4, Int(Float(points.count) * clamped))
        return points.enumerated()
            .map { (index, point) in
                (score: seededScore(index: index, seed: seed), point: point)
            }
            .sorted { $0.score < $1.score }
            .prefix(target)
            .map(\.point)
    }

    static func wovenOrder(_ points: [CGPoint], seed: Int) -> [CGPoint] {
        guard points.count > 3 else { return points }
        let centroid = center(of: points)
        let sorted = points.sorted {
            let lhsAngle = atan2($0.y - centroid.y, $0.x - centroid.x)
            let rhsAngle = atan2($1.y - centroid.y, $1.x - centroid.x)
            if lhsAngle == rhsAngle {
                return distanceSquared($0, centroid) > distanceSquared($1, centroid)
            }
            return lhsAngle < rhsAngle
        }

        let count = sorted.count
        let start = abs(seed) % count
        let step = coprimeStep(for: count, seed: seed)
        var visited = Array(repeating: false, count: count)
        var ordered: [CGPoint] = []
        var index = start

        while ordered.count < count {
            if visited[index] {
                index = nextUnvisited(after: index, visited: visited) ?? 0
            }
            visited[index] = true
            ordered.append(sorted[index])
            index = (index + step) % count
        }

        return seed.isMultiple(of: 2) ? ordered : ordered.reversed()
    }

    private static func coprimeStep(for count: Int, seed: Int) -> Int {
        guard count > 3 else { return 1 }
        let lowerBound = max(2, count / 3)
        let span = max(1, count - lowerBound - 1)
        var candidate = lowerBound + abs(seed &* 31) % span
        while greatestCommonDivisor(candidate, count) != 1 {
            candidate += 1
            if candidate >= count {
                candidate = 2
            }
        }
        return candidate
    }

    private static func nextUnvisited(after index: Int, visited: [Bool]) -> Int? {
        guard !visited.allSatisfy({ $0 }) else { return nil }
        for offset in 1...visited.count {
            let candidate = (index + offset) % visited.count
            if !visited[candidate] {
                return candidate
            }
        }
        return nil
    }

    private static func seededScore(index: Int, seed: Int) -> UInt64 {
        var value = UInt64(bitPattern: Int64(index &* 1_103_515_245 &+ seed &* 12_345))
        value ^= value >> 33
        value &*= 0xff51afd7ed558ccd
        value ^= value >> 33
        value &*= 0xc4ceb9fe1a85ec53
        value ^= value >> 33
        return value
    }

    private static func center(of points: [CGPoint]) -> CGPoint {
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private static func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var x = abs(a)
        var y = abs(b)
        while y != 0 {
            let remainder = x % y
            x = y
            y = remainder
        }
        return x
    }
}
