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
    private let queue = DispatchQueue(label: "io.github.languel.sketchcam.segmentation", qos: .utility)
    private let lock = NSLock()
    private var request = VNGeneratePersonSegmentationRequest()
    private var requestQuality = SegmentationQuality.fast
    private var cachedMatte: CIImage?
    fileprivate var cachedMatteBuffer: CVPixelBuffer?
    fileprivate var cachedContour: LandmarkGroup?
    fileprivate var matteVersion: UInt64 = 0
    fileprivate var contourVersion: UInt64 = .max
    fileprivate var lastContourTrace: CFAbsoluteTime = 0
    fileprivate var lastContourDetail: Float = -1
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
    /// Traces the latest matte into a ring of contour points that follows the
    /// silhouette BOUNDARY (Moore-neighbor tracing) — so it hugs concavities
    /// (armpits, between fingers/legs) the old radial ray-cast could not — then
    /// resamples to a point count set by `detail`. IDs are stable (s0 = top of
    /// head, walking the boundary), normalized bottom-left like Vision points.
    /// Rate-limited to `maxPerSecond` (the detection cadence): tracing per matte
    /// (~30 Hz) invalidated the overlay cache every frame.
    func currentContour(maxPerSecond: Double = 10, detail: Float = 0.4) -> (group: LandmarkGroup, version: UInt64)? {
        lock.withLock {
            guard let buffer = cachedMatteBuffer else { return nil }
            let now = CFAbsoluteTimeGetCurrent()
            let due = now - lastContourTrace >= 1.0 / max(1, maxPerSecond)
            if let cachedContour, lastContourDetail == detail, (contourVersion == matteVersion || !due) {
                return (cachedContour, contourVersion)
            }
            lastContourTrace = now
            lastContourDetail = detail
            let pointCount = Int((24 + (240 - 24) * max(0, min(1, detail))).rounded())
            guard let points = Self.traceContour(buffer, pointCount: pointCount) else { return nil }
            var edges = (0..<(points.count - 1)).map { ($0, $0 + 1) }
            edges.append((points.count - 1, 0))
            let group = LandmarkGroup(region: .contour, points: points, edges: edges)
            cachedContour = group
            contourVersion = matteVersion
            return (group, contourVersion)
        }
    }

    private static func traceContour(_ buffer: CVPixelBuffer, pointCount: Int) -> [LandmarkPoint]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let data = base.assumingMemoryBound(to: UInt8.self)

        @inline(__always) func isPerson(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < width && y < height && data[y * rowBytes + x] > 127
        }

        // Start at the topmost-leftmost person pixel (a guaranteed boundary
        // pixel reached scanning top→bottom, left→right).
        var start: (x: Int, y: Int)?
        scan: for y in 0..<height {
            let row = y * rowBytes
            for x in 0..<width where data[row + x] > 127 {
                start = (x, y); break scan
            }
        }
        guard let start else { return nil }

        // Moore-neighbor boundary tracing, clockwise (y is downward on screen).
        let off = [(-1, -1), (0, -1), (1, -1), (1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0)]
        var boundary: [(Int, Int)] = [start]
        var current = start
        // We arrived at `start` from its left (background); begin searching one
        // step clockwise from that backtrack direction.
        var searchStart = (7 + 1) % 8   // 7 = (-1,0) = left
        let maxSteps = (width + height) * 4 + 16
        var steps = 0
        while steps < maxSteps {
            steps += 1
            var moved = false
            for k in 0..<8 {
                let i = (searchStart + k) % 8
                let nx = current.x + off[i].0
                let ny = current.y + off[i].1
                if isPerson(nx, ny) {
                    boundary.append((nx, ny))
                    let backFromNew = (i + 4) % 8        // direction new→current
                    searchStart = (backFromNew + 1) % 8  // resume clockwise after it
                    current = (nx, ny)
                    moved = true
                    break
                }
            }
            if !moved { break }                          // isolated pixel
            if current == start && boundary.count > 2 { break }
        }
        guard boundary.count >= 8 else { return nil }

        // Arc-length resample the closed boundary to `pointCount` even stations.
        let perimeter = (0..<boundary.count).reduce(0.0) { acc, i in
            let a = boundary[i], b = boundary[(i + 1) % boundary.count]
            return acc + hypot(Double(b.0 - a.0), Double(b.1 - a.1))
        }
        guard perimeter > 1 else { return nil }
        let step = perimeter / Double(pointCount)

        var sampled: [(Double, Double)] = []
        sampled.reserveCapacity(pointCount)
        var accumulated = 0.0
        var target = 0.0
        var i = 0
        while sampled.count < pointCount && i < boundary.count {
            let a = boundary[i], b = boundary[(i + 1) % boundary.count]
            let segLen = hypot(Double(b.0 - a.0), Double(b.1 - a.1))
            while target <= accumulated + segLen && sampled.count < pointCount {
                let f = segLen > 1e-6 ? (target - accumulated) / segLen : 0
                sampled.append((Double(a.0) + (Double(b.0 - a.0)) * f,
                                Double(a.1) + (Double(b.1 - a.1)) * f))
                target += step
            }
            accumulated += segLen
            i += 1
        }
        guard sampled.count >= 3 else { return nil }

        // Rotate so s0 is the topmost station (smallest screen-y = top of head).
        let topIndex = sampled.indices.min { sampled[$0].1 < sampled[$1].1 } ?? 0
        let ring = Array(sampled[topIndex...] + sampled[..<topIndex])

        return ring.enumerated().map { index, p in
            LandmarkPoint(
                point: CGPoint(x: p.0 / Double(width), y: 1 - p.1 / Double(height)),
                confidence: 1,
                label: "s\(index)"
            )
        }
    }
}
