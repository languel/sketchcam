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
    /// Zero-readback display path (the preview pane / presentation output).
    let previewDisplay = SampleBufferDisplayController()
    private let landmarkService = LandmarkDetectionService(context: SketchCamViewModel.sharedCIContext)
    private let overlayCompositor = LandmarkOverlayCompositor()
    private let webController = WebLayerController()
    private var lastWebSettings: WebLayerSettings?
    private var lastWebOutputSize: CGSize = .zero
    private let segmentationService = SegmentationService()
    private let publisher = VirtualCameraFramePublisher()
    private let processingQueue = DispatchQueue(label: "io.github.languel.sketchcam.processing", qos: .userInitiated)
    private let timings = PipelineTimings()
    private let frameGate = NSLock()
    private var cameraFrameInFlight = false
    /// Keeps the OS from throttling us (App Nap / timer coalescing / QoS
    /// clamping) while live — the closest real lever to Apple's "Game Mode"
    /// for a non-fullscreen app. Held for the capture session's lifetime.
    private var realtimeActivity: NSObjectProtocol?
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

    /// Loads the bundled public-domain test clip (Chaplin) — a moving figure for
    /// detection/drawing tests without a person in front of the camera.
    func loadDemoClip() {
        guard let url = Bundle.main.url(forResource: "chaplin-dance", withExtension: "mp4") else {
            errorText = "Demo clip not found in app bundle."
            return
        }
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
        webController.onInteractiveClosed = { [weak self] in
            self?.settings.web.interactive = false
        }
        if realtimeActivity == nil {
            realtimeActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical],
                reason: "Real-time camera processing"
            )
        }
        refreshDevices()
        startTestPatternTimer()
        // Dev affordance: SKETCHCAM_LANDMARKS=camera|synthetic env var enables
        // the overlay at launch (headless perf verification only). The old
        // UserDefaults variant was removed: it persisted invisibly across
        // launches and caused a "slow with everything off" mystery.
        if let mode = ProcessInfo.processInfo.environment["SKETCHCAM_LANDMARKS"], !mode.isEmpty {
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
        if let realtimeActivity {
            ProcessInfo.processInfo.endActivity(realtimeActivity)
            self.realtimeActivity = nil
        }
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

    /// Convex hull of all detected landmark points (excluding silhouette/hull
    /// groups) → a seg-free person outline group.
    private static func makeHullGroup(from groups: [LandmarkGroup]) -> LandmarkGroup? {
        let points = groups
            .filter { $0.region != .contour && $0.region != .bodyHull }
            .flatMap { $0.points.map(\.point) }
        guard points.count >= 3 else { return nil }
        let hull = BodyHull.convexHull(points)
        guard hull.count >= 3 else { return nil }
        let landmarkPoints = hull.enumerated().map { LandmarkPoint(point: $1, confidence: 1, label: "h\($0)") }
        var edges = (0..<(hull.count - 1)).map { ($0, $0 + 1) }
        edges.append((hull.count - 1, 0))
        return LandmarkGroup(region: .bodyHull, points: landmarkPoints, edges: edges)
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
            // Web layer: push config changes to the (main-thread) web view only
            // when they change; the snapshot is read back below thread-safely.
            if settings.web != self.lastWebSettings || outputFormat.size != self.lastWebOutputSize {
                self.lastWebSettings = settings.web
                self.lastWebOutputSize = outputFormat.size
                let web = settings.web
                let size = outputFormat.size
                DispatchQueue.main.async { self.webController.update(settings: web, outputSize: size) }
            }
            let webLayer = settings.web.enabled ? self.webController.currentImage() : nil
            do {
                let frameIndex = self.nextFrameIndex()
                // Segmentation runs when keying OR the silhouette contour
                // needs it; the processor only keys when keying is on.
                let contourWanted = settings.landmarks.enabled && settings.landmarks.trackContour
                var segSettings = settings.segmentation
                segSettings.enabled = settings.segmentation.enabled || contourWanted
                let rawMatte = self.segmentationService.currentMatte(
                    pixelBuffer: originalPixelBuffer,
                    settings: segSettings
                )
                let matte = settings.segmentation.enabled ? rawMatte : nil
                self.timings.record(.segment, seconds: self.segmentationService.lastSegmentMillis / 1_000)
                let overlay: CIImage? = {
                    guard settings.landmarks.enabled else { return nil }
                    var detection = self.landmarkService.currentDetection(
                        pixelBuffer: originalPixelBuffer,
                        settings: settings,
                        frameIndex: frameIndex
                    )
                    if contourWanted, let contour = self.segmentationService.currentContour(maxPerSecond: settings.landmarks.detectionsPerSecond, detail: settings.landmarks.contourDetail) {
                        var augmented = detection ?? LandmarkDetection(
                            groups: [],
                            detectionID: 0,
                            sourceSize: CGSize(
                                width: CVPixelBufferGetWidth(originalPixelBuffer),
                                height: CVPixelBufferGetHeight(originalPixelBuffer)
                            )
                        )
                        augmented.groups.append(contour.group)
                        augmented.detectionID = augmented.detectionID &+ (contour.version &* 0x10_0000)
                        detection = augmented
                    }
                    // Seg-free person outline: convex hull of the detected
                    // landmarks (no segmentation). Rides the detection's id so it
                    // tracks at frame rate with the rest when predictive.
                    if settings.landmarks.trackBodyHull, var d = detection, let hull = Self.makeHullGroup(from: d.groups) {
                        d.groups.append(hull)
                        detection = d
                    }
                    return self.overlayCompositor.overlay(
                        detection: detection,
                        settings: settings,
                        outputSize: outputFormat.size
                    )
                }()
                // Overlay renders async; report the latest render duration
                // (like detect/segment), not the ~0ms cache fetch.
                self.timings.record(.overlay, seconds: self.overlayCompositor.lastRenderMillis / 1_000)
                self.timings.record(.detect, seconds: self.landmarkService.lastDetectionMillis / 1_000)
                let processed = try self.timings.measure(.process) {
                    try self.processor.process(
                        pixelBuffer: pixelBuffer,
                        settings: settings,
                        outputFormat: outputFormat,
                        frameIndex: frameIndex,
                        timestamp: timestamp,
                        overlay: overlay,
                        matte: matte,
                        webLayer: webLayer,
                        webAboveDrawing: settings.web.placement == .aboveDrawing
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

        // Preview/display is decoupled from publishing: the virtual camera gets
        // every frame; the display refreshes at previewFPS (0 = full-tilt). The
        // Metal path enqueues the frame's CMSampleBuffer with zero readback; the
        // CGImage path is the fallback (and handles split mode).
        let now = CFAbsoluteTimeGetCurrent()
        let previewInterval: CFAbsoluteTime = settings.previewFPS > 0 ? 1.0 / settings.previewFPS : 0
        var image: CGImage?
        var displayBuffer: CVPixelBuffer?
        if settings.previewEnabled, now - lastPreviewTime >= previewInterval {
            lastPreviewTime = now
            if settings.useMetalPreview, settings.previewMode != .split {
                switch settings.previewMode {
                case .processed: displayBuffer = pixelBuffer
                case .original: displayBuffer = originalPixelBuffer
                case .split: break
                }
            } else {
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
        }

        let shouldUpdateStats = now - lastStatsTime >= statsInterval
        if shouldUpdateStats {
            lastStatsTime = now
        }
        guard image != nil || displayBuffer != nil || shouldUpdateStats else { return }

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
            if let displayBuffer {
                self.previewDisplay.enqueue(displayBuffer)
            }
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
