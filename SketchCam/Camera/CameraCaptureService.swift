import AVFoundation
import CoreMedia
import Foundation

/// Camera capture resolution. Capturing more pixels than the pipeline needs
/// costs ISP bandwidth, memory traffic, and per-frame conversion — VGA is the
/// default for the doodle pipeline; effects upscale fine.
enum CameraInputResolution: String, CaseIterable, Identifiable {
    case low
    case vga
    case hd
    case high

    var id: String { rawValue }

    var title: String {
        switch self {
        case .low: return "Low (352)"
        case .vga: return "VGA (640)"
        case .hd: return "720p"
        case .high: return "Native"
        }
    }

    var targetDimensions: CMVideoDimensions? {
        switch self {
        case .low:
            return CMVideoDimensions(width: 352, height: 288)
        case .vga:
            return CMVideoDimensions(width: 640, height: 480)
        case .hd:
            return CMVideoDimensions(width: 1280, height: 720)
        case .high:
            return nil
        }
    }

    var presetCandidates: [AVCaptureSession.Preset] {
        switch self {
        case .low:
            return [.low, .cif352x288]
        case .vga:
            return [.vga640x480, .medium]
        case .hd:
            return [.hd1280x720, .medium]
        case .high:
            return [.high]
        }
    }
}

final class CameraCaptureService: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onConfigurationChanged: ((CGSize) -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "io.github.languel.sketchcam.camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let outputQueue = DispatchQueue(label: "io.github.languel.sketchcam.camera.output", qos: .userInitiated)
    private(set) var isRunning = false

    func availableDevices() -> [CameraDeviceOption] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices
            .map { CameraDeviceOption(id: $0.uniqueID, name: $0.localizedName) }
            .filter { !$0.isSketchCamOutput }
    }

    func start(deviceID: String?, inputResolution: CameraInputResolution = .vga) {
        sessionQueue.async {
            do {
                try self.configure(deviceID: deviceID, inputResolution: inputResolution)
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.isRunning = true
            } catch {
                self.isRunning = false
                NSLog("SketchCam camera start failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.isRunning = false
        }
    }

    private func configure(deviceID: String?, inputResolution: CameraInputResolution) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = inputResolution.presetCandidates.first(where: { session.canSetSessionPreset($0) }) ?? .medium
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        let device = try selectedDevice(deviceID: deviceID)
        configureCaptureFormat(on: device, inputResolution: inputResolution)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.cannotAddInput
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
        guard session.canAddOutput(videoOutput) else {
            throw CameraError.cannotAddOutput
        }
        session.addOutput(videoOutput)
        onConfigurationChanged?(CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription).cgSize)
    }

    private func configureCaptureFormat(on device: AVCaptureDevice, inputResolution: CameraInputResolution) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if let format = preferredFormat(for: device, inputResolution: inputResolution) {
                device.activeFormat = format
            }

            let frameDuration = CMTime(value: 1, timescale: 30)
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { range in
                range.minFrameRate <= 30 && range.maxFrameRate >= 30
            }) {
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            }
        } catch {
            NSLog("SketchCam could not configure camera format: \(error.localizedDescription)")
        }
    }

    private func preferredFormat(for device: AVCaptureDevice, inputResolution: CameraInputResolution) -> AVCaptureDevice.Format? {
        guard let target = inputResolution.targetDimensions else { return nil }
        let targetWidth = Int(target.width)
        let targetHeight = Int(target.height)
        return device.formats
            .filter { format in
                format.videoSupportedFrameRateRanges.contains { range in
                    range.minFrameRate <= 30 && range.maxFrameRate >= 30
                }
            }
            .min { lhs, rhs in
                formatScore(CMVideoFormatDescriptionGetDimensions(lhs.formatDescription), targetWidth: targetWidth, targetHeight: targetHeight)
                    < formatScore(CMVideoFormatDescriptionGetDimensions(rhs.formatDescription), targetWidth: targetWidth, targetHeight: targetHeight)
            }
    }

    private func formatScore(_ dimensions: CMVideoDimensions, targetWidth: Int, targetHeight: Int) -> Int {
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        let area = width * height
        let targetArea = targetWidth * targetHeight
        let areaPenalty = abs(area - targetArea)
        let widthPenalty = abs(width - targetWidth)
        let heightPenalty = abs(height - targetHeight)
        let oversizePenalty = area > targetArea ? area / 4 : 0
        return areaPenalty + widthPenalty * 8 + heightPenalty * 8 + oversizePenalty
    }

    private func selectedDevice(deviceID: String?) throws -> AVCaptureDevice {
        if let deviceID, let device = AVCaptureDevice(uniqueID: deviceID), !device.localizedName.localizedCaseInsensitiveContains("SketchCam") {
            return device
        }
        if let defaultDevice = AVCaptureDevice.default(for: .video), !defaultDevice.localizedName.localizedCaseInsensitiveContains("SketchCam") {
            return defaultDevice
        }
        if let first = availableDevices().first, let device = AVCaptureDevice(uniqueID: first.id) {
            return device
        }
        throw CameraError.noDevice
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        onSampleBuffer?(sampleBuffer)
    }
}

private enum CameraError: Error, LocalizedError {
    case noDevice
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "No usable camera device was found."
        case .cannotAddInput:
            return "Could not add the selected camera input."
        case .cannotAddOutput:
            return "Could not add the camera frame output."
        }
    }
}

private extension CMVideoDimensions {
    var cgSize: CGSize {
        CGSize(width: Int(width), height: Int(height))
    }
}

