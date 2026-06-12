import CoreImage
import CoreVideo
import Foundation
import SketchCamCore
import Vision

/// Person-segmentation matte via Vision (`VNGeneratePersonSegmentationRequest`,
/// ANE-backed) — the native macOS equivalent of MediaPipe selfie segmentation.
///
/// Same off-hot-path pattern as landmark detection: the processing queue asks
/// for the current matte each frame; segmentation runs on its own queue and
/// the latest matte is cached. At `.fast` quality a run is a few ms, so the
/// matte lags the video by at most a frame or two.
final class SegmentationService {
    private let queue = DispatchQueue(label: "io.github.languel.sketchcam.segmentation", qos: .userInitiated)
    private let lock = NSLock()
    private var request = VNGeneratePersonSegmentationRequest()
    private var requestQuality = SegmentationQuality.fast
    private var cachedMatte: CIImage?
    fileprivate var cachedMatteBuffer: CVPixelBuffer?
    fileprivate var cachedContour: LandmarkGroup?
    fileprivate var matteVersion: UInt64 = 0
    fileprivate var contourVersion: UInt64 = .max
    fileprivate var lastContourTrace: CFAbsoluteTime = 0
    private var inFlight = false
    private(set) var lastSegmentMillis: Double = 0

    func currentMatte(pixelBuffer: CVPixelBuffer, settings: SegmentationSettings) -> CIImage? {
        guard settings.enabled else {
            lock.withLock { cachedMatte = nil }
            return nil
        }
        schedule(pixelBuffer: pixelBuffer, settings: settings)
        return lock.withLock { cachedMatte }
    }

    private func schedule(pixelBuffer: CVPixelBuffer, settings: SegmentationSettings) {
        let shouldSubmit: Bool = lock.withLock {
            guard !inFlight else { return false }
            inFlight = true
            return true
        }
        guard shouldSubmit else { return }

        queue.async { [weak self] in
            guard let self else { return }
            let start = CFAbsoluteTimeGetCurrent()
            let matte = self.runSegmentation(pixelBuffer: pixelBuffer, quality: settings.quality)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
            self.lock.withLock {
                if let matte {
                    self.cachedMatte = matte.image
                    self.cachedMatteBuffer = matte.buffer
                    self.matteVersion &+= 1
                }
                self.lastSegmentMillis = elapsed
                self.inFlight = false
            }
        }
    }

    private func runSegmentation(pixelBuffer: CVPixelBuffer, quality: SegmentationQuality) -> (image: CIImage, buffer: CVPixelBuffer)? {
        if requestQuality != quality {
            request = VNGeneratePersonSegmentationRequest()
            requestQuality = quality
        }
        switch quality {
        case .fast: request.qualityLevel = .fast
        case .balanced: request.qualityLevel = .balanced
        case .accurate: request.qualityLevel = .accurate
        }
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let matteBuffer = request.results?.first?.pixelBuffer else { return nil }
        return (CIImage(cvPixelBuffer: matteBuffer), matteBuffer)
    }
}

// MARK: - Silhouette contour

extension SegmentationService {
    /// Traces the latest matte into a fixed ring of contour points: 64 rays
    /// cast from the silhouette centroid, each keeping the OUTERMOST person
    /// pixel. IDs are stable (s0 = top, clockwise on screen), so drawing
    /// algorithms can address specific stations around the body. Normalized
    /// bottom-left coordinates, same space as Vision landmarks.
    /// Rate-limited: re-traces at most `maxPerSecond` times (default to the
    /// landmark detection cadence). Tracing per matte (~30 Hz) invalidated
    /// the overlay cache every frame and saturated the pipeline.
    func currentContour(maxPerSecond: Double = 10) -> (group: LandmarkGroup, version: UInt64)? {
        lock.withLock {
            guard let buffer = cachedMatteBuffer else { return nil }
            let now = CFAbsoluteTimeGetCurrent()
            let due = now - lastContourTrace >= 1.0 / max(1, maxPerSecond)
            if let cachedContour, contourVersion == matteVersion || !due {
                return (cachedContour, contourVersion)
            }
            lastContourTrace = now
            guard let points = Self.traceContour(buffer) else { return nil }
            var edges = (0..<(points.count - 1)).map { ($0, $0 + 1) }
            edges.append((points.count - 1, 0))
            let group = LandmarkGroup(region: .contour, points: points, edges: edges)
            cachedContour = group
            contourVersion = matteVersion
            return (group, contourVersion)
        }
    }

    private static func traceContour(_ buffer: CVPixelBuffer, pointCount: Int = 64) -> [LandmarkPoint]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let data = base.assumingMemoryBound(to: UInt8.self)

        // centroid of person pixels (coarse scan)
        var sumX = 0.0, sumY = 0.0
        var count = 0
        for y in stride(from: 0, to: height, by: 3) {
            let row = y * rowBytes
            for x in stride(from: 0, to: width, by: 3) where data[row + x] > 127 {
                sumX += Double(x)
                sumY += Double(y)
                count += 1
            }
        }
        guard count > 24 else { return nil }
        let cx = sumX / Double(count)
        let cy = sumY / Double(count)
        let maxRadius = Double(max(width, height)) * 1.5

        var points: [LandmarkPoint] = []
        points.reserveCapacity(pointCount)
        for index in 0..<pointCount {
            // start at screen-top, clockwise (pixel rows are top-down)
            let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(pointCount)
            let dx = cos(angle), dy = sin(angle)
            var last: (Double, Double)?
            var r = 1.0
            while r < maxRadius {
                let x = cx + dx * r
                let y = cy + dy * r
                if x < 0 || y < 0 || x >= Double(width) || y >= Double(height) { break }
                if data[Int(y) * rowBytes + Int(x)] > 127 { last = (x, y) }
                r += 1.25
            }
            let (px, py) = last ?? (cx, cy)
            points.append(LandmarkPoint(
                point: CGPoint(x: px / Double(width), y: 1 - py / Double(height)),
                confidence: last == nil ? 0.1 : 1,
                label: "s\(index)"
            ))
        }
        return points
    }
}
