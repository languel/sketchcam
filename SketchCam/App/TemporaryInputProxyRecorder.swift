import AVFoundation
import CoreImage
import Foundation

struct TemporaryInputProxySnapshot: Sendable {
    let cameraURL: URL?
    let webURL: URL?
    let duration: Double
}

/// Records raw Camera and Web inputs into temporary, frame-addressable movies
/// for deterministic NRT export. Files are session-only and are removed on
/// normal quit; stale sessions are pruned on the next launch.
final class TemporaryInputProxyRecorder: ObservableObject, @unchecked Sendable {
    @Published private(set) var isRecording = false
    @Published private(set) var statusText = "No input proxy"
    @Published private(set) var recordedDuration = 0.0

    private final class Track {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor

        init(url: URL, width: Int, height: Int, fps: Double) throws {
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [
                    AVVideoExpectedSourceFrameRateKey: fps,
                    AVVideoAverageBitRateKey: max(2_000_000, width * height * 4)
                ]
            ])
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ExporterError.cannotAddInput }
            writer.add(input)
            adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ])
            guard writer.startWriting() else { throw writer.error ?? ExporterError.cannotCreateWriter }
            writer.startSession(atSourceTime: .zero)
        }

        func append(_ buffer: CVPixelBuffer, at time: CMTime) {
            guard input.isReadyForMoreMediaData else { return }
            _ = adaptor.append(buffer, withPresentationTime: time)
        }

        func finish() {
            input.markAsFinished()
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            semaphore.wait()
        }
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "io.github.languel.sketchcam.input-proxy", qos: .utility)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let root: URL
    private var folder: URL?
    private var cameraTrack: Track?
    private var webTrack: Track?
    private var cameraURL: URL?
    private var webURL: URL?
    private var startedAt: CFAbsoluteTime = 0
    private var fps = 30.0
    private var size = CGSize.zero
    private var frameIndex = 0
    private var active = false

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SketchCam-NRT-Proxies", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        pruneStaleSessions()
    }

    func start(size: CGSize, fps: Double) {
        clear()
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            lock.withLock {
                self.folder = folder
                self.size = size
                self.fps = min(360, max(0.001, fps))
                self.frameIndex = 0
                self.startedAt = CFAbsoluteTimeGetCurrent()
                self.active = true
            }
            DispatchQueue.main.async {
                self.recordedDuration = 0
                self.statusText = "Recording Camera/Web proxy…"
                self.isRecording = true
            }
        } catch {
            DispatchQueue.main.async { self.statusText = "Proxy failed: \(error.localizedDescription)" }
        }
    }

    func offer(camera: CVPixelBuffer, web: CIImage?) {
        let state = lock.withLock { (active, folder, size, fps, frameIndex) }
        guard state.0, let folder = state.1, state.2.width > 0, state.2.height > 0 else { return }
        lock.withLock { frameIndex += 1 }
        queue.async { [weak self] in
            guard let self, self.lock.withLock({ self.active }) else { return }
            let time = CMTime(value: CMTimeValue(state.4), timescale: CMTimeScale(max(1, Int32(state.3.rounded()))))
            do {
                if self.cameraTrack == nil {
                    let url = folder.appendingPathComponent("camera.mov")
                    self.cameraTrack = try Track(url: url, width: Int(state.2.width), height: Int(state.2.height), fps: state.3)
                    self.cameraURL = url
                }
                let cameraBuffer = self.scaled(camera, size: state.2) ?? camera
                self.cameraTrack?.append(cameraBuffer, at: time)
                if let web {
                    if self.webTrack == nil {
                        let url = folder.appendingPathComponent("web.mov")
                        self.webTrack = try Track(url: url, width: Int(state.2.width), height: Int(state.2.height), fps: state.3)
                        self.webURL = url
                    }
                    if let webBuffer = self.buffer(image: web, size: state.2) {
                        self.webTrack?.append(webBuffer, at: time)
                    }
                }
                let duration = Double(state.4 + 1) / state.3
                DispatchQueue.main.async { self.recordedDuration = duration }
            } catch {
                self.stop(message: "Proxy failed: \(error.localizedDescription)")
            }
        }
    }

    func stop(message: String? = nil) {
        let wasActive = lock.withLock { let value = active; active = false; return value }
        guard wasActive else { return }
        queue.async { [weak self] in
            guard let self else { return }
            self.cameraTrack?.finish(); self.webTrack?.finish()
            self.cameraTrack = nil; self.webTrack = nil
            DispatchQueue.main.async {
                self.isRecording = false
                self.statusText = message ?? String(format: "Proxy ready · %.1f s", self.recordedDuration)
            }
        }
    }

    func snapshot() -> TemporaryInputProxySnapshot? {
        lock.withLock {
            guard !active, cameraURL != nil || webURL != nil else { return nil }
            return TemporaryInputProxySnapshot(cameraURL: cameraURL, webURL: webURL,
                                               duration: Double(frameIndex) / max(0.001, fps))
        }
    }

    func clear() {
        stop()
        queue.sync {
            cameraTrack = nil; webTrack = nil
            if let folder { try? FileManager.default.removeItem(at: folder) }
            folder = nil; cameraURL = nil; webURL = nil
        }
        DispatchQueue.main.async {
            self.recordedDuration = 0
            self.statusText = "No input proxy"
            self.isRecording = false
        }
    }

    private func scaled(_ source: CVPixelBuffer, size: CGSize) -> CVPixelBuffer? {
        buffer(image: CIImage(cvPixelBuffer: source), size: size)
    }

    private func buffer(image: CIImage, size: CGSize) -> CVPixelBuffer? {
        var output: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
        guard let output else { return nil }
        let rect = CGRect(origin: .zero, size: size)
        let sx = size.width / max(1, image.extent.width), sy = size.height / max(1, image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: sx, y: sy)).cropped(to: rect)
        context.render(scaled, to: output, bounds: rect, colorSpace: nil)
        return output
    }

    private func pruneStaleSessions() {
        let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in urls {
            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if date == nil || date! < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }
}
