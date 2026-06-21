import AppKit
import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import SketchCamCore
import SketchCamShared
import UniformTypeIdentifiers

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value
    init(_ value: Value) { storage = value }
    var value: Value {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}

/// Separate observable for the high-frequency preview image + debug stats, so
/// updating them (~4 Hz) only invalidates the small views that read them, not
/// the whole control panel. See `SketchCamViewModel.live`.
final class LiveReadouts: ObservableObject {
    @Published var previewImage: CGImage?
    @Published var stats = DebugStats()
}

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
    /// High-frequency live readouts (preview image + per-stage stats) live on a
    /// SEPARATE observable so their ~4 Hz updates don't fire the view model's
    /// objectWillChange and re-evaluate the entire ContentView body (which leaks
    /// SwiftUI Picker tag projections / Observation registrars on every pass).
    /// Only the small views that show them observe this store.
    let live = LiveReadouts()
    let exporter = OutputStreamExporter()
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
    /// v2 GPU layer compositor (experimental; behind settings.useGPUCompositor).
    private let gpuCompositor = MetalLayerCompositor(ciContext: SketchCamViewModel.sharedCIContext)
    private let previewRenderer = PreviewRenderer(context: SketchCamViewModel.sharedCIContext)
    /// Zero-readback display path (the preview pane / presentation output).
    let previewDisplay = SampleBufferDisplayController()
    private let landmarkService = LandmarkDetectionService(context: SketchCamViewModel.sharedCIContext)
    private let overlayCompositor = LandmarkOverlayCompositor()
    private let inkCompositor = InkLayerCompositor()
    private let acrylicCompositor = AcrylicLayerCompositor()
    private let controlFieldCoordinator = ControlFieldCoordinator()
    private let paperRenderer = MetalPaperRenderer.shared
    /// Live in-progress ink stroke, handed to the engine off the @Published
    /// settings path so drawing doesn't re-render the whole UI per mouse move.
    let inkLiveStroke = InkLiveStroke()
    private let canvasActions = CanvasActionHistory()
    private let performanceEvents = PerformanceEventLog()
    @Published private(set) var canvasHistoryRevision = 0
    private let webController = WebLayerController()
    private var lastWebSettings: WebLayerSettings?
    private var lastWebOutputSize: CGSize = .zero
    private var webPickedURLs: [URL] = []   // retained to keep sandbox grants alive
    private let segmentationService = SegmentationService()
    private let publisher = VirtualCameraFramePublisher()
    private let processingQueue = DispatchQueue(label: "io.github.languel.sketchcam.processing", qos: .userInitiated)
    private let timings = PipelineTimings()
    private let frameGate = NSLock()
    private var cameraFrameInFlight = false
    private let sourceFrameLock = NSLock()
    private var activeFrameSource = FrameSource.camera
    private var latestCameraFrame: CVPixelBuffer?
    private var latestMovieFrame: CVPixelBuffer?
    /// Keeps the OS from throttling us (App Nap / timer coalescing / QoS
    /// clamping) while live — the closest real lever to Apple's "Game Mode"
    /// for a non-fullscreen app. Held for the capture session's lifetime.
    private var realtimeActivity: NSObjectProtocol?
    private let frozenLock = NSLock()
    private var frozenFrame: CVPixelBuffer?
    private let exportLock = NSLock()
    private var lastPublishedFrame: CVPixelBuffer?
    private var lastOriginalPublishedFrame: CVPixelBuffer?
    private let nrtQueue = DispatchQueue(label: "io.github.languel.sketchcam.nrt", qos: .userInitiated)
    private var movieRateBeforePause: Double = 1
    private var lastPreviewTime: CFAbsoluteTime = 0
    private var lastStatsTime: CFAbsoluteTime = 0
    private var lastPerfLogTime: CFAbsoluteTime = 0
    #if DEBUG
    private var perfLogHandle: FileHandle?
    private var perfLogOpened = false
    #endif
    private var frameIndex = 0
    private var fpsStartTime = CFAbsoluteTimeGetCurrent()
    private var fpsFrameCount = 0
    private var testPatternTimer: DispatchSourceTimer?
    private var activeExportStroke: (id: UUID, mode: InkBrushMode, samples: Int)?

    /// Preview readback cadence; publishing runs at full frame rate regardless.
    private let statsInterval: CFAbsoluteTime = 0.25

    init() {
        gpuCompositor?.metricTap = { [weak exporter] layerID, buffer in
            exporter?.updateStreamMetrics(layerID: layerID, pixelBuffer: buffer)
        }
        captureService.onConfigurationChanged = { [weak self] size in
            DispatchQueue.main.async {
                self?.live.stats.cameraResolution = size
            }
        }
        captureService.onSampleBuffer = { [weak self] sampleBuffer in
            self?.handleCameraSample(sampleBuffer)
        }
        movieSource.onPixelBuffer = { [weak self] pixelBuffer in
            self?.handleMovieFrame(pixelBuffer)
        }
        exporter.onAcceptedFrame = { [weak self] _ in
            guard let self, self.frameSource == .movie else { return }
            let config = self.exporter.configuration
            let seconds = config.sourceAdvanceSeconds + Double(config.sourceAdvanceFrames) / 30.0
            if seconds > 0 { self.movieSource.step(seconds: seconds, loop: config.loopSource) }
        }
        exporter.onNRTRequested = { [weak self] configuration in
            self?.beginNRT(configuration)
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
        sourceFrameLock.withLock {
            activeFrameSource = frameSource
            if movieURL == nil {
                latestMovieFrame = nil
            }
        }
        if cameraPermissionState == .authorized {
            captureService.start(deviceID: selectedDeviceID, inputResolution: inputResolution)
        }
        if let movieURL {
            if movieSource.currentURL != movieURL || !movieSource.isPlaying {
                movieSource.play(url: movieURL, rate: Float(movieRate))
            } else {
                movieSource.setRate(Float(movieRate))
            }
        } else {
            movieSource.stop()
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

    /// Export the most recently published frame using the Export panel's still settings.
    func exportCurrentFrame() {
        let frame = exportLock.withLock { lastPublishedFrame }
        guard let frame else {
            errorText = "No frame to export yet."
            return
        }
        let panel = NSSavePanel()
        let format = exporter.configuration.imageFormat
        panel.allowedContentTypes = [Self.contentType(for: format)]
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "sketchcam-\(stamp).\(format.fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exporter.exportCurrent(frame, to: url)
    }

    func chooseExportDestination() {
        let config = exporter.configuration
        if config.outputKind == .imageSequence {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false; panel.canChooseDirectories = true
            panel.canCreateDirectories = true; panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            if panel.runModal() == .OK { exporter.destinationURL = panel.url }
            return
        }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        switch config.outputKind {
        case .still: panel.allowedContentTypes = [Self.contentType(for: config.imageFormat)]
        case .gif: panel.allowedContentTypes = [.gif]
        case .movie: panel.allowedContentTypes = [config.container == .mp4 ? .mpeg4Movie : .quickTimeMovie]
        case .imageSequence: break
        }
        panel.nameFieldStringValue = config.takeName + "." + exportExtension(config)
        if panel.runModal() == .OK { exporter.destinationURL = panel.url }
    }

    private func exportExtension(_ config: ExportConfiguration) -> String {
        switch config.outputKind {
        case .still: config.imageFormat.fileExtension
        case .imageSequence: ""
        case .gif: "gif"
        case .movie: config.container.rawValue
        }
    }

    private static func contentType(for format: ExportImageFormat) -> UTType {
        switch format {
        case .png: .png
        case .tiff: .tiff
        case .jpeg: .jpeg
        case .heif: .heic
        }
    }

    private func beginNRT(_ configuration: ExportConfiguration) {
        let source = exportLock.withLock {
            configuration.renderMode == .nrtContinue ? lastPublishedFrame : (lastOriginalPublishedFrame ?? lastPublishedFrame)
        }
        guard let source else {
            exporter.stop(cancelled: true)
            errorText = "No source frame is available for offline rendering."
            return
        }
        let sourceCopy = Self.copyPixelBuffer(source, context: Self.sharedCIContext) ?? source
        let settings = settings
        let events = performanceEvents.snapshot()
        let deterministicMovieURL = frameSource == .movie ? movieURL : nil
        nrtQueue.async { [weak self] in
            self?.renderNRT(source: sourceCopy, movieURL: deterministicMovieURL,
                            settings: settings, events: events, configuration: configuration)
        }
    }

    private func renderNRT(source: CVPixelBuffer, movieURL: URL?, settings: ProcessingSettings,
                           events: [PerformanceEvent], configuration: ExportConfiguration) {
        let format = FrameFormat(id: "export", width: configuration.width, height: configuration.height,
                                 frameRate: max(1, Int(configuration.playbackFPS.rounded())))
        let simulationStep = 1.0 / configuration.simulationFPS
        let scheduled = Self.schedule(events, configuration: configuration)
        let scheduledEnd = scheduled.last?.time ?? 0
        let duration: Double = {
            if configuration.maximumFrames > 0 { return Double(configuration.maximumFrames) / configuration.captureFPS }
            if configuration.maximumDuration > 0 { return configuration.maximumDuration }
            return max(1, scheduledEnd + 1)
        }()

        if configuration.renderMode == .nrtContinue {
            var t = 0.0, index = 0
            while t <= duration, exporter.isRecording {
                exporter.offerOfflineFrame(source, frameIndex: index, renderTime: t)
                if index.isMultiple(of: 10) { exporter.updateNRTProgress(t / max(duration, 0.001)) }
                index += 1; t += simulationStep
            }
            DispatchQueue.main.async { [weak self] in if self?.exporter.isRecording == true { self?.exporter.stop() } }
            return
        }

        let context = CIContext(options: [.cacheIntermediates: false])
        let processor = CoreImageFrameProcessor(context: context)
        let ink = InkLayerCompositor()
        let movieAsset = movieURL.map(AVURLAsset.init(url:))
        let movieGenerator: AVAssetImageGenerator? = movieAsset.map {
            let generator = AVAssetImageGenerator(asset: $0)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            return generator
        }
        let movieDuration = movieAsset.map(Self.loadedDuration) ?? 0
        var renderSettings = settings
        var paths: [InkEditorPath] = []
        var applied = 0, frame = 0, t = 0.0
        while t <= duration, exporter.isRecording {
            while applied < scheduled.count, scheduled[applied].time <= t + 0.000_001 {
                let event = scheduled[applied].event
                switch event.kind {
                case .pen, .wash:
                    if let path = event.path { paths.removeAll { $0.id == path.id }; paths.append(path) }
                case .undo:
                    if let id = event.actionID { paths.removeAll { $0.id == id } }
                case .redo:
                    if let id = event.actionID,
                       let path = events.first(where: { $0.actionID == id && $0.path != nil })?.path {
                        paths.removeAll { $0.id == id }; paths.append(path)
                    }
                case .clear: paths.removeAll()
                case .fix: renderSettings.landmarks.inkFixRevision = (renderSettings.landmarks.inkFixRevision ?? 0) + 1
                case .unfix: renderSettings.landmarks.inkUnfixRevision = (renderSettings.landmarks.inkUnfixRevision ?? 0) + 1
                case .wetCanvas: renderSettings.landmarks.inkWetCanvasRevision = (renderSettings.landmarks.inkWetCanvasRevision ?? 0) + 1
                case .dryCanvas: renderSettings.landmarks.inkDryCanvasRevision = (renderSettings.landmarks.inkDryCanvasRevision ?? 0) + 1
                }
                applied += 1
            }
            let inkImage = ink.layer(settings: renderSettings, live: nil, livePoints: [], endedLiveID: nil,
                                     outputSize: format.size, frameIndex: frame, actionPaths: paths)
            do {
                let frameSource = Self.movieFrame(
                    generator: movieGenerator, fallback: source, time: t,
                    duration: movieDuration, loop: configuration.loopSource, context: context
                )
                let result = try processor.process(
                    pixelBuffer: frameSource, settings: renderSettings, outputFormat: format,
                    frameIndex: frame, timestamp: CMTime(seconds: t, preferredTimescale: 600_000),
                    overlay: nil, matte: nil, webLayer: nil, inkLayer: inkImage,
                    webAboveDrawing: renderSettings.web.placement == .aboveDrawing
                )
                exporter.offerOfflineFrame(result.pixelBuffer, frameIndex: frame, renderTime: t)
                if frame.isMultiple(of: 10) { exporter.updateNRTProgress(t / max(duration, 0.001)) }
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.errorText = "NRT render failed: \(error.localizedDescription)"
                    self?.exporter.stop(cancelled: true)
                }
                return
            }
            frame += 1; t += simulationStep
        }
        DispatchQueue.main.async { [weak self] in if self?.exporter.isRecording == true { self?.exporter.stop() } }
    }

    private static func schedule(_ events: [PerformanceEvent], configuration: ExportConfiguration)
        -> [(time: Double, event: PerformanceEvent)] {
        var cursor = 0.0
        return events.map { event in
            let duration = max(0, event.endedAt - event.startedAt) / configuration.replaySpeed
            let time: Double
            switch configuration.replayTiming {
            case .original: time = event.endedAt / configuration.replaySpeed
            case .removeIdleGaps: cursor += duration; time = cursor
            case .fixedGap: cursor += duration + configuration.fixedReplayGap; time = cursor
            }
            return (time, event)
        }
    }

    private static func copyPixelBuffer(_ source: CVPixelBuffer, context: CIContext) -> CVPixelBuffer? {
        var copy: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                            CVPixelBufferGetPixelFormatType(source),
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &copy)
        if let copy { context.render(CIImage(cvPixelBuffer: source), to: copy) }
        return copy
    }

    private static func movieFrame(generator: AVAssetImageGenerator?, fallback: CVPixelBuffer,
                                   time: Double, duration: Double, loop: Bool,
                                   context: CIContext) -> CVPixelBuffer {
        guard let generator, duration.isFinite, duration > 0 else { return fallback }
        let seconds = loop ? time.truncatingRemainder(dividingBy: duration) : min(time, duration)
        guard let image = generateCGImage(
            generator, at: CMTime(seconds: max(0, seconds), preferredTimescale: 600_000)
        ) else { return fallback }
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { return fallback }
        context.render(CIImage(cgImage: image), to: buffer)
        return buffer
    }

    private static func loadedDuration(_ asset: AVAsset) -> Double {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedBox<Double>(0)
        Task {
            if let duration = try? await asset.load(.duration) { box.value = duration.seconds }
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private static func generateCGImage(_ generator: AVAssetImageGenerator, at time: CMTime) -> CGImage? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = LockedBox<CGImage?>(nil)
        generator.generateCGImageAsynchronously(for: time) { image, _, _ in
            box.value = image
            semaphore.signal()
        }
        semaphore.wait()
        return box.value
    }

    private func handleMovieFrame(_ pixelBuffer: CVPixelBuffer) {
        let shouldProcess = sourceFrameLock.withLock {
            latestMovieFrame = pixelBuffer
            return activeFrameSource == .movie
        }
        guard shouldProcess else { return }
        guard beginCameraFrame() else { return }
        let effective = effectiveInputFrame(pixelBuffer)
        process(
            pixelBuffer: effective,
            timestamp: CMClockGetTime(CMClockGetHostTimeClock()),
            originalPixelBuffer: effective,
            clockSource: .movie
        )
    }

    // MARK: - Ink live stroke (main thread → engine, off the settings path)

    func updateInkLiveStroke(_ sample: InkLiveStrokeSample) {
        if activeExportStroke?.id != sample.id {
            activeExportStroke = (sample.id, sample.brushMode, 1)
            exporter.signal(sample.brushMode == .pen ? .drawBegin : .washBegin)
        }
        else { activeExportStroke?.samples += 1 }
        inkLiveStroke.update(sample)
    }
    func endInkLiveStroke() {
        if let activeExportStroke {
            exporter.signal(activeExportStroke.mode == .pen ? .drawEnd : .washEnd)
        }
        activeExportStroke = nil
        inkLiveStroke.end()
    }
    func cancelInkLiveStroke() { inkLiveStroke.cancel() }

    func commitImmediateCanvasStroke(_ path: InkEditorPath) {
        canvasActions.commitImmediate(path)
        canvasHistoryRevision &+= 1
        performanceEvents.append(kind: (path.brushMode ?? .pen) == .pen ? .pen : .wash, path: path)
        exporter.signal(.anyCanvasAction, actionID: path.id)
    }

    func replaceEditableCanvasPaths(_ paths: [InkEditorPath]) {
        performanceEvents.migrateIfEmpty(paths)
        canvasActions.replaceEditablePaths(paths)
        canvasHistoryRevision &+= 1
    }

    var canUndoCanvasAction: Bool { canvasActions.canUndo() }
    var canRedoCanvasAction: Bool { canvasActions.canRedo() }

    @discardableResult
    func undoCanvasAction() -> CanvasStrokeAction? {
        cancelInkLiveStroke()
        let action = canvasActions.undo()
        if action != nil { canvasHistoryRevision &+= 1 }
        if let action { performanceEvents.append(kind: .undo, actionID: action.id); exporter.signal(.anyCanvasAction, actionID: action.id) }
        return action
    }

    @discardableResult
    func redoCanvasAction() -> CanvasStrokeAction? {
        cancelInkLiveStroke()
        let action = canvasActions.redo()
        if action != nil { canvasHistoryRevision &+= 1 }
        if let action { performanceEvents.append(kind: .redo, actionID: action.id); exporter.signal(.anyCanvasAction, actionID: action.id) }
        return action
    }

    func clearCanvasActions() {
        cancelInkLiveStroke()
        canvasActions.clear()
        canvasHistoryRevision &+= 1
        performanceEvents.append(kind: .clear)
        exporter.signal(.anyCanvasAction)
    }

    func signalCanvasAction(path: InkEditorPath? = nil) {
        if let path {
            performanceEvents.append(kind: (path.brushMode ?? .pen) == .pen ? .pen : .wash, path: path)
        }
        exporter.signal(.anyCanvasAction, actionID: path?.id)
    }

    func recordPerformanceCommand(_ kind: PerformanceEventKind) {
        performanceEvents.append(kind: kind)
        exporter.signal(.anyCanvasAction)
    }

    func performanceEventSnapshot() -> [PerformanceEvent] { performanceEvents.snapshot() }

    // MARK: - Web layer controls (main thread)

    func webGoBack() { webController.goBack() }
    func webGoForward() { webController.goForward() }
    func webReload() { webController.reloadPage() }

    /// Pick a local HTML file (or a folder with index.html). Selecting via the
    /// panel grants the sandbox read access that a typed path lacks; we retain
    /// the URL to keep the grant alive for the session.
    func chooseWebFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an HTML file, or a folder containing index.html"
        panel.begin { [weak self] response in
            guard let self, response == .OK, var url = panel.url else { return }
            _ = url.startAccessingSecurityScopedResource()
            self.webPickedURLs.append(url)
            if url.hasDirectoryPath { url = url.appendingPathComponent("index.html") }
            self.settings.web.useSnippet = false
            self.settings.web.urlString = url.absoluteString
        }
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
        movieSource.stop()
        sourceFrameLock.withLock {
            latestCameraFrame = nil
            latestMovieFrame = nil
        }
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
        let shouldProcess = sourceFrameLock.withLock {
            latestCameraFrame = pixelBuffer
            return activeFrameSource == .camera
        }
        guard shouldProcess else { return }
        // Drop frames while one is in flight instead of queueing them up —
        // backlog on the processing queue turns into unbounded latency.
        guard beginCameraFrame() else { return }
        let effective = effectiveInputFrame(pixelBuffer)
        process(pixelBuffer: effective, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), originalPixelBuffer: effective, clockSource: .camera)
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

    private func sourceFrames(clockFrame: CVPixelBuffer, clockSource: FrameSource) -> (camera: CVPixelBuffer?, movie: CVPixelBuffer?) {
        sourceFrameLock.withLock {
            switch clockSource {
            case .camera:
                return (clockFrame, latestMovieFrame)
            case .movie:
                return (latestCameraFrame, clockFrame)
            }
        }
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

    private func process(pixelBuffer: CVPixelBuffer, timestamp: CMTime, originalPixelBuffer: CVPixelBuffer, clockSource: FrameSource) {
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
                // v2: a Person Key effect anywhere in the layer stack needs the matte.
                let personKeyWanted = settings.useGPUCompositor && Self.graphWantsPersonMatte(settings)
                var segSettings = settings.segmentation
                segSettings.enabled = settings.segmentation.enabled || contourWanted || personKeyWanted
                let rawMatte = self.segmentationService.currentMatte(
                    pixelBuffer: originalPixelBuffer,
                    settings: segSettings
                )
                let matte = (settings.segmentation.enabled || personKeyWanted) ? rawMatte : nil
                self.timings.record(.segment, seconds: self.segmentationService.lastSegmentMillis / 1_000)
                let landmarkDrawingWanted = settings.landmarks.enabled
                let detectionWanted = landmarkDrawingWanted
                let drawingDetection: LandmarkDetection? = {
                    guard detectionWanted else { return nil }
                    var detection = self.landmarkService.currentDetection(
                        pixelBuffer: originalPixelBuffer,
                        settings: settings,
                        frameIndex: frameIndex
                    )
                    if landmarkDrawingWanted, contourWanted, let contour = self.segmentationService.currentContour(maxPerSecond: settings.landmarks.detectionsPerSecond, detail: settings.landmarks.contourDetail) {
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
                    if landmarkDrawingWanted, settings.landmarks.trackBodyHull, var d = detection, let hull = Self.makeHullGroup(from: d.groups) {
                        d.groups.append(hull)
                        detection = d
                    }
                    return detection
                }()
                let overlay: CIImage? = {
                    guard settings.landmarks.enabled else { return nil }
                    return self.overlayCompositor.overlay(
                        detection: drawingDetection,
                        settings: settings,
                        outputSize: outputFormat.size
                    )
                }()
                let graph = (settings.layerGraph ?? .defaultGraph(from: settings)).reconciled(with: settings)
                let inkTexture = self.routedInkTexture(
                    graph: graph,
                    settings: settings,
                    outputFormat: outputFormat,
                    pixelBuffer: pixelBuffer,
                    clockSource: clockSource,
                    frameIndex: frameIndex,
                    matte: matte,
                    overlay: overlay,
                    webLayer: webLayer
                )
                let controlSources = self.sourceFrames(clockFrame: pixelBuffer, clockSource: clockSource)
                let inkTextureBuffer = Self.controlGraphNeedsInkTexture(settings.resolvedControlFields)
                    ? self.pixelBuffer(from: inkTexture, outputFormat: outputFormat)
                    : nil
                let controlFields = self.timings.measure(.controlFields) {
                    self.controlFieldCoordinator?.update(
                        graph: settings.resolvedControlFields,
                        context: ControlFieldFrameContext(
                            frameIndex: frameIndex,
                            timestamp: timestamp,
                            outputSize: outputFormat.size,
                            cameraPixelBuffer: controlSources.camera,
                            moviePixelBuffer: controlSources.movie,
                            inkTexturePixelBuffer: inkTextureBuffer,
                            detection: drawingDetection,
                            settings: settings
                        )
                    ) ?? .empty
                }
                if let coordinator = self.controlFieldCoordinator {
                    self.timings.record(.motion, seconds: coordinator.lastMotionSeconds)
                    self.timings.record(.paperFields, seconds: coordinator.lastPaperSeconds)
                }
                // The inkwash engine runs synchronously (Metal commit +
                // waitUntilCompleted + CPU readback) inline on this queue, so
                // measure it as its own stage; otherwise its cost only showed
                // up buried in "Frame total".
                let liveInk = self.inkLiveStroke.consume()
                let inkLayer = self.timings.measure(.ink) {
                    self.inkCompositor.layer(
                        settings: settings,
                        live: liveInk.sample,
                        livePoints: liveInk.points,
                        endedLiveID: liveInk.ended,
                        outputSize: outputFormat.size,
                        frameIndex: frameIndex,
                        textureInput: inkTexture,
                        actionPaths: self.canvasActions.replayPaths(),
                        controlFields: controlFields
                    )
                }
                let inkActivity = self.inkCompositor.activitySnapshot
                self.exporter.updateInkActivity(
                    solverActive: inkActivity.solverActive,
                    change: inkActivity.physicalChange
                )
                // Overlay renders async; report the latest render duration
                // (like detect/segment), not the ~0ms cache fetch.
                self.timings.record(.overlay, seconds: self.overlayCompositor.lastRenderMillis / 1_000)
                self.timings.record(.detect, seconds: self.landmarkService.lastDetectionMillis / 1_000)
                let processed = try self.timings.measure(.process) { () throws -> ProcessedFrame in
                    if settings.useGPUCompositor, let gpu = self.gpuCompositor,
                       let frame = self.compositeOnGPU(
                            gpu, pixelBuffer: pixelBuffer, settings: settings,
                            outputFormat: outputFormat, frameIndex: frameIndex, timestamp: timestamp,
                            overlay: overlay, matte: matte, webLayer: webLayer, inkLayer: inkLayer,
                            clockSource: clockSource) {
                        return frame
                    }
                    return try self.processor.process(
                        pixelBuffer: pixelBuffer,
                        settings: settings,
                        outputFormat: outputFormat,
                        frameIndex: frameIndex,
                        timestamp: timestamp,
                        overlay: overlay,
                        matte: matte,
                        webLayer: webLayer,
                        inkLayer: inkLayer,
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

    /// True when the reconciled layer graph contains an enabled Person Key effect
    /// or mask (so segmentation must run to supply the matte).
    private static func graphWantsPersonMatte(_ settings: ProcessingSettings) -> Bool {
        let graph = (settings.layerGraph ?? .defaultGraph(from: settings)).reconciled(with: settings)
        return graph.layers.contains { layer in
            layer.visible &&
            (layer.effects.contains { $0.enabled && $0.kind.needsPersonMatte } ||
             layer.mask?.source == .source(.personMatte))
        }
    }

    private static func controlGraphNeedsInkTexture(_ graph: ControlFieldGraph) -> Bool {
        graph.providers.contains {
            $0.enabled && $0.resolvedMotionConfig.enabled && $0.resolvedMotionConfig.input == .inkTexture
        }
    }

    private func pixelBuffer(from image: CIImage?, outputFormat: FrameFormat) -> CVPixelBuffer? {
        guard let image,
              let buffer = try? PixelBufferUtils.makePixelBuffer(format: outputFormat) else { return nil }
        let bounds = CGRect(origin: .zero, size: outputFormat.size)
        Self.sharedCIContext.render(image, to: buffer, bounds: bounds, colorSpace: nil)
        return buffer
    }

    private func routedInkTexture(graph: LayerGraph, settings: ProcessingSettings, outputFormat: FrameFormat,
                                  pixelBuffer: CVPixelBuffer, clockSource: FrameSource, frameIndex: Int, matte: CIImage?,
                                  overlay: CIImage?, webLayer: CIImage?) -> CIImage? {
        guard let inkNode = graph.nodes.first(where: { $0.kind.family == "ink" }),
              let textureIndex = inkNode.kind.ports.firstIndex(where: { $0.name == "texture" }),
              inkNode.inputs.indices.contains(textureIndex) else { return nil }
        let binding = inkNode.inputs[textureIndex]
        guard binding != .none else { return nil }

        let outputRect = CGRect(origin: .zero, size: outputFormat.size)
        let sourceFrames = sourceFrames(clockFrame: pixelBuffer, clockSource: clockSource)
        let srcW = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), srcH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let cameraImage = sourceFrames.camera.map {
            CoreImageFrameProcessor.aspectFill(CIImage(cvPixelBuffer: $0), in: outputRect, mirrored: settings.mirror)
        }
        let movieImage = sourceFrames.movie.map {
            CoreImageFrameProcessor.aspectFill(CIImage(cvPixelBuffer: $0), in: outputRect, mirrored: settings.mirror)
        }
        let personMatteImage: CIImage? = matte.map { m in
            let inSrc = m.transformed(by: CGAffineTransform(
                scaleX: srcW / max(1, m.extent.width), y: srcH / max(1, m.extent.height)))
            return CoreImageFrameProcessor.aspectFill(inSrc, in: outputRect, mirrored: settings.mirror)
        }

        func nodeImage(_ node: Node) -> CIImage? {
            switch node.kind {
            case .video:
                return cameraImage
            case .movie:
                return movieImage
            case .solid(let cfg):
                return CIImage(color: CIColor(red: CGFloat(cfg.color.red), green: CGFloat(cfg.color.green),
                                              blue: CGFloat(cfg.color.blue), alpha: CGFloat(cfg.color.alpha))).cropped(to: outputRect)
            case .paper(let config):
                return self.paperRenderer?.image(config: config, rect: outputRect)
            case .personMatte:
                return personMatteImage
            case .overlay, .marks, .drawing:
                return overlay
            case .web:
                return webLayer
            case .acrylic(let config):
                return self.acrylicCompositor.layer(nodeID: node.id, config: config, outputSize: outputFormat.size)
            case .ink, .effect:
                return nil
            }
        }

        switch binding {
        case .none:
            return nil
        case .source(let source):
            switch source {
            case .camera:
                return cameraImage
            case .personMatte:
                return personMatteImage
            case .landmarks, .mouse:
                return nil
            }
        case .node(let id):
            guard let node = graph.node(id) else { return nil }
            let streams = MetalLayerCompositor.Streams(image: nodeImage, personMatte: personMatteImage)
            return gpuCompositor?.layerOutput(
                nodeID: id,
                graph: graph,
                streams: streams,
                outputFormat: outputFormat,
                frameIndex: frameIndex
            ) ?? nodeImage(node)
        }
    }

    /// Build the per-stream images and composite the graph on the GPU. Returns
    /// nil on any failure so the caller falls back to the CoreImage path.
    private func compositeOnGPU(_ gpu: MetalLayerCompositor, pixelBuffer: CVPixelBuffer,
                                settings: ProcessingSettings, outputFormat: FrameFormat,
                                frameIndex: Int, timestamp: CMTime,
                                overlay: CIImage?, matte: CIImage?, webLayer: CIImage?, inkLayer: CIImage?,
                                clockSource: FrameSource) -> ProcessedFrame? {
        let outputRect = CGRect(origin: .zero, size: outputFormat.size)
        let sourceFrames = sourceFrames(clockFrame: pixelBuffer, clockSource: clockSource)
        let cameraImage: CIImage? = sourceFrames.camera.map {
            CoreImageFrameProcessor.aspectFill(CIImage(cvPixelBuffer: $0), in: outputRect, mirrored: settings.mirror)
        }
        let movieImage: CIImage? = sourceFrames.movie.map {
            CoreImageFrameProcessor.aspectFill(CIImage(cvPixelBuffer: $0), in: outputRect, mirrored: settings.mirror)
        }
        let srcW = CGFloat(CVPixelBufferGetWidth(pixelBuffer)), srcH = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        // Person matte scaled into output space (matches the legacy keyer).
        let personMatteImage: CIImage? = matte.map { m in
            let inSrc = m.transformed(by: CGAffineTransform(
                scaleX: srcW / max(1, m.extent.width), y: srcH / max(1, m.extent.height)))
            return CoreImageFrameProcessor.aspectFill(inSrc, in: outputRect, mirrored: settings.mirror)
        }

        let graph = (settings.layerGraph ?? .defaultGraph(from: settings)).reconciled(with: settings)
        let streams = MetalLayerCompositor.Streams(
            image: { node in
                switch node.kind {
                case .video:
                    return cameraImage   // v2: camera is always a layer (hide it with the eye)
                case .movie:
                    return movieImage
                case .solid(let cfg):
                    return CIImage(color: CIColor(red: CGFloat(cfg.color.red), green: CGFloat(cfg.color.green),
                                                  blue: CGFloat(cfg.color.blue), alpha: CGFloat(cfg.color.alpha))).cropped(to: outputRect)
                case .paper(let config):
                    return self.paperRenderer?.image(config: config, rect: outputRect)
                case .personMatte:
                    return personMatteImage
                case .overlay, .marks, .drawing:
                    return overlay
                case .ink:
                    return inkLayer
                case .acrylic(let config):
                    return self.acrylicCompositor.layer(nodeID: node.id, config: config, outputSize: outputFormat.size)
                case .web:
                    return webLayer
                case .effect:
                    return nil
                }
            },
            personMatte: personMatteImage
        )
        return gpu.composite(graph: graph, streams: streams, outputFormat: outputFormat,
                             frameIndex: frameIndex, timestamp: timestamp, mirror: settings.mirror)
    }

    private func publish(frame pixelBuffer: CVPixelBuffer, sampleBuffer: CMSampleBuffer, originalPixelBuffer: CVPixelBuffer) {
        let settings = store.settings
        let outputFormat = store.outputFormat

        timings.measure(.publish) {
            publisher.publish(sampleBuffer)
        }
        exportLock.withLock {
            lastPublishedFrame = pixelBuffer
            lastOriginalPublishedFrame = originalPixelBuffer
        }
        exporter.offerFrame(pixelBuffer, frameIndex: frameIndex)
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
            // Append via a held FileHandle (O(1)), truncating once at session start —
            // the old read-whole-file + rewrite was O(n) per tick and grew the file
            // unbounded across sessions.
            if !perfLogOpened {
                perfLogOpened = true
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("sketchcam-perf-live.txt")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                perfLogHandle = try? FileHandle(forWritingTo: url)
            }
            if let data = line.data(using: .utf8) {
                try? perfLogHandle?.write(contentsOf: data)
            }
        }
        #endif
        DispatchQueue.main.async {
            if let displayBuffer {
                self.previewDisplay.enqueue(displayBuffer)
            }
            if let image {
                self.live.previewImage = image
            }
            if shouldUpdateStats {
                self.live.stats.outputFormat = outputFormat
                self.live.stats.fps = fps
                self.live.stats.frameIndex = frameIndexSnapshot
                self.live.stats.virtualCameraStatus = virtualStatus
                self.live.stats.stageMillis = stageMillis
                // Only clear the error when there actually is one — assigning nil
                // every tick would fire the view model's objectWillChange at 4 Hz.
                if self.errorText != nil { self.errorText = nil }
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
