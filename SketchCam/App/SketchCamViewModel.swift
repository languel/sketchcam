import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import SketchCamCore
import SketchCamShared

final class SketchCamViewModel: ObservableObject {
    @Published var cameraDevices: [CameraDeviceOption] = []
    @Published var selectedDeviceID: String?
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
    // One CIContext for the whole pipeline (processor + preview): separate
    // contexts mean separate Metal queues/caches and extra GPU sync.
    private static let sharedCIContext = CIContext(options: [.cacheIntermediates: true])
    private let processor = CoreImageFrameProcessor(context: SketchCamViewModel.sharedCIContext)
    private let previewRenderer = PreviewRenderer(context: SketchCamViewModel.sharedCIContext)
    private let publisher = VirtualCameraFramePublisher()
    private let processingQueue = DispatchQueue(label: "io.github.languel.sketchcam.processing", qos: .userInitiated)
    private let timings = PipelineTimings()
    private let frameGate = NSLock()
    private var cameraFrameInFlight = false
    private var lastPreviewTime: CFAbsoluteTime = 0
    private var lastStatsTime: CFAbsoluteTime = 0
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
    }

    func start() {
        refreshDevices()
        startTestPatternTimer()
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
        process(pixelBuffer: pixelBuffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), originalPixelBuffer: pixelBuffer)
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
                let processed = try self.timings.measure(.process) {
                    try self.processor.process(
                        pixelBuffer: pixelBuffer,
                        settings: settings,
                        outputFormat: outputFormat,
                        frameIndex: self.nextFrameIndex(),
                        timestamp: timestamp
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
