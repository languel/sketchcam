import AVFoundation
import CoreMedia
import Foundation

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

    func start(deviceID: String?) {
        sessionQueue.async {
            do {
                try self.configure(deviceID: deviceID)
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

    private func configure(deviceID: String?) throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .high
        for input in session.inputs {
            session.removeInput(input)
        }
        for output in session.outputs {
            session.removeOutput(output)
        }

        let device = try selectedDevice(deviceID: deviceID)
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

