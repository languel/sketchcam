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
    @Published var settings = ProcessingSettings()
    @Published var outputFormat = SketchCamFormats.defaultFormat
    @Published var previewImage: CGImage?
    @Published var stats = DebugStats()
    @Published var cameraPermissionState = CameraPermissionManager.state
    @Published var errorText: String?

    let activationManager = ExtensionActivationManager()

    private let captureService = CameraCaptureService()
    private let processor = CoreImageFrameProcessor()
    private let previewRenderer = PreviewRenderer()
    private let publisher = VirtualCameraFramePublisher()
    private let processingQueue = DispatchQueue(label: "io.github.languel.sketchcam.processing", qos: .userInitiated)
    private let timings = PipelineTimings()
    private var frameIndex = 0
    private var fpsStartTime = CFAbsoluteTimeGetCurrent()
    private var fpsFrameCount = 0
    private var testPatternTimer: DispatchSourceTimer?

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
                    self.captureService.start(deviceID: self.selectedDeviceID)
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
        captureService.start(deviceID: id)
    }

    func activateExtension() {
        activationManager.activate()
    }

    func deactivateExtension() {
        publisher.disconnect()
        activationManager.deactivate()
    }

    private func handleCameraSample(_ sampleBuffer: CMSampleBuffer) {
        guard !settingsSnapshot().testPatternMode,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            return
        }
        process(pixelBuffer: pixelBuffer, timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), originalPixelBuffer: pixelBuffer)
    }

    private func startTestPatternTimer() {
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0, leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let snapshot = self.settingsSnapshot()
            let permission = self.permissionSnapshot()
            guard snapshot.testPatternMode || permission != .authorized else { return }
            do {
                let format = self.outputFormatSnapshot()
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
            let frameStart = CFAbsoluteTimeGetCurrent()
            let (settings, outputFormat) = self.timings.measure(.snapshot) {
                (self.settingsSnapshot(), self.outputFormatSnapshot())
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
        let settings = settingsSnapshot()
        let outputFormat = outputFormatSnapshot()
        let image: CGImage? = timings.measure(.preview) {
            switch settings.previewMode {
            case .processed:
                return previewRenderer.makeImage(from: pixelBuffer)
            case .original:
                return previewRenderer.makeImage(from: originalPixelBuffer)
            case .split:
                return previewRenderer.makeSplitImage(original: originalPixelBuffer, processed: pixelBuffer, outputFormat: outputFormat)
            }
        }

        timings.measure(.publish) {
            publisher.publish(sampleBuffer)
        }
        let fps = updateFPS()
        let stageMillis = timings.snapshotMillis()
        DispatchQueue.main.async {
            self.previewImage = image
            self.stats.outputFormat = outputFormat
            self.stats.fps = fps
            self.stats.frameIndex = self.frameIndex
            self.stats.virtualCameraStatus = self.publisher.status.displayText
            self.stats.stageMillis = stageMillis
            self.errorText = nil
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

    private func updateFPS() -> Double {
        fpsFrameCount += 1
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - fpsStartTime
        if elapsed >= 1 {
            let fps = Double(fpsFrameCount) / elapsed
            fpsStartTime = now
            fpsFrameCount = 0
            return fps
        }
        return stats.fps
    }

    private func settingsSnapshot() -> ProcessingSettings {
        DispatchQueue.main.sync { settings }
    }

    private func outputFormatSnapshot() -> FrameFormat {
        DispatchQueue.main.sync { outputFormat }
    }

    private func permissionSnapshot() -> CameraPermissionState {
        DispatchQueue.main.sync { cameraPermissionState }
    }
}

extension SketchCamViewModel: @unchecked Sendable {}
