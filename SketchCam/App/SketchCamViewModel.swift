import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import SketchCamCore
import SketchCamShared
import UniformTypeIdentifiers

final class SketchCamViewModel: ObservableObject {
    enum FrameSource: String, CaseIterable, Identifiable {
        case camera
        case movie

        var id: String { rawValue }
        var title: String {
            switch self {
            case .camera: return "Camera"
            case .movie: return "Movie"
            }
        }
    }

    @Published var cameraDevices: [CameraDeviceOption] = []
    @Published var selectedDeviceID: String?
    @Published var frameSource = FrameSource.camera {
        didSet {
            guard oldValue != frameSource else { return }
            applyFrameSource()
        }
    }
    @Published var movieURL: URL? {
        didSet {
            if frameSource == .movie {
                applyFrameSource()
            }
        }
    }
    @Published var movieRate: Double = 1.0 {
        didSet { movieSource.setRate(Float(movieRate)) }
    }
    /// Freeze the input: the next incoming frame is copied and re-fed to the
    /// pipeline on every tick, so detection/effects keep running on one
    /// still image for analysis and annotation (combine with Show IDs).
    @Published var inputFrozen = false {
        didSet {
            guard !inputFrozen else { return }
            frozenLock.withLock { frozenFrame = nil }
        }
    }
    @Published var inputResolution = CameraInputResolution.vga {
        didSet {
            guard oldValue != inputResolution, cameraPermissionState == .authorized else { return }
            captureService.start(deviceID: selectedDeviceID, inputResolution: inputResolution)
        }
    }
    @Published var settings = ProcessingSettings() {
        didSet { store.settings = settings }
    }
    @Published var outputFormat = SketchCamFormats.defaultFormat {
        didSet { store.outputFormat = outputFormat }
    }
    @Published var previewImage: CGImage?
    @Published var stats = DebugStats()
    @Published var cameraPermissionState = CameraPermissionManager.state {
        didSet { store.permission = cameraPermissionState }
    }
    @Published var errorText: String?

    let activationManager = ExtensionActivationManager()

    private let store = PipelineStateStore()
    private let captureService = CameraCaptureService()
    private let movieSource = MoviePlaybackSource()
    // One CIContext for the whole pipeline (processor + preview): separate
    // contexts mean separate Metal queues/caches and extra GPU sync.
    private static let sharedCIContext = CIContext(options: [.cacheIntermediates: true])
    private let processor = CoreImageFrameProcessor(context: SketchCamViewModel.sharedCIContext)
    private let previewRenderer = PreviewRenderer(context: SketchCamViewModel.sharedCIContext)
    private let landmarkService = LandmarkDetectionService(context: SketchCamViewModel.sharedCIContext)
    private let overlayCompositor = LandmarkOverlayCompositor()
    private let segmentationService = SegmentationService()
    private let publisher = VirtualCameraFramePublisher()
    private let processingQueue = DispatchQueue(label: "io.github.languel.sketchcam.processing", qos: .userInitiated)
    private let timings = PipelineTimings()
    private let frameGate = NSLock()
    private var cameraFrameInFlight = false
    private let frozenLock = NSLock()
    private var frozenFrame: CVPixelBuffer?
    private let exportLock = NSLock()
    private var lastPublishedFrame: CVPixelBuffer?
    private var movieRateBeforePause: Double = 1
    private var lastPreviewTime: CFAbsoluteTime = 0
    private var lastStatsTime: CFAbsoluteTime = 0
    private var lastPerfLogTime: CFAbsoluteTime = 0
    private var frameIndex = 0
    private var fpsStartTime = CFAbsoluteTimeGetCurrent()
    private var fpsFrameCount = 0
    private var testPatternTimer: DispatchSourceTimer?

    /// Preview readback cadence; publishing runs at full frame rate regardless.
    private let previewInterval: CFAbsoluteTime = 1.0 / 12.0
    private let statsInterval: CFAbsoluteTime = 0.25

    init() {
        captureService.onConfigurationChanged = { [weak self] size in
            DispatchQueue.main.async {
                self?.stats.cameraResolution = size
            }
        }
        captureService.onSampleBuffer = { [weak self] sampleBuffer in
            self?.handleCameraSample(sampleBuffer)
        }
        movieSource.onPixelBuffer = { [weak self] pixelBuffer in
            self?.handleMovieFrame(pixelBuffer)
        }
    }

    func openMoviePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a movie to use as the frame source"
        if panel.runModal() == .OK, let url = panel.url {
            movieURL = url
            frameSource = .movie
        }
    }

    func openMovieURL(_ string: String) {
        guard let url = URL(string: string), url.scheme?.hasPrefix("http") == true else { return }
        movieURL = url
        frameSource = .movie
    }

    private func applyFrameSource() {
        switch frameSource {
        case .camera:
            movieSource.stop()
            if cameraPermissionState == .authorized {
                captureService.start(deviceID: selectedDeviceID, inputResolution: inputResolution)
            }
        case .movie:
            captureService.stop()
            if let movieURL {
                movieSource.play(url: movieURL, rate: Float(movieRate))
                DispatchQueue.main.async {
                    self.stats.cameraResolution = .zero
                }
            }
        }
    }

    /// One shortcut, contextual behavior: pauses/resumes the movie when it
    /// is the source, freezes/unfreezes the live input otherwise.
    func toggleFreezeOrPause() {
        if frameSource == .movie {
            if movieRate == 0 {
                movieRate = movieRateBeforePause
            } else {
                movieRateBeforePause = movieRate
                movieRate = 0
            }
        } else {
            inputFrozen.toggle()
        }
    }

    /// Export the most recently published frame (full output resolution,
    /// PNG with alpha) via a save panel.
    func exportCurrentFrame() {
        let frame = exportLock.withLock { lastPublishedFrame }
        guard let frame else {
            errorText = "No frame to export yet."
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "sketchcam-\(stamp).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let image = CIImage(cvPixelBuffer: frame)
        guard let cgImage = Self.sharedCIContext.createCGImage(
            image,
            from: image.extent,
            format: .BGRA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        ) else {
            errorText = "Could not render export image."
            return
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            errorText = "Could not encode PNG."
            return
        }
        do {
            try data.write(to: url)
        } catch {
            errorText = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleMovieFrame(_ pixelBuffer: CVPixelBuffer) {
        guard beginCameraFrame() else { return }
        let effective = effectiveInputFrame(pixelBuffer)
        process(
            pixelBuffer: effective,
            timestamp: CMClockGetTime(CMClockGetHostTimeClock()),
            originalPixelBuffer: effective
        )
    }

    func start() {
        refreshDevices()
        startTestPatternTimer()
        // Dev affordance: enable the overlay at launch for headless perf
        // verification and demo scripts. Env var works for direct exec;
        // `defaults write io.github.languel.sketchcam SKETCHCAM_LANDMARKS camera`
        // works for LaunchServices launches.
        let landmarkOverride = ProcessInfo.processInfo.environment["SKETCHCAM_LANDMARKS"]
            ?? UserDefaults.standard.string(forKey: "SKETCHCAM_LANDMARKS")
        if let mode = landmarkOverride, !mode.isEmpty {
            settings.landmarks.enabled = true
            settings.landmarks.sourceMode = mode == "synthetic" ? .synthetic : .camera
        }
        Task {
            let granted = await CameraPermissionManager.requestAccess()
            DispatchQueue.main.async {
                self.cameraPermissionState = CameraPermissionManager.state
                if granted {
                    self.settings.testPatternMode = false
                    self.captureService.start(deviceID: self.selectedDeviceID, inputResolution: self.inputResolution)
                } else {
                    self.settings.testPatternMode = true
                    self.errorText = "Camera permission denied; using test pattern."
                }
            }
        }
    }

    func stop() {
        captureService.stop()
        testPatternTimer?.cancel()
        testPatternTimer = nil
        publisher.disconnect()
    }

    func refreshDevices() {
        let devices = captureService.availableDevices()
        cameraDevices = devices
        if selectedDeviceID == nil {
            selectedDeviceID = devices.first?.id
        }
    }

    func selectCamera(_ id: String?) {
        selectedDeviceID = id
        guard cameraPermissionState == .authorized else { return }
        captureService.start(deviceID: id, inputResolution: inputResolution)
    }

    func activateExtension() {
        activationManager.activate()
    }

    func deactivateExtension() {
        publisher.disconnect()
        activationManager.deactivate()
    }

    private func handleCameraSample(_ sampleBuffer: CMSampleBuffer) {
        guard !store.settings.testPatternMode,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        // Drop frames while one is in flight instead of queueing them up —
        // backlog on the processing queue turns into unbounded latency.
        guard beginCameraFrame() else { return }
        let effective = effectiveInputFrame(pixelBuffer)
        process(pixelBuffer: effective, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), originalPixelBuffer: effective)
    }

    /// When frozen, the first incoming frame is deep-copied (camera buffers
    /// come from a small fixed pool — holding one starves the capture
    /// session) and substituted for every subsequent frame.
    private func effectiveInputFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        guard inputFrozen else { return pixelBuffer }
        return frozenLock.withLock {
            if let frozenFrame {
                return frozenFrame
            }
            let copy = Self.deepCopy(pixelBuffer) ?? pixelBuffer
            frozenFrame = copy
            return copy
        }
    }

    private static func deepCopy(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let format = FrameFormat(
            id: "frozen",
            width: CVPixelBufferGetWidth(pixelBuffer),
            height: CVPixelBufferGetHeight(pixelBuffer)
        )
        guard let copy = try? PixelBufferUtils.makePixelBuffer(format: format) else { return nil }
        sharedCIContext.render(CIImage(cvPixelBuffer: pixelBuffer), to: copy)
        return copy
    }

    private func beginCameraFrame() -> Bool {
        frameGate.lock()
        defer { frameGate.unlock() }
        guard !cameraFrameInFlight else { return false }
        cameraFrameInFlight = true
        return true
    }

    private func endCameraFrame() {
        frameGate.lock()
        cameraFrameInFlight = false
        frameGate.unlock()
    }

    private func startTestPatternTimer() {
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot = self.store.settings
            let permission = self.store.permission
            guard snapshot.testPatternMode || permission != .authorized else { return }
            do {
                let format = self.store.outputFormat
                let pattern = try TestPatternGenerator.makeFrame(format: format, frameIndex: self.nextFrameIndex())
                self.publish(frame: pattern.pixelBuffer, sampleBuffer: pattern.sampleBuffer, originalPixelBuffer: pattern.pixelBuffer)
            } catch {
                self.publishError(error)
            }
        }
        testPatternTimer = timer
        timer.resume()
    }

    private func process(pixelBuffer: CVPixelBuffer, timestamp: CMTime, originalPixelBuffer: CVPixelBuffer) {
        processingQueue.async { [weak self] in
            guard let self else { return }
            defer { self.endCameraFrame() }
            let frameStart = CFAbsoluteTimeGetCurrent()
            let (settings, outputFormat) = self.timings.measure(.snapshot) {
                (self.store.settings, self.store.outputFormat)
            }
            do {
                let frameIndex = self.nextFrameIndex()
                let overlay = self.timings.measure(.overlay) { () -> CIImage? in
                    guard settings.landmarks.enabled else { return nil }
                    let detection = self.landmarkService.currentDetection(
                        pixelBuffer: originalPixelBuffer,
                        settings: settings,
                        frameIndex: frameIndex
                    )
                    return self.overlayCompositor.overlay(
                        detection: detection,
                        settings: settings,
                        outputSize: outputFormat.size
                    )
                }
                self.timings.record(.detect, seconds: self.landmarkService.lastDetectionMillis / 1_000)
                let matte = self.segmentationService.currentMatte(
                    pixelBuffer: originalPixelBuffer,
                    settings: settings.segmentation
                )
                self.timings.record(.segment, seconds: self.segmentationService.lastSegmentMillis / 1_000)
                let processed = try self.timings.measure(.process) {
                    try self.processor.process(
                        pixelBuffer: pixelBuffer,
                        settings: settings,
                        outputFormat: outputFormat,
                        frameIndex: frameIndex,
                        timestamp: timestamp,
                        overlay: overlay,
                        matte: matte
                    )
                }
                self.publish(frame: processed.pixelBuffer, sampleBuffer: processed.sampleBuffer, originalPixelBuffer: originalPixelBuffer)
                self.timings.record(.total, seconds: CFAbsoluteTimeGetCurrent() - frameStart)
            } catch {
                self.publishError(error)
            }
        }
    }

    private func publish(frame pixelBuffer: CVPixelBuffer, sampleBuffer: CMSampleBuffer, originalPixelBuffer: CVPixelBuffer) {
        let settings = store.settings
        let outputFormat = store.outputFormat

        timings.measure(.publish) {
            publisher.publish(sampleBuffer)
        }
        exportLock.withLock { lastPublishedFrame = pixelBuffer }
        let fps = updateFPS()

        // Preview and stats are decoupled from publishing: the virtual camera
        // gets every frame; the UI gets a throttled, downscaled view of them.
        let now = CFAbsoluteTimeGetCurrent()
        var image: CGImage?
        if settings.previewEnabled, now - lastPreviewTime >= previewInterval {
            lastPreviewTime = now
            image = timings.measure(.preview) {
                switch settings.previewMode {
                case .processed:
                    return previewRenderer.makeImage(from: pixelBuffer)
                case .original:
                    return previewRenderer.makeImage(from: originalPixelBuffer)
                case .split:
                    return previewRenderer.makeSplitImage(original: originalPixelBuffer, processed: pixelBuffer, outputFormat: outputFormat)
                }
            }
        }

        let shouldUpdateStats = now - lastStatsTime >= statsInterval
        if shouldUpdateStats {
            lastStatsTime = now
        }
        guard image != nil || shouldUpdateStats else { return }

        let stageMillis = timings.snapshotMillis()
        let frameIndexSnapshot = frameIndex
        let virtualStatus = publisher.status.displayText
        #if DEBUG
        if now - lastPerfLogTime >= 5 {
            lastPerfLogTime = now
            let stages = stageMillis.map { "\($0.stage.rawValue)=\(String(format: "%.1f", $0.millis))" }.joined(separator: " ")
            let line = String(format: "SketchCamPerf fps=%.1f %@ landmarks=%d\n", fps, stages, settings.landmarks.enabled ? 1 : 0)
            // Sandboxed: lands in ~/Library/Containers/io.github.languel.sketchcam/Data/tmp/
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("sketchcam-perf-live.txt")
            let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (existing + line).write(to: url, atomically: true, encoding: .utf8)
        }
        #endif
        DispatchQueue.main.async {
            if let image {
                self.previewImage = image
            }
            if shouldUpdateStats {
                self.stats.outputFormat = outputFormat
                self.stats.fps = fps
                self.stats.frameIndex = frameIndexSnapshot
                self.stats.virtualCameraStatus = virtualStatus
                self.stats.stageMillis = stageMillis
                self.errorText = nil
            }
        }
    }

    private func publishError(_ error: Error) {
        DispatchQueue.main.async {
            self.errorText = error.localizedDescription
        }
    }

    private func nextFrameIndex() -> Int {
        frameIndex += 1
        return frameIndex
    }

    private var lastFPS: Double = 0

    private func updateFPS() -> Double {
        fpsFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsStartTime
        if elapsed >= 1 {
            lastFPS = Double(fpsFrameCount) / elapsed
            fpsStartTime = now
            fpsFrameCount = 0
        }
        return lastFPS
    }
}

extension SketchCamViewModel: @unchecked Sendable {}
