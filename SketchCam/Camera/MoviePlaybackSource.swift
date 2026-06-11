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
    private let queue = DispatchQueue(label: "io.github.languel.sketchcam.movie", qos: .userInitiated)
    private(set) var currentURL: URL?
    private var currentRate: Float = 1

    var isPlaying: Bool { timer != nil }

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

    func setRate(_ rate: Float) {
        currentRate = rate
        guard isPlaying else { return }
        player.rate = rate
    }

    func stop() {
        timer?.cancel()
        timer = nil
        player.pause()
        player.removeAllItems()
        looper = nil
        videoOutput = nil
        currentURL = nil
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
        guard videoOutput.hasNewPixelBuffer(forItemTime: itemTime),
              let pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) else {
            return
        }
        onPixelBuffer?(pixelBuffer)
    }
}
