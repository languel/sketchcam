import AVFoundation
import CoreVideo
import Foundation

/// Deterministic frame source for iterating on detection/effect quality:
/// loops a local movie file (or a network stream URL) through the same
/// pipeline as the camera, with adjustable playback rate so fast motion can
/// be slowed down while tuning.
final class MoviePlaybackSource {
    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    private let player = AVQueuePlayer()
    private var looper: AVPlayerLooper?
    private var videoOutput: AVPlayerItemVideoOutput?
    private weak var attachedItem: AVPlayerItem?
    private var timer: DispatchSourceTimer?
    private var lastPixelBuffer: CVPixelBuffer?
    private let queue = DispatchQueue(label: "io.github.languel.sketchcam.movie", qos: .userInitiated)
    private(set) var currentURL: URL?
    private var currentRate: Float = 1

    var isPlaying: Bool { timer != nil }
    var currentTimeSeconds: Double { player.currentTime().seconds }

    func play(url: URL, rate: Float) {
        stop()
        currentURL = url
        currentRate = rate

        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ])
        videoOutput = output
        attachedItem = nil

        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = true
        player.playImmediately(atRate: rate)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(3))
        timer.setEventHandler { [weak self] in
            self?.pullFrame()
        }
        self.timer = timer
        timer.resume()
    }

    /// Rate 0 pauses (the last frame keeps being delivered so detection,
    /// preview, and the published feed stay alive on the frozen image).
    func setRate(_ rate: Float) {
        currentRate = rate
        guard isPlaying else { return }
        player.rate = rate
    }

    /// Advances the current movie deterministically for stop-motion capture.
    @discardableResult
    func step(seconds: Double, loop: Bool) -> Bool {
        guard seconds != 0, let item = player.currentItem else { return true }
        let duration = item.duration.seconds
        var target = player.currentTime().seconds + seconds
        var canContinue = true
        if duration.isFinite, duration > 0 {
            if loop {
                target = target.truncatingRemainder(dividingBy: duration)
                if target < 0 { target += duration }
            } else {
                canContinue = target < duration
                target = min(max(0, target), duration)
            }
        }
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600_000),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        return canContinue
    }

    func stop() {
        timer?.cancel()
        timer = nil
        player.pause()
        player.removeAllItems()
        looper = nil
        videoOutput = nil
        currentURL = nil
        lastPixelBuffer = nil
    }

    private func pullFrame() {
        guard let videoOutput else { return }
        // AVPlayerLooper plays copies of the template item; move the video
        // output onto whichever item is current (an output can only be
        // attached to one item at a time).
        if let item = player.currentItem, item !== attachedItem {
            attachedItem?.remove(videoOutput)
            item.add(videoOutput)
            attachedItem = item
        }
        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
           let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
            lastPixelBuffer = pixelBuffer
            onPixelBuffer?(pixelBuffer)
        } else if let lastPixelBuffer {
            // Paused or between movie frames: keep the pipeline fed so the
            // extension doesn't fall back and detection can keep iterating
            // on the same frame.
            onPixelBuffer?(lastPixelBuffer)
        }
    }
}
