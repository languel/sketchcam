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
                    self.cachedMatte = matte
                }
                self.lastSegmentMillis = elapsed
                self.inFlight = false
            }
        }
    }

    private func runSegmentation(pixelBuffer: CVPixelBuffer, quality: SegmentationQuality) -> CIImage? {
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
        return CIImage(cvPixelBuffer: matteBuffer)
    }
}
