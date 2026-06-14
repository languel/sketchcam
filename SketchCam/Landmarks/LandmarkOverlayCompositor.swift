import AppKit
import CoreGraphics
import CoreImage
import CoreText
import CoreVideo
import Foundation
import SketchCamCore
import SketchCamShared

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

    // The vector render happens OFF the frame hot path: when the cache key
    // changes, a render is scheduled on a low-priority queue and the hot
    // path keeps compositing the previous layer until the new one lands
    // (≤ one detection interval stale — same staleness budget as detection
    // itself). A slow render can therefore never drop published frames.
    private let renderQueue = DispatchQueue(label: "io.github.languel.sketchcam.overlay-render", qos: .utility)
    private let lock = NSLock()
    private var cachedImage: CIImage?
    private var cachedKey: CacheKey?
    private var renderingKey: CacheKey?
    /// Duration of the most recent async render (ms) — for the Overlay HUD row.
    private(set) var lastRenderMillis: Double = 0
    // Double-buffered canvases: makeImage() snapshots copy-on-write, so
    // redrawing into the same backing store forces a full-buffer copy.
    // Alternating two contexts means we always draw into the one whose
    // snapshot is no longer current.
    private var contexts: [CGContext?] = [nil, nil]
    private var contextSizes: [CGSize] = [.zero, .zero]
    private var contextIndex = 0

    /// Independent drawing modules. Every enabled one renders per frame, layered
    /// back-to-front in this order. Register new algorithms here; nothing else
    /// needs to change.
    private let algorithms: [DrawingAlgorithm] = [WrapDrawing(), YarnDrawing(), LineWalkDrawing()]

    // GPU drawing path (opt-in via settings.landmarks.useMetalDrawing). Created
    // lazily on the render queue; double-buffered output so the hot path can
    // still composite the previous overlay while the next one renders.
    private lazy var metalRenderer: MetalLineRenderer? = MetalLineRenderer()
    private var overlayBuffers: [CVPixelBuffer?] = [nil, nil]
    private var overlayBufferIndex = 0
    private var overlayBufferSize: CGSize = .zero

    func overlay(
        detection: LandmarkDetection?,
        settings: ProcessingSettings,
        outputSize: CGSize
    ) -> CIImage? {
        guard settings.landmarks.enabled, let detection, !detection.groups.isEmpty else {
            return lock.withLock {
                cachedImage = nil
                cachedKey = nil
                return nil
            }
        }

        let key = CacheKey(
            detectionID: detection.detectionID,
            landmarks: settings.landmarks,
            mirror: settings.mirror,
            outputSize: outputSize
        )
        return lock.withLock {
            if key != cachedKey, renderingKey == nil {
                renderingKey = key
                renderQueue.async { [weak self] in
                    self?.renderAsync(detection: detection, settings: settings, outputSize: outputSize, key: key)
                }
            }
            return cachedImage
        }
    }

    private func renderAsync(detection: LandmarkDetection, settings: ProcessingSettings, outputSize: CGSize, key: CacheKey) {
        let start = CFAbsoluteTimeGetCurrent()
        let image = render(detection: detection, settings: settings, outputSize: outputSize)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
        lock.withLock {
            cachedImage = image
            cachedKey = image == nil ? nil : key
            renderingKey = nil
            lastRenderMillis = elapsed
        }
    }

    private func render(
        detection: LandmarkDetection,
        settings: ProcessingSettings,
        outputSize: CGSize
    ) -> CIImage? {
        // Labels are text: render the canvas at full output resolution when
        // they're on so they stay crisp (the 720p cap + GPU upscale is what
        // made them blurry); vector strokes alone tolerate the upscale.
        let maxHeight = settings.landmarks.showIDs ? outputSize.height : Self.maxOverlayHeight
        let scaleDown = min(1, maxHeight / max(1, outputSize.height))
        let canvasSize = CGSize(
            width: (outputSize.width * scaleDown).rounded(.down),
            height: (outputSize.height * scaleDown).rounded(.down)
        )

        // GPU drawing path: render every enabled algorithm's strokes via Metal
        // in one pass. Only when no Marks renderers are on (dots/stick/labels
        // stay on the CPU path; Metal renders its own buffer).
        let l = settings.landmarks
        if l.useMetalDrawing, l.yarnEnabled || l.wrapEnabled || l.lineWalkEnabled,
           !l.showDots, !l.showStick, !l.showIDs, let metal = metalRenderer {
            return renderMetalOverlay(detection: detection, settings: settings, canvasSize: canvasSize, scaleDown: scaleDown, outputSize: outputSize, metal: metal)
        }

        contextIndex = (contextIndex + 1) % 2
        if contexts[contextIndex] == nil || contextSizes[contextIndex] != canvasSize {
            contexts[contextIndex] = CGContext(
                data: nil,
                width: Int(canvasSize.width),
                height: Int(canvasSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            )
            contextSizes[contextIndex] = canvasSize
        }
        guard let cgContext = contexts[contextIndex] else { return nil }
        cgContext.clear(CGRect(origin: .zero, size: canvasSize))
        cgContext.setAllowsAntialiasing(true)
        cgContext.setShouldAntialias(true)

        let landmarks = settings.landmarks
        // Map every region into canvas space once; reused by the Marks
        // renderers below and handed whole to the active drawing algorithm.
        var mappedGroups: [MappedGroup] = []
        for group in detection.groups {
            let mapped = group.points.map {
                LandmarkCoordinateMapper.map(
                    $0.point,
                    sourceSize: detection.sourceSize,
                    outputSize: canvasSize,
                    mirrored: settings.mirror
                )
            }
            mappedGroups.append(MappedGroup(region: group.region, points: mapped, edges: group.edges))

            // Marks renderers (raw sensor data) are independent of the drawing
            // style and can stack freely.
            if landmarks.showStick {
                drawSkeleton(mapped, edges: group.edges, region: group.region, in: cgContext, landmarks: landmarks)
            }
            if landmarks.showDots {
                drawRaw(mapped, region: group.region, in: cgContext, landmarks: landmarks)
            }
            if landmarks.showIDs {
                drawLabels(mapped, points: group.points, region: group.region, in: cgContext, landmarks: landmarks)
            }
        }

        // Every enabled art algorithm renders, layered in registration order.
        for algorithm in algorithms where algorithm.isEnabled(landmarks) {
            algorithm.render(groups: mappedGroups, landmarks: landmarks, into: cgContext)
        }

        guard let cgImage = cgContext.makeImage() else { return nil }
        let upscale = 1 / scaleDown
        return CIImage(cgImage: cgImage)
            .transformed(by: CGAffineTransform(scaleX: upscale, y: upscale))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// GPU drawing render: map groups → canvas space, gather tessellatable
    /// strokes from every enabled algorithm (layered in registration order),
    /// and rasterize with Metal into an IOSurface buffer wrapped as a CIImage.
    private func renderMetalOverlay(
        detection: LandmarkDetection,
        settings: ProcessingSettings,
        canvasSize: CGSize,
        scaleDown: CGFloat,
        outputSize: CGSize,
        metal: MetalLineRenderer
    ) -> CIImage? {
        let mapped = detection.groups.map { group -> MappedGroup in
            let points = group.points.map {
                LandmarkCoordinateMapper.map($0.point, sourceSize: detection.sourceSize, outputSize: canvasSize, mirrored: settings.mirror)
            }
            return MappedGroup(region: group.region, points: points, edges: group.edges)
        }
        var strokes: [StrokeTessellator.Stroke] = []
        for algorithm in algorithms where algorithm.isEnabled(settings.landmarks) {
            strokes += algorithm.strokes(groups: mapped, landmarks: settings.landmarks)
        }

        let width = Int(canvasSize.width), height = Int(canvasSize.height)
        guard width > 0, height > 0, let buffer = overlayBuffer(width: width, height: height) else { return nil }
        guard metal.render(strokes: strokes, ribbon: !settings.landmarks.beadStroke, into: buffer) else { return nil }

        let upscale = 1 / scaleDown
        return CIImage(cvPixelBuffer: buffer)
            .transformed(by: CGAffineTransform(scaleX: upscale, y: upscale))
            .cropped(to: CGRect(origin: .zero, size: outputSize))
    }

    /// Double-buffered IOSurface-backed BGRA buffer for the Metal overlay,
    /// rebuilt on size change. Alternating buffers avoids overwriting the one
    /// the hot path is still compositing.
    private func overlayBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if overlayBufferSize != size {
            overlayBuffers = [nil, nil]
            overlayBufferSize = size
        }
        overlayBufferIndex = (overlayBufferIndex + 1) % 2
        if overlayBuffers[overlayBufferIndex] == nil {
            overlayBuffers[overlayBufferIndex] = try? PixelBufferUtils.makePixelBuffer(
                format: FrameFormat(id: "metal-overlay", width: width, height: height)
            )
        }
        return overlayBuffers[overlayBufferIndex]
    }

    private func drawRaw(_ points: [CGPoint], region: LandmarkRegion, in context: CGContext, landmarks: LandmarkSettings) {
        let style = landmarks.style(for: region)
        let opacity = CGFloat(min(1, max(0, style.color.alpha)))
        context.setFillColor(DrawingSupport.nsColor(style.color, alphaScale: 0.95).cgColor)
        context.setStrokeColor(NSColor.black.withAlphaComponent(0.45 * opacity).cgColor)
        context.setLineWidth(0.8)
        let radius = CGFloat(max(1.6, style.size * 2.2 * max(0.1, landmarks.dotScale)))
        for point in points {
            let rect = CGRect(x: point.x - radius / 2, y: point.y - radius / 2, width: radius, height: radius)
            context.fillEllipse(in: rect)
            context.strokeEllipse(in: rect)
        }
    }

    /// MediaPipe-docs-style structural rendering: connection lines (face
    /// outline, eye shapes, finger chains, body skeleton) over joint dots.
    private func drawSkeleton(_ points: [CGPoint], edges: [(Int, Int)], region: LandmarkRegion, in context: CGContext, landmarks: LandmarkSettings) {
        let style = landmarks.style(for: region)
        let width = CGFloat(max(0.7, style.size * max(0.1, landmarks.stickScale)))
        let opacity = CGFloat(min(1, max(0, style.color.alpha)))

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
        context.setStrokeColor(DrawingSupport.nsColor(style.color).cgColor)
        context.setLineWidth(width)
        context.strokePath()
        // joints intentionally not drawn — enable the Dots renderer for those
    }

    private func drawLabels(_ mapped: [CGPoint], points: [LandmarkPoint], region: LandmarkRegion, in context: CGContext, landmarks: LandmarkSettings) {
        let style = landmarks.style(for: region)
        let textColor: NSColor = landmarks.labelsMatchColor
            ? DrawingSupport.nsColor(style.color, alphaScale: 1 / max(0.01, CGFloat(style.color.alpha))).blended(withFraction: 0.35, of: .white) ?? .white
            : .white
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: -1), blur: 2.5, color: NSColor.black.cgColor)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: CGFloat(max(6, landmarks.labelSize)), weight: .semibold),
            .foregroundColor: textColor
        ]
        let offset = CGFloat(max(3, style.size * 1.8))
        for (index, point) in mapped.enumerated() {
            guard let label = points[safe: index]?.label else { continue }
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: label, attributes: attributes))
            context.textPosition = CGPoint(x: point.x + offset, y: point.y + offset * 0.75)
            CTLineDraw(line, context)
        }
        context.restoreGState()
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

