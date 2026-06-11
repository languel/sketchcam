import CoreMedia
import CoreMediaIO
import Foundation
import IOKit.audio
import os.log
import SketchCamShared

private let logger = Logger(subsystem: "io.github.languel.sketchcam.camera-extension", category: "provider")

final class SketchCamCameraDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!

    private let frameStore = LatestFrameStore()
    private let frameScaler = FrameScaler()
    private let timerQueue = DispatchQueue(label: "io.github.languel.sketchcam.camera-extension.timer", qos: .userInteractive)
    private let sinkQueue = DispatchQueue(label: "io.github.languel.sketchcam.camera-extension.sink", qos: .userInitiated)
    private var sourceStreamSource: SketchCamSourceStreamSource!
    private var sinkStreamSource: SketchCamSinkStreamSource!
    private var timer: DispatchSourceTimer?
    private var sourceStreamingCount: UInt32 = 0
    private var sinkStreaming = false
    private var sinkClients: [CMIOExtensionClient] = []
    private var frameIndex = 0

    init(localizedName: String) {
        super.init()
        let deviceID = UUID(uuidString: "7D7DCC2D-7060-4E1F-A71D-48271911641F")!
        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: deviceID, legacyDeviceID: nil, source: self)

        sourceStreamSource = SketchCamSourceStreamSource(
            localizedName: "SketchCam Video",
            streamID: UUID(uuidString: "986122D3-4B8D-42B5-8B0F-89422B66A33A")!,
            direction: .source,
            deviceSource: self
        )
        sinkStreamSource = SketchCamSinkStreamSource(
            localizedName: "SketchCam Input",
            streamID: UUID(uuidString: "55AA0DEB-6AF4-4853-BFF7-783534FC6620")!,
            direction: .sink,
            deviceSource: self
        )

        do {
            try device.addStream(sourceStreamSource.stream)
            try device.addStream(sinkStreamSource.stream)
        } catch {
            fatalError("Failed to add SketchCam streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            result.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            result.model = "SketchCam Virtual Camera"
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func startSourceStreaming() {
        sourceStreamingCount += 1
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: timerQueue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(activeFormat.frameRate), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in
            self?.sendNextFrame()
        }
        self.timer = timer
        timer.resume()
        logger.info("Started source stream")
    }

    func stopSourceStreaming() {
        if sourceStreamingCount > 1 {
            sourceStreamingCount -= 1
            return
        }
        sourceStreamingCount = 0
        timer?.cancel()
        timer = nil
        logger.info("Stopped source stream")
    }

    func registerSinkClient(_ client: CMIOExtensionClient) {
        if !sinkClients.contains(where: { $0 === client }) {
            sinkClients.append(client)
        }
    }

    func startSinkStreaming() {
        guard !sinkStreaming else { return }
        sinkStreaming = true
        for client in sinkClients {
            drainSink(client: client)
        }
        logger.info("Started sink stream")
    }

    func stopSinkStreaming() {
        sinkStreaming = false
        logger.info("Stopped sink stream")
    }

    func noteSinkDisconnected(_ client: CMIOExtensionClient) {
        sinkClients.removeAll { $0 === client }
    }

    var activeFormat: FrameFormat {
        sourceStreamSource.activeFormat
    }

    private func sendNextFrame() {
        do {
            let format = activeFormat
            let sampleBuffer: CMSampleBuffer
            if let latest = frameStore.latest(maxAge: 1.0) {
                // The host app's output resolution and the consumer-negotiated
                // stream format can differ (e.g. the user switches the app to
                // 720p while QuickTime negotiated 1080p) — rescale instead of
                // dropping to the fallback pattern.
                sampleBuffer = try frameScaler.scaleIfNeeded(latest, to: format)
            } else {
                sampleBuffer = try FallbackTestPatternGenerator.makeSampleBuffer(format: format, frameIndex: frameIndex)
            }
            frameIndex += 1
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            sourceStreamSource.stream.send(sampleBuffer, discontinuity: [], hostTimeInNanoseconds: PixelBufferUtils.hostTimeNanoseconds(for: time))
        } catch {
            logger.error("Could not send frame: \(error.localizedDescription)")
        }
    }

    private func drainSink(client: CMIOExtensionClient) {
        sinkQueue.async { [weak self] in
            guard let self, self.sinkStreaming else { return }
            self.sinkStreamSource.stream.consumeSampleBuffer(from: client) { sampleBuffer, sequenceNumber, _, hasMoreSampleBuffers, error in
                if let error {
                    logger.error("Sink consume failed: \(error.localizedDescription)")
                }
                if let sampleBuffer {
                    self.frameStore.update(sampleBuffer: sampleBuffer, sequenceNumber: sequenceNumber)
                    let scheduled = CMIOExtensionScheduledOutput(sequenceNumber: sequenceNumber, hostTimeInNanoseconds: PixelBufferUtils.hostTimeNanoseconds())
                    self.sinkStreamSource.stream.notifyScheduledOutputChanged(scheduled)
                }
                if hasMoreSampleBuffers {
                    self.drainSink(client: client)
                } else {
                    self.sinkQueue.asyncAfter(deadline: .now() + 0.002) {
                        self.drainSink(client: client)
                    }
                }
            }
        }
    }
}

final class SketchCamSourceStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormats: [CMIOExtensionStreamFormat]
    private weak var deviceSource: SketchCamCameraDeviceSource?
    private var activeFormatIndexValue = 2

    init(localizedName: String, streamID: UUID, direction: CMIOExtensionStream.Direction, deviceSource: SketchCamCameraDeviceSource) {
        self.deviceSource = deviceSource
        self.streamFormats = Self.makeStreamFormats()
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: direction, clockType: .hostTime, source: self)
    }

    var activeFormat: FrameFormat {
        SketchCamFormats.all[min(activeFormatIndexValue, SketchCamFormats.all.count - 1)]
    }

    var formats: [CMIOExtensionStreamFormat] {
        streamFormats
    }

    var activeFormatIndex: Int {
        get { activeFormatIndexValue }
        set { activeFormatIndexValue = min(max(0, newValue), streamFormats.count - 1) }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = activeFormat.frameDuration
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        true
    }

    func startStream() throws {
        deviceSource?.startSourceStreaming()
    }

    func stopStream() throws {
        deviceSource?.stopSourceStreaming()
    }

    fileprivate static func makeStreamFormats() -> [CMIOExtensionStreamFormat] {
        SketchCamFormats.all.compactMap { format in
            guard let description = try? PixelBufferUtils.makeFormatDescription(format: format) else {
                return nil
            }
            return CMIOExtensionStreamFormat(
                formatDescription: description,
                maxFrameDuration: format.frameDuration,
                minFrameDuration: format.frameDuration,
                validFrameDurations: nil
            )
        }
    }
}

final class SketchCamSinkStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let streamFormats: [CMIOExtensionStreamFormat]
    private weak var deviceSource: SketchCamCameraDeviceSource?
    private var activeFormatIndexValue = 2

    init(localizedName: String, streamID: UUID, direction: CMIOExtensionStream.Direction, deviceSource: SketchCamCameraDeviceSource) {
        self.deviceSource = deviceSource
        self.streamFormats = SketchCamSourceStreamSource.makeStreamFormats()
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID, direction: direction, clockType: .hostTime, source: self)
    }

    private var activeFormat: FrameFormat {
        SketchCamFormats.all[min(activeFormatIndexValue, SketchCamFormats.all.count - 1)]
    }

    var formats: [CMIOExtensionStreamFormat] {
        streamFormats
    }

    var activeFormatIndex: Int {
        get { activeFormatIndexValue }
        set { activeFormatIndexValue = min(max(0, newValue), streamFormats.count - 1) }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamSinkBufferQueueSize,
            .streamSinkBuffersRequiredForStartup,
            .streamSinkBufferUnderrunCount,
            .streamSinkEndOfData
        ]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = activeFormat.frameDuration
        }
        if properties.contains(.streamSinkBufferQueueSize) {
            result.sinkBufferQueueSize = 3
        }
        if properties.contains(.streamSinkBuffersRequiredForStartup) {
            result.sinkBuffersRequiredForStartup = 1
        }
        if properties.contains(.streamSinkBufferUnderrunCount) {
            result.sinkBufferUnderrunCount = 0
        }
        if properties.contains(.streamSinkEndOfData) {
            result.sinkEndOfData = 0
        }
        return result
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {
        if let activeFormatIndex = streamProperties.activeFormatIndex {
            self.activeFormatIndex = activeFormatIndex
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        deviceSource?.registerSinkClient(client)
        return true
    }

    func startStream() throws {
        deviceSource?.startSinkStreaming()
    }

    func stopStream() throws {
        deviceSource?.stopSinkStreaming()
    }
}

final class SketchCamCameraExtensionProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: SketchCamCameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = SketchCamCameraDeviceSource(localizedName: "SketchCam")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Failed to add SketchCam device: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.providerManufacturer]
    }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let result = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            result.manufacturer = "languel"
        }
        return result
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}

    func connect(to client: CMIOExtensionClient) throws {}

    func disconnect(from client: CMIOExtensionClient) {
        deviceSource.noteSinkDisconnected(client)
    }
}
