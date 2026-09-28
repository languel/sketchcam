import AppKit
import CoreGraphics
import CoreImage
import CoreVideo
import SketchCamCore

/// A small camera thumbnail supplies region colors; flat vector polygons do
/// the painting. No person matte or full-frame pixel readback is involved.
struct PortraitColorField {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    static func capture(_ frame: CVPixelBuffer, canvasSize: CGSize,
                        mirrored: Bool, context: CIContext) -> PortraitColorField? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let width = 128
        let height = max(1, Int((CGFloat(width) * canvasSize.height / canvasSize.width).rounded()))
        let output = CGRect(origin: .zero, size: canvasSize)
        let source = CoreImageFrameProcessor.aspectFill(CIImage(cvPixelBuffer: frame),
                                                        in: output, mirrored: mirrored)
        let thumbnail = source.transformed(by: CGAffineTransform(
            scaleX: CGFloat(width) / canvasSize.width,
            y: CGFloat(height) / canvasSize.height
        ))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            context.render(thumbnail, toBitmap: base, rowBytes: width * 4,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        }
        return PortraitColorField(width: width, height: height, pixels: pixels)
    }

    func sample(at point: CGPoint, canvasSize: CGSize) -> RGBAColor {
        guard width > 0, height > 0, canvasSize.width > 0, canvasSize.height > 0 else { return .white }
        let x = max(0, min(width - 1, Int(point.x / canvasSize.width * CGFloat(width))))
        let y = max(0, min(height - 1, Int(point.y / canvasSize.height * CGFloat(height))))
        var red = 0, green = 0, blue = 0, samples = 0
        for row in max(0, y - 1)...min(height - 1, y + 1) {
            for column in max(0, x - 1)...min(width - 1, x + 1) {
                let offset = (row * width + column) * 4
                red += Int(pixels[offset])
                green += Int(pixels[offset + 1])
                blue += Int(pixels[offset + 2])
                samples += 1
            }
        }
        return RGBAColor(red: Float(red) / Float(samples * 255),
                         green: Float(green) / Float(samples * 255),
                         blue: Float(blue) / Float(samples * 255))
    }
}

enum PortraitFillRenderer {
    static let printPalette: [RGBAColor] = [
        RGBAColor(red: 0.96, green: 0.91, blue: 0.81),
        RGBAColor(red: 0.17, green: 0.17, blue: 0.19),
        RGBAColor(red: 0.95, green: 0.68, blue: 0.57),
        RGBAColor(red: 0.72, green: 0.57, blue: 0.20),
        RGBAColor(red: 0.50, green: 0.70, blue: 0.83),
        RGBAColor(red: 0.92, green: 0.22, blue: 0.15),
        RGBAColor(red: 0.40, green: 0.63, blue: 0.27),
        RGBAColor(red: 0.70, green: 0.55, blue: 0.72),
        RGBAColor(red: 0.64, green: 0.31, blue: 0.22),
        RGBAColor(red: 0.28, green: 0.72, blue: 0.72),
        RGBAColor(red: 0.94, green: 0.46, blue: 0.66),
        RGBAColor(red: 0.18, green: 0.28, blue: 0.46)
    ]

    enum Part: Int {
        case body, neck, face, hair, hand
    }

    struct Shape {
        let part: Part
        let points: [CGPoint]
        let colorSample: CGPoint
        let colorSlot: Int
    }

    static func shapes(groups: [MappedGroup], settings: LandmarkSettings) -> [Shape] {
        if settings.resolvedPortraitApproach == .aaron {
            let geometry = AaronPortrait.geometry(groups: groups, settings: settings)
            let curves = geometry.paths
            guard curves.count >= 2, curves[1].count >= 4 else { return [] }
            let faceSample = groups.first(where: { $0.region == .nose })?.points.first
                ?? curves[1][curves[1].count / 2]
            var painted: [Shape] = []
            if settings.resolvedPortraitOutlineEnabled && settings.resolvedPortraitBodyEnabled {
                let bodySample = groups.first(where: { $0.region == .torso })?.points.last
                    ?? curves[0][curves[0].count / 2]
                if settings.resolvedPortraitPoseBodyEnabled,
               let rig = PortraitPathBuilder.poseBodyComponent(
                   from: groups, scalp: nil, seed: settings.resolvedPortraitSeed &+ 113
               ), let torso = rig.torsoFill {
                    painted.append(Shape(part: .body, points: BodyHull.convexHull(torso),
                                         colorSample: bodySample, colorSlot: 0))
                    painted += rig.sleeveFills.map {
                        Shape(part: .body, points: $0, colorSample: bodySample, colorSlot: 0)
                    }
                    if let neck = rig.neckFill {
                        painted.append(Shape(part: .neck, points: neck,
                                             colorSample: faceSample, colorSlot: 1))
                    }
                } else if curves[0].count >= 4 {
                    painted.append(Shape(part: .body, points: curves[0],
                                         colorSample: bodySample, colorSlot: 0))
                }
            }
            painted.append(Shape(part: .face, points: curves[1],
                                 colorSample: faceSample, colorSlot: 1))
            if let hair = geometry.hair, let outer = hair.hairFillOutline {
                let roof = Array(hair.points.prefix(17))
                if let first = roof.first, let last = roof.last, roof.count > 1 {
                    let under = roof.enumerated().map { index, point in
                        let t = CGFloat(index) / CGFloat(roof.count - 1)
                        let base = CGPoint(x: first.x + (last.x - first.x) * t,
                                           y: first.y + (last.y - first.y) * t)
                        return CGPoint(x: base.x + (point.x - base.x) * 0.46,
                                       y: base.y + (point.y - base.y) * 0.46)
                    }
                    painted.append(Shape(part: .hair, points: outer + under.reversed(),
                                         colorSample: roof[roof.count / 2], colorSlot: 2))
                    painted += hair.hairSideFills.map {
                        Shape(part: .hair, points: $0,
                              colorSample: roof[roof.count / 2], colorSlot: 2)
                    }
                }
            }
            for hand in groups where hand.region == .hands {
                guard let contour = PortraitPathBuilder.fingerContourComponent(
                    from: hand, fullness: settings.resolvedPortraitFingerFullness
                ) else { continue }
                let slot = hand.labels.contains("L0") ? 3 : hand.labels.contains("R0") ? 4 : 5
                let palm = zip(hand.labels, hand.points).first {
                    $0.0 == "L0" || $0.0 == "R0" || $0.0 == "E0"
                }?.1 ?? contour.points[0]
                painted.append(Shape(part: .hand, points: contour.points,
                                     colorSample: palm, colorSlot: slot))
            }
            return painted
        }
        guard let jaw = groups.first(where: { $0.region == .jaw && $0.points.count >= 3 }) else { return [] }
        let crown = PortraitPathBuilder.hairComponent(
            from: groups, style: .clean, amount: 0,
            seed: settings.resolvedPortraitSeed &+ 71,
            expansion: settings.resolvedPortraitHairExpansion,
            hairdo: settings.resolvedPortraitHairdo
        )
        guard let roof = crown?.points, roof.count >= 3 else { return [] }
        var shapes: [Shape] = []
        let faceCenter = groups.first(where: { $0.region == .nose })?.points.first
            ?? jaw.points[jaw.points.count / 2]

        if settings.resolvedPortraitOutlineEnabled && settings.resolvedPortraitPoseBodyEnabled
            && (settings.resolvedPortraitApproach == .landmarks || settings.resolvedPortraitBodyEnabled),
           let body = PortraitPathBuilder.poseBodyComponent(
               from: groups, scalp: crown, seed: settings.resolvedPortraitSeed &+ 113
           ), let torsoFill = body.torsoFill, torsoFill.count >= 4 {
            let torsoCenter = groups.first(where: { $0.region == .torso })?.points.last
                ?? torsoFill[torsoFill.count / 2]
            shapes.append(Shape(part: .body,
                                points: BodyHull.convexHull(torsoFill),
                                colorSample: torsoCenter, colorSlot: 0))
            for sleeve in body.sleeveFills {
                shapes.append(Shape(part: .body, points: sleeve,
                                    colorSample: torsoCenter, colorSlot: 0))
            }
            // A neck wedge uses the same tracked color as the face. The
            // shoulders can fall below the camera crop, but the bridge from
            // jaw to shirt must never turn into a transparent hole.
            shapes.append(Shape(part: .neck,
                                points: body.neckFill ?? [],
                                colorSample: faceCenter, colorSlot: 1))
        }

        shapes.append(Shape(part: .face,
                            points: BodyHull.convexHull(roof + jaw.points),
                            colorSample: faceCenter, colorSlot: 1))
        if settings.resolvedPortraitHairEnabled, let first = roof.first, let last = roof.last {
            let count = roof.count - 1
            let outer = crown?.hairFillOutline ?? roof
            let under = roof.enumerated().map { index, point -> CGPoint in
                let t = CGFloat(index) / CGFloat(count)
                let baseline = CGPoint(x: first.x + (last.x - first.x) * t,
                                       y: first.y + (last.y - first.y) * t)
                return CGPoint(x: baseline.x + (point.x - baseline.x) * 0.46,
                               y: baseline.y + (point.y - baseline.y) * 0.46)
            }
            let sample = roof[roof.count / 2]
            shapes.append(Shape(part: .hair, points: outer + Array(under.reversed()),
                                colorSample: sample, colorSlot: 2))
            shapes += (crown?.hairSideFills ?? []).map {
                Shape(part: .hair, points: $0, colorSample: sample, colorSlot: 2)
            }
        }

        for hand in groups where hand.region == .hands {
            guard let contour = PortraitPathBuilder.fingerContourComponent(
                from: hand, fullness: settings.resolvedPortraitFingerFullness
            ), contour.points.count >= 12 else { continue }
            let palm = zip(hand.labels, hand.points).first { $0.0 == "L0" || $0.0 == "R0" || $0.0 == "E0" }?.1
                ?? contour.points[0]
            let slot = hand.labels.contains("L0") ? 3 : hand.labels.contains("R0") ? 4 : 5
            shapes.append(Shape(part: .hand, points: contour.points,
                                colorSample: palm, colorSlot: slot))
        }
        return shapes
    }

    static func paint(_ shapes: [Shape], field: PortraitColorField?,
                      canvasSize: CGSize, settings: LandmarkSettings,
                      colorTracker: PortraitFillColorTracker? = nil,
                      into context: CGContext) {
        for shape in shapes where shape.points.count >= 3 {
            let camera = field?.sample(at: shape.colorSample, canvasSize: canvasSize)
                ?? fallbackColor(for: shape.part)
            let seed = settings.resolvedPortraitSeed &+ shape.colorSlot &* 101
            let color = colorTracker?.color(camera: camera, part: shape.part,
                                            slot: shape.colorSlot, settings: settings, seed: seed)
                ?? paintColor(camera: camera, part: shape.part, settings: settings, seed: seed)
            context.setFillColor(DrawingSupport.nsColor(color).cgColor)
            context.beginPath()
            context.addLines(between: shape.points)
            context.closePath()
            context.fillPath()
        }
    }

    static func paintColor(camera: RGBAColor, part: Part,
                           settings: LandmarkSettings, seed: Int) -> RGBAColor {
        let variation = settings.resolvedPortraitFillVariation
        let accent = fallbackColor(for: part)
        var random = PortraitPRNG(seed: seed)
        let jitter = (Float(random.unit()) - 0.5) * variation * 0.24
        func channel(_ input: Float, _ expressive: Float) -> Float {
            max(0, min(1, input * (1 - variation * 0.7)
                           + expressive * variation * 0.7 + jitter))
        }
        let mixed = RGBAColor(red: channel(camera.red, accent.red),
                              green: channel(camera.green, accent.green),
                              blue: channel(camera.blue, accent.blue),
                              alpha: settings.resolvedPortraitFillOpacity)
        guard settings.resolvedPortraitFillPalettized else { return mixed }
        let choices = printPalette.prefix(settings.resolvedPortraitFillPaletteSteps)
        let nearest = choices.min { lhs, rhs in
            func distance(_ color: RGBAColor) -> Float {
                let red = color.red - mixed.red
                let green = color.green - mixed.green
                let blue = color.blue - mixed.blue
                return red * red * 0.3 + green * green * 0.59 + blue * blue * 0.11
            }
            return distance(lhs) < distance(rhs)
        } ?? mixed
        return RGBAColor(red: nearest.red, green: nearest.green,
                         blue: nearest.blue, alpha: mixed.alpha)
    }

    private static func fallbackColor(for part: Part) -> RGBAColor {
        switch part {
        case .body: RGBAColor(red: 0.48, green: 0.68, blue: 0.75)
        case .neck, .face: RGBAColor(red: 0.94, green: 0.69, blue: 0.60)
        case .hair: RGBAColor(red: 0.32, green: 0.28, blue: 0.23)
        case .hand: RGBAColor(red: 0.95, green: 0.72, blue: 0.62)
        }
    }
}

/// Color belongs to a semantic part, not to the detector's current point or
/// the order in which shapes arrived this frame. Sampling is averaged over
/// seconds; a limited-palette swatch changes only after a long hold and a
/// meaningful distance improvement, so boundary noise cannot flicker it.
final class PortraitFillColorTracker {
    private struct Style: Equatable {
        let seed: Int
        let palette: Bool
        let steps: Int
        let variation: Float
    }

    private struct Record {
        var average: RGBAColor
        var displayed: RGBAColor
        var lastSample: TimeInterval
        var lastPaletteChange: TimeInterval
    }

    private var style: Style?
    private var records: [Int: Record] = [:]

    func color(camera: RGBAColor, part: PortraitFillRenderer.Part, slot: Int,
               settings: LandmarkSettings, seed: Int,
               now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> RGBAColor {
        let nextStyle = Style(seed: settings.resolvedPortraitSeed,
                              palette: settings.resolvedPortraitFillPalettized,
                              steps: settings.resolvedPortraitFillPaletteSteps,
                              variation: settings.resolvedPortraitFillVariation)
        if style != nextStyle {
            style = nextStyle
            records.removeAll()
        }
        guard var record = records[slot] else {
            let displayed = PortraitFillRenderer.paintColor(camera: camera, part: part,
                                                            settings: settings, seed: seed)
            records[slot] = Record(average: camera, displayed: displayed,
                                   lastSample: now, lastPaletteChange: now)
            return displayed
        }
        let elapsed = max(0, min(30, now - record.lastSample))
        let averageRate = Float(1 - exp(-elapsed / 8))
        record.average = blend(record.average, camera, by: averageRate)
        let desired = PortraitFillRenderer.paintColor(camera: record.average, part: part,
                                                      settings: settings, seed: seed)
        if settings.resolvedPortraitFillPalettized {
            if now - record.lastPaletteChange >= 8, desired != record.displayed {
                var continuous = settings
                continuous.portraitFillPalettized = false
                let target = PortraitFillRenderer.paintColor(camera: record.average, part: part,
                                                             settings: continuous, seed: seed)
                if distance(target, desired) + 0.018 < distance(target, record.displayed) {
                    record.displayed = desired
                    record.lastPaletteChange = now
                }
            }
        } else {
            record.displayed = blend(record.displayed, desired,
                                     by: Float(1 - exp(-elapsed / 4)))
        }
        record.displayed.alpha = settings.resolvedPortraitFillOpacity
        record.lastSample = now
        records[slot] = record
        return record.displayed
    }

    private func blend(_ a: RGBAColor, _ b: RGBAColor, by amount: Float) -> RGBAColor {
        let t = min(1, max(0, amount))
        return RGBAColor(red: a.red + (b.red - a.red) * t,
                         green: a.green + (b.green - a.green) * t,
                         blue: a.blue + (b.blue - a.blue) * t,
                         alpha: b.alpha)
    }

    private func distance(_ a: RGBAColor, _ b: RGBAColor) -> Float {
        let red = a.red - b.red, green = a.green - b.green, blue = a.blue - b.blue
        return red * red * 0.3 + green * green * 0.59 + blue * blue * 0.11
    }
}
