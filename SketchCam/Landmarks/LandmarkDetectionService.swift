import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import SketchCamCore
import SketchCamShared

/// Owns landmark detection off the frame hot path.
///
/// The processing queue calls `currentDetection(...)` once per frame: it
/// returns the cached detection immediately and, if a detection is due
/// (rate-limited, none in flight), snapshots the frame at the configured
/// detection resolution and runs the tracker on a separate queue. Synthetic
/// mode is computed inline (it is just math).
final class LandmarkDetectionService {
    private let tracker = VisionLandmarkTracker()
    private let detectionQueue = DispatchQueue(label: "io.github.languel.sketchcam.landmarks", qos: .utility)
    private let context: CIContext
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    private let downsamplePool = PixelBufferPool()

    private let lock = NSLock()
    private struct TimedDetection { let detection: LandmarkDetection; let time: CFAbsoluteTime }
    private var latest: TimedDetection?
    private var previous: TimedDetection?
    private var detectionInFlight = false
    private var lastDetectionStart: CFAbsoluteTime = 0
    private var nextDetectionID: UInt64 = 1
    private var frameTick: UInt64 = 0
    private(set) var lastDetectionMillis: Double = 0

    init(context: CIContext) {
        self.context = context
    }

    func currentDetection(
        pixelBuffer: CVPixelBuffer,
        settings: ProcessingSettings,
        frameIndex: Int
    ) -> LandmarkDetection? {
        guard settings.landmarks.enabled else {
            lock.withLock {
                latest = nil
                previous = nil
            }
            return nil
        }

        if settings.landmarks.sourceMode == .synthetic {
            // Deterministic and cheap — regenerate per frame so the doodle animates.
            let groups = SyntheticLandmarkGenerator.makeGroups(settings: settings, frameIndex: frameIndex)
            return LandmarkDetection(
                groups: groups,
                detectionID: UInt64(frameIndex),
                sourceSize: CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
            )
        }

        scheduleIfDue(pixelBuffer: pixelBuffer, settings: settings)
        let now = CFAbsoluteTimeGetCurrent()
        return lock.withLock {
            settings.landmarks.predictiveTracking ? extrapolatedLocked(now: now) : latest?.detection
        }
    }

    /// Predicts each landmark forward to `now` from the last two detections and
    /// stamps a per-frame id so the overlay re-renders every frame (smooth
    /// frame-rate tracking instead of stepping at the detection cadence). Must
    /// be called while holding `lock`. Matches points across detections by
    /// region + stable label.
    private func extrapolatedLocked(now: CFAbsoluteTime) -> LandmarkDetection? {
        guard let latest else { return nil }
        guard let previous, latest.time > previous.time else { return latest.detection }
        let dt = latest.time - previous.time
        let ahead = min(max(0, now - latest.time), dt)   // clamp to ≤ one interval (limits overshoot)
        guard ahead > 0.0001 else { return latest.detection }
        let factor = CGFloat(ahead / dt)

        var prev: [String: CGPoint] = [:]
        for group in previous.detection.groups {
            for point in group.points where point.label != nil {
                prev["\(group.region.rawValue):\(point.label!)"] = point.point
            }
        }
        let groups = latest.detection.groups.map { group -> LandmarkGroup in
            let points = group.points.map { point -> LandmarkPoint in
                guard let label = point.label, let was = prev["\(group.region.rawValue):\(label)"] else { return point }
                let predicted = CGPoint(
                    x: point.point.x + (point.point.x - was.x) * factor,
                    y: point.point.y + (point.point.y - was.y) * factor
                )
                return LandmarkPoint(point: predicted, confidence: point.confidence, label: point.label)
            }
            return LandmarkGroup(region: group.region, points: points, edges: group.edges)
        }
        frameTick &+= 1
        return LandmarkDetection(groups: groups, detectionID: frameTick, sourceSize: latest.detection.sourceSize)
    }

    private func scheduleIfDue(pixelBuffer: CVPixelBuffer, settings: ProcessingSettings) {
        let interval = 1.0 / max(1, settings.landmarks.detectionsPerSecond)
        let now = CFAbsoluteTimeGetCurrent()

        let shouldSubmit: Bool = lock.withLock {
            guard !detectionInFlight, now - lastDetectionStart >= interval else { return false }
            detectionInFlight = true
            lastDetectionStart = now
            return true
        }
        guard shouldSubmit else { return }

        let sourceSize = CGSize(width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer))
        guard let detectionBuffer = downsample(pixelBuffer, maxDimension: settings.landmarks.detectionMaxDimension) else {
            lock.withLock { detectionInFlight = false }
            return
        }

        let landmarkSettings = settings.landmarks
        detectionQueue.async { [weak self] in
            guard let self else { return }
            let start = CFAbsoluteTimeGetCurrent()
            let groups = self.tracker.detect(in: detectionBuffer, settings: landmarkSettings)
            let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1_000
            let completedAt = CFAbsoluteTimeGetCurrent()
            self.lock.withLock {
                if !groups.isEmpty || self.latest != nil {
                    let detection = LandmarkDetection(
                        groups: groups,
                        detectionID: self.nextDetectionID,
                        sourceSize: sourceSize
                    )
                    self.nextDetectionID += 1
                    self.previous = self.latest
                    self.latest = TimedDetection(detection: detection, time: completedAt)
                }
                self.lastDetectionMillis = elapsed
                self.detectionInFlight = false
            }
        }
    }

    private func downsample(_ pixelBuffer: CVPixelBuffer, maxDimension: Int) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let currentMax = max(width, height)
        guard currentMax > maxDimension else {
            // Already small enough — Vision can consume the capture buffer
            // directly; it never mutates it.
            return pixelBuffer
        }

        let scale = CGFloat(maxDimension) / CGFloat(currentMax)
        let outputWidth = max(2, Int((CGFloat(width) * scale).rounded(.toNearestOrAwayFromZero)))
        let outputHeight = max(2, Int((CGFloat(height) * scale).rounded(.toNearestOrAwayFromZero)))
        let format = FrameFormat(id: "landmarks-\(outputWidth)x\(outputHeight)", width: outputWidth, height: outputHeight)

        do {
            let output = try downsamplePool.makeBuffer(format: format)
            let bounds = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)
            let image = CIImage(cvPixelBuffer: pixelBuffer)
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .cropped(to: bounds)
            context.render(image, to: output, bounds: bounds, colorSpace: colorSpace)
            return output
        } catch {
            return nil
        }
    }
}
