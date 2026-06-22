import AppKit
import AVFoundation
import CoreImage
import ImageIO
import SketchCamCore
import UniformTypeIdentifiers

enum ExporterError: LocalizedError {
    case noDestination, cannotCreateWriter, cannotAddInput, encodingFailed
    case destinationExtension(expected: String), frameMaterializationFailed, diskSpace
    var errorDescription: String? {
        switch self {
        case .noDestination: "Choose an export file or folder first."
        case let .destinationExtension(expected):
            "Choose a destination ending in .\(expected) for this output type."
        case .cannotCreateWriter: "Could not create the output writer."
        case .cannotAddInput: "The selected codec cannot accept this output configuration."
        case .encodingFailed: "A frame could not be encoded."
        case .frameMaterializationFailed: "The cropped frame could not be prepared for its output format."
        case .diskSpace: "Export stopped at the configured free-disk-space limit."
        }
    }
}

private protocol ExportFrameSink: AnyObject {
    func append(_ image: CGImage, pixelBuffer: CVPixelBuffer, time: CMTime) throws
    func finish(cancelled: Bool, completion: @escaping (Error?) -> Void)
}

private final class StillSink: ExportFrameSink {
    private let url: URL
    private let format: ExportImageFormat
    private let quality: Double
    private var wroteFrame = false

    init(url: URL, format: ExportImageFormat, quality: Double) {
        self.url = url
        self.format = format
        self.quality = quality
    }

    func append(_ image: CGImage, pixelBuffer: CVPixelBuffer, time: CMTime) throws {
        guard !wroteFrame else { return }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, ImageSequenceSink.type(format), 1, nil
        ) else { throw ExporterError.encodingFailed }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExporterError.encodingFailed }
        wroteFrame = true
    }

    func finish(cancelled: Bool, completion: @escaping (Error?) -> Void) { completion(nil) }
}

private final class ImageSequenceSink: ExportFrameSink {
    private let folder: URL
    private let format: ExportImageFormat
    private let quality: Double
    private var index = 0

    init(folder: URL, format: ExportImageFormat, quality: Double) throws {
        self.folder = folder; self.format = format; self.quality = quality
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func append(_ image: CGImage, pixelBuffer: CVPixelBuffer, time: CMTime) throws {
        index += 1
        let url = folder.appendingPathComponent(String(format: "frame-%06d.%@", index, format.fileExtension))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, Self.type(format), 1, nil) else {
            throw ExporterError.encodingFailed
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ExporterError.encodingFailed }
    }

    func finish(cancelled: Bool, completion: @escaping (Error?) -> Void) { completion(nil) }

    static func type(_ format: ExportImageFormat) -> CFString {
        switch format {
        case .png: return UTType.png.identifier as CFString
        case .tiff: return UTType.tiff.identifier as CFString
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .heif: return UTType.heic.identifier as CFString
        }
    }
}

private final class GIFSink: ExportFrameSink {
    private let destination: CGImageDestination
    private let delay: Double

    init(url: URL, playbackFPS: Double) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 0, nil) else {
            throw ExporterError.cannotCreateWriter
        }
        self.destination = destination
        self.delay = max(0.01, 1 / playbackFPS)
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    }

    func append(_ image: CGImage, pixelBuffer: CVPixelBuffer, time: CMTime) throws {
        let p: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
        CGImageDestinationAddImage(destination, image, p as CFDictionary)
    }

    func finish(cancelled: Bool, completion: @escaping (Error?) -> Void) {
        completion(CGImageDestinationFinalize(destination) ? nil : ExporterError.encodingFailed)
    }
}

private final class MovieSink: ExportFrameSink {
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor

    init(url: URL, configuration: ExportConfiguration) throws {
        writer = try AVAssetWriter(outputURL: url, fileType: configuration.container == .mp4 ? .mp4 : .mov)
        let codec: AVVideoCodecType = switch configuration.movieCodec {
        case .h264: .h264
        case .hevc: .hevc
        case .proRes422: .proRes422
        case .proRes422HQ: .proRes422HQ
        case .proRes4444: .proRes4444
        }
        var compression: [String: Any] = [:]
        if codec == .h264 || codec == .hevc {
            compression[AVVideoQualityKey] = configuration.quality
            compression[AVVideoExpectedSourceFrameRateKey] = configuration.playbackFPS
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: configuration.width,
            AVVideoHeightKey: configuration.height,
            AVVideoCompressionPropertiesKey: compression
        ])
        input.expectsMediaDataInRealTime = configuration.renderMode == .live
        guard writer.canAdd(input) else { throw ExporterError.cannotAddInput }
        writer.add(input)
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: configuration.width,
            kCVPixelBufferHeightKey as String: configuration.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.startWriting() else { throw writer.error ?? ExporterError.cannotCreateWriter }
        writer.startSession(atSourceTime: .zero)
    }

    func append(_ image: CGImage, pixelBuffer: CVPixelBuffer, time: CMTime) throws {
        var spins = 0
        while !input.isReadyForMoreMediaData && spins < 100 {
            Thread.sleep(forTimeInterval: 0.002); spins += 1
        }
        guard input.isReadyForMoreMediaData, adaptor.append(pixelBuffer, withPresentationTime: time) else {
            throw writer.error ?? ExporterError.encodingFailed
        }
    }

    func finish(cancelled: Bool, completion: @escaping (Error?) -> Void) {
        input.markAsFinished()
        if cancelled { writer.cancelWriting(); completion(nil); return }
        writer.finishWriting { completion(self.writer.error) }
    }
}

private final class ExportReviewSource: @unchecked Sendable {
    enum Storage {
        case movie(AVAssetImageGenerator)
        case images([URL])
        case imageSource(CGImageSource)
    }

    let storage: Storage
    let frameCount: Int
    let fps: Double

    init?(url: URL, configuration: ExportConfiguration) {
        fps = max(0.001, configuration.playbackFPS)
        switch configuration.outputKind {
        case .movie:
            let asset = AVURLAsset(url: url)
            let duration = max(0, CMTimeGetSeconds(asset.duration))
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            storage = .movie(generator)
            frameCount = max(1, Int((duration * fps).rounded(.up)))
        case .imageSequence:
            guard let urls = try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil
            ).filter({ $0.lastPathComponent.hasPrefix("frame-") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
                  !urls.isEmpty else { return nil }
            storage = .images(urls); frameCount = urls.count
        case .gif, .still:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            storage = .imageSource(source); frameCount = max(1, CGImageSourceGetCount(source))
        }
    }

    func image(at index: Int) -> CGImage? {
        let safe = min(max(0, index), frameCount - 1)
        switch storage {
        case .movie(let generator):
            return try? generator.copyCGImage(
                at: CMTime(seconds: Double(safe) / fps, preferredTimescale: 600_000),
                actualTime: nil
            )
        case .images(let urls):
            guard let source = CGImageSourceCreateWithURL(urls[safe] as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(source, 0, nil)
        case .imageSource(let source):
            return CGImageSourceCreateImageAtIndex(source, safe, nil)
        }
    }
}

final class OutputStreamExporter: ObservableObject, @unchecked Sendable {
    enum SessionState: String { case idle, recording, finishing, failed }
    enum BuiltInPreset: String, CaseIterable, Identifiable {
        case activeInkPerformance
        case realtimePerformance
        case manualStopMotion
        case mouseUpStopMotion
        case canvasActions
        case inkTimeLapse

        var id: String { rawValue }
        var title: String {
            switch self {
            case .activeInkPerformance: "Active Ink Performance"
            case .realtimePerformance: "Realtime Performance"
            case .manualStopMotion: "Manual Stop Motion"
            case .mouseUpStopMotion: "Mouse-Up Stop Motion"
            case .canvasActions: "Canvas Actions"
            case .inkTimeLapse: "Ink Time-Lapse"
            }
        }
        var summary: String {
            switch self {
            case .activeInkPerformance:
                "Capture smoothly while a gesture or the ink simulation is active; omit settled idle time."
            case .realtimePerformance:
                "Capture every composed frame at the current output rate, including pauses."
            case .manualStopMotion:
                "Add one frame only with Capture Next or its keyboard shortcut."
            case .mouseUpStopMotion:
                "Add one completed frame whenever the canvas pointer is released."
            case .canvasActions:
                "Add one frame after each committed stroke, command, undo, or redo."
            case .inkTimeLapse:
                "Sample active ink at 5 FPS and play it at the output rate for a compact simulation study."
            }
        }
    }

    @Published var configuration = ExportConfiguration()
    @Published var destinationURL: URL?
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var capturedFrames = 0
    @Published private(set) var duplicatedFrames = 0
    @Published private(set) var droppedFrames = 0
    @Published private(set) var statusText = "Ready"
    @Published private(set) var progress: Double?
    @Published private(set) var reviewImage: CGImage?
    @Published private(set) var reviewFrame = 0
    @Published private(set) var reviewFrameCount = 0
    @Published private(set) var reviewURL: URL?
    @Published private(set) var reviewIsLoading = false
    @Published var presetName = ""
    @Published private(set) var presets: [ExportPreset] = []
    @Published private(set) var selectedBuiltInPreset: BuiltInPreset?
    var onAcceptedFrame: ((Int) -> Void)?
    var onNRTRequested: ((ExportConfiguration) -> Void)?
    var sourceTimeProvider: (() -> Double?)?

    private struct Runtime {
        var active = false
        var acceptingFrames = true
        var manualPending = 0
        var eventPending: CaptureTrigger?
        var pendingActionID: UUID?
        var startedAt = 0.0
        var lastCaptureAt = -Double.infinity
        var nextCaptureAt = 0.0
        var mouseDown = false
        var mouseDragging = false
        var drawActive = false
        var washActive = false
        var inkSolverActive = false
        var inkChange = 0.0
        var metrics: [ExportMetric: Double] = [:]
        var layerMetrics: [UUID: [ExportMetric: Double]] = [:]
        var layerMetricFrames: [UUID: CVPixelBuffer] = [:]
        var metricFrame: CVPixelBuffer?
        var streamConditionWasTrue = false
        var acceptedCount = 0
        var metadata: [ExportFrameMetadata] = []
    }

    private let lock = NSLock()
    private var runtime = Runtime()
    private let writerQueue = DispatchQueue(label: "io.github.languel.sketchcam.export", qos: .userInitiated)
    private let writerSlots = DispatchSemaphore(value: 4)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var sink: ExportFrameSink?
    private var scopedURL: URL?
    private var reviewScopedURL: URL?
    private var lastFrame: CVPixelBuffer?
    private var posterImage: CGImage?
    private var restoreConfigurationAfterSession: ExportConfiguration?
    private var reviewSource: ExportReviewSource?
    private var reviewConfiguration: ExportConfiguration?
    /// The compositor frame before export framing/crop. Keeping the latest raw
    /// frame lets Review use the exact same renderer as the encoder instead of
    /// drawing a second crop guide over an already transformed export.
    private var reviewInputImage: CGImage?
    private var reviewInputIsPreExport = false
    private var reviewPreviewRevision = 0
    private let reviewQueue = DispatchQueue(label: "io.github.languel.sketchcam.export.review", qos: .userInitiated)
    private let defaultsKey = "io.github.languel.sketchcam.export.configuration"
    private let presetsKey = "io.github.languel.sketchcam.export.presets"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let saved = try? JSONDecoder().decode(ExportConfiguration.self, from: data) {
            configuration = saved
        }
        if let data = UserDefaults.standard.data(forKey: presetsKey),
           let saved = try? JSONDecoder().decode([ExportPreset].self, from: data) {
            presets = saved
        }
    }

    deinit {
        scopedURL?.stopAccessingSecurityScopedResource()
        reviewScopedURL?.stopAccessingSecurityScopedResource()
    }

    var isRecording: Bool { lock.withLock { runtime.active } }
    var reviewTime: Double {
        Double(reviewFrame) / max(0.001, reviewConfiguration?.playbackFPS ?? configuration.playbackFPS)
    }

    func needsMetricTarget(_ id: UUID) -> Bool {
        isRecording && configuration.gates.contains { $0.enabled && $0.kind == .streamMetric && $0.layerID == id }
    }

    func applyPreset(_ preset: BuiltInPreset, outputFPS: Double = 30) {
        let fps = min(360, max(0.001, outputFPS))
        var value = ExportConfiguration()
        switch preset {
        case .activeInkPerformance:
            value.outputKind = .movie
            value.trigger = .cadence
            value.captureFPS = fps
            value.playbackFPS = fps
            value.gates = [CaptureGate(kind: .inkSolverActive, comparison: .above, lowerBound: 0.5)]
        case .realtimePerformance:
            value.outputKind = .movie
            value.trigger = .cadence
            value.captureFPS = fps
            value.playbackFPS = fps
            value.gates = []
        case .manualStopMotion:
            value.outputKind = .movie
            value.trigger = .manual
            value.captureFPS = 1
            value.playbackFPS = fps
        case .mouseUpStopMotion:
            value.outputKind = .movie
            value.trigger = .mouseUp
            value.playbackFPS = fps
        case .canvasActions:
            value.outputKind = .movie
            value.trigger = .anyCanvasAction
            value.playbackFPS = fps
        case .inkTimeLapse:
            value.outputKind = .movie
            value.trigger = .cadence
            value.captureFPS = 5
            value.playbackFPS = fps
            value.gates = [CaptureGate(kind: .inkSolverActive, comparison: .above, lowerBound: 0.5)]
        }
        selectedBuiltInPreset = preset
        configuration = value
        invalidateIncompatibleDestination()
        persistConfiguration()
    }

    func saveNamedPreset() {
        let name = presetName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = presets.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
            presets[index].configuration = configuration
        } else {
            presets.append(ExportPreset(name: name, configuration: configuration))
        }
        persistPresets()
    }

    func applyPreset(_ preset: ExportPreset) {
        selectedBuiltInPreset = nil
        configuration = preset.configuration
        invalidateIncompatibleDestination()
        persistConfiguration()
    }

    func deletePreset(_ preset: ExportPreset) {
        presets.removeAll { $0.id == preset.id }
        persistPresets()
    }

    private func persistPresets() {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: presetsKey) }
    }

    func persistConfiguration() {
        var value = configuration; value.clamp(); configuration = value
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }

    /// A file selected for one sink must never silently retain that suffix
    /// when the user switches to another sink. Besides confusing Finder and
    /// media players, a stale suffix can make downstream UTType dispatch pick
    /// the wrong importer. Sequences target a folder and therefore have none.
    func invalidateIncompatibleDestination() {
        guard let destinationURL else { return }
        if configuration.outputKind == .imageSequence {
            let isDirectory = (try? destinationURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            guard !isDirectory else { return }
            self.destinationURL = nil
            statusText = "Choose an image-sequence folder"
            return
        }
        let expected = expectedFileExtension(configuration)
        guard destinationURL.pathExtension.caseInsensitiveCompare(expected) != .orderedSame else { return }
        self.destinationURL = nil
        statusText = "Choose a .\(expected) destination"
    }

    func expectedFileExtension(_ config: ExportConfiguration) -> String {
        switch config.outputKind {
        case .still: config.imageFormat.fileExtension
        case .imageSequence: ""
        case .gif: "gif"
        case .movie: config.container.rawValue
        }
    }

    func start() { start(seedingReview: false) }

    private func start(seedingReview: Bool) {
        guard state == .idle || state == .failed, let chosenURL = destinationURL else {
            statusText = ExporterError.noDestination.localizedDescription; return
        }
        var config = configuration; config.clamp(); configuration = config; persistConfiguration()
        if config.outputKind != .imageSequence {
            let expected = expectedFileExtension(config)
            guard chosenURL.pathExtension.caseInsensitiveCompare(expected) == .orderedSame else {
                fail(ExporterError.destinationExtension(expected: expected))
                return
            }
        }
        do {
            let destinationURL = try prepareDestination(chosenURL, config: config)
            self.destinationURL = destinationURL
            scopedURL = chosenURL
            _ = chosenURL.startAccessingSecurityScopedResource()
            let newSink: ExportFrameSink
            switch config.outputKind {
            case .still:
                newSink = StillSink(url: destinationURL, format: config.imageFormat, quality: config.quality)
            case .imageSequence:
                newSink = try ImageSequenceSink(folder: destinationURL, format: config.imageFormat, quality: config.quality)
            case .gif: newSink = try GIFSink(url: destinationURL, playbackFPS: config.playbackFPS)
            case .movie: newSink = try MovieSink(url: destinationURL, configuration: config)
            }
            sink = newSink
            posterImage = nil
            let now = config.renderMode == .live ? ProcessInfo.processInfo.systemUptime : 0
            lock.withLock {
                runtime = Runtime(active: true, acceptingFrames: !seedingReview,
                                  startedAt: now, nextCaptureAt: now)
            }
            capturedFrames = 0; duplicatedFrames = 0; droppedFrames = 0
            progress = config.renderMode == .live ? nil : 0
            state = .recording; statusText = "Recording"
            if config.renderMode != .live { onNRTRequested?(config) }
        } catch { fail(error) }
    }

    func stop(cancelled: Bool = false) {
        guard state == .recording else { return }
        lock.withLock { runtime.active = false }
        state = .finishing; statusText = cancelled ? "Cancelling…" : "Finishing…"
        let metadata = lock.withLock { runtime.metadata }
        let destination = destinationURL
        let config = configuration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.sink?.finish(cancelled: cancelled) { error in
                if !cancelled, config.writeMetadata, let destination {
                    let sidecar = destination.deletingPathExtension().appendingPathExtension("json")
                    try? JSONEncoder.pretty.encode(
                        ExportSessionMetadata(configuration: config, frames: metadata)
                    ).write(to: sidecar)
                }
                if !cancelled, config.writePoster, let destination, let poster = self.posterImage {
                    let posterURL = destination.deletingPathExtension().appendingPathExtension("poster.png")
                    if let imageDestination = CGImageDestinationCreateWithURL(
                        posterURL as CFURL, UTType.png.identifier as CFString, 1, nil
                    ) {
                        CGImageDestinationAddImage(imageDestination, poster, nil)
                        _ = CGImageDestinationFinalize(imageDestination)
                    }
                }
                DispatchQueue.main.async {
                    if error == nil, !cancelled {
                        self.reviewScopedURL?.stopAccessingSecurityScopedResource()
                        self.reviewScopedURL = self.scopedURL
                        self.scopedURL = nil
                    } else {
                        self.scopedURL?.stopAccessingSecurityScopedResource(); self.scopedURL = nil
                    }
                    self.sink = nil; self.state = error == nil ? .idle : .failed
                    self.progress = error == nil && !cancelled ? 1 : nil
                    self.statusText = error?.localizedDescription ?? (cancelled ? "Cancelled" : "Finished \(self.capturedFrames) frames")
                    if error == nil, !cancelled, let destination {
                        self.loadReview(url: destination, configuration: config)
                    }
                    if let restore = self.restoreConfigurationAfterSession {
                        self.configuration = restore
                        self.restoreConfigurationAfterSession = nil
                        self.invalidateIncompatibleDestination()
                        self.persistConfiguration()
                    }
                }
            }
        }
        writerQueue.async(execute: work)
    }

    func captureNext() { lock.withLock { runtime.manualPending += 1 } }

    func seekReview(frame: Int) {
        guard let source = reviewSource else { return }
        let target = min(max(0, frame), source.frameCount - 1)
        reviewFrame = target; reviewIsLoading = true
        reviewQueue.async { [weak self, weak source] in
            guard let self, let source else { return }
            let image = source.image(at: target)
            DispatchQueue.main.async {
                guard self.reviewSource === source, self.reviewFrame == target else { return }
                self.reviewInputImage = image
                self.reviewInputIsPreExport = false
                self.reviewImage = image
                self.reviewIsLoading = false
            }
        }
    }

    func stepReview(_ delta: Int) { seekReview(frame: reviewFrame + delta) }

    /// Rebuilds the Review image through the same framing/crop/transform path
    /// used by every output sink. This is intentionally explicit: crop fields
    /// call it as they change, while unrelated exporter settings do no work.
    func refreshReviewPreview() {
        guard let input = reviewInputImage else { return }
        var config = configuration
        config.clamp()
        reviewPreviewRevision += 1
        let revision = reviewPreviewRevision
        reviewIsLoading = true
        let inputIsPreExport = reviewInputIsPreExport
        let reviewed = reviewConfiguration
        reviewQueue.async { [weak self] in
            guard let self else { return }
            let image: CGImage?
            if inputIsPreExport {
                image = try? self.render(self.pixelBuffer(from: input), config: config).1
            } else if let reviewed, self.sameVisualTransform(reviewed, config) {
                // Decoded review frames already contain their original export
                // transform. Showing them directly avoids applying it twice.
                image = input
            } else {
                image = try? self.render(self.pixelBuffer(from: input), config: config).1
            }
            DispatchQueue.main.async {
                guard self.reviewPreviewRevision == revision else { return }
                self.reviewImage = image ?? input
                self.reviewIsLoading = false
            }
        }
    }

    /// Creates a new take containing the reviewed prefix, then leaves the
    /// exporter armed so subsequent live/event captures append after it.
    func continueFromReview() { startFromReview(through: reviewFrame, continueRecording: true) }

    /// Re-encodes the entire reviewed clip with the current crop, transform,
    /// format, codec, and playback settings into a new take.
    func reexportReview() { startFromReview(through: max(0, reviewFrameCount - 1), continueRecording: false) }

    private func loadReview(url: URL, configuration: ExportConfiguration) {
        reviewIsLoading = true
        reviewQueue.async { [weak self] in
            guard let self else { return }
            let source = ExportReviewSource(url: url, configuration: configuration)
            let last = max(0, (source?.frameCount ?? 1) - 1)
            let image = source?.image(at: last)
            DispatchQueue.main.async {
                self.reviewSource = source
                self.reviewConfiguration = configuration
                self.reviewURL = source == nil ? nil : url
                self.reviewFrameCount = source?.frameCount ?? 0
                self.reviewFrame = last
                self.reviewImage = image
                self.reviewIsLoading = false
            }
        }
    }

    private func sameVisualTransform(_ lhs: ExportConfiguration, _ rhs: ExportConfiguration) -> Bool {
        lhs.cropLeft == rhs.cropLeft && lhs.cropTop == rhs.cropTop &&
        lhs.cropRight == rhs.cropRight && lhs.cropBottom == rhs.cropBottom &&
        lhs.resolvedRotation == rhs.resolvedRotation &&
        lhs.resolvedFlipHorizontal == rhs.resolvedFlipHorizontal &&
        lhs.resolvedFlipVertical == rhs.resolvedFlipVertical &&
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.framing == rhs.framing
    }

    private func startFromReview(through requestedFrame: Int, continueRecording: Bool) {
        guard state == .idle || state == .failed,
              let source = reviewSource, reviewFrameCount > 0 else { return }
        let last = min(max(0, requestedFrame), source.frameCount - 1)
        if configuration.outputKind == .imageSequence, let reviewURL {
            // A completed sequence points at its take folder; new takes belong
            // beside it rather than nested inside it.
            destinationURL = reviewURL.deletingLastPathComponent()
        }
        configuration.renderMode = .live
        if configuration.resolvedCollisionPolicy == .replace {
            configuration.collisionPolicy = .newTake
        }
        start(seedingReview: true)
        guard state == .recording else { return }
        statusText = continueRecording ? "Preparing reviewed prefix…" : "Re-exporting review…"
        progress = 0
        let config = configuration
        var prefixConfig = config
        if let reviewed = reviewConfiguration,
           reviewed.cropLeft == config.cropLeft, reviewed.cropTop == config.cropTop,
           reviewed.cropRight == config.cropRight, reviewed.cropBottom == config.cropBottom,
           reviewed.resolvedRotation == config.resolvedRotation,
           reviewed.resolvedFlipHorizontal == config.resolvedFlipHorizontal,
           reviewed.resolvedFlipVertical == config.resolvedFlipVertical {
            // Reviewed frames already contain the transform from their first
            // encode. Preserve them exactly unless the user changed it.
            prefixConfig.cropLeft = 0; prefixConfig.cropTop = 0
            prefixConfig.cropRight = 0; prefixConfig.cropBottom = 0
            prefixConfig.rotation = .degrees0
            prefixConfig.flipHorizontal = false; prefixConfig.flipVertical = false
        }
        writerQueue.async { [weak self, weak source] in
            guard let self, let source else { return }
            for index in 0...last {
                guard self.state == .recording, let raw = source.image(at: index) else { break }
                do {
                    let input = try self.pixelBuffer(from: raw)
                    let (buffer, image) = try self.render(input, config: prefixConfig)
                    let time = CMTime(seconds: ExportTiming.presentationTime(frameIndex: index, fps: config.playbackFPS),
                                      preferredTimescale: 600_000)
                    try self.sink?.append(image, pixelBuffer: buffer, time: time)
                    self.lock.withLock { self.runtime.acceptedCount += 1 }
                    DispatchQueue.main.async {
                        self.capturedFrames = index + 1
                        self.reviewImage = image
                        self.reviewFrame = index
                        self.progress = Double(index + 1) / Double(last + 1)
                    }
                } catch {
                    DispatchQueue.main.async { self.fail(error) }
                    return
                }
            }
            DispatchQueue.main.async {
                guard self.state == .recording else { return }
                if continueRecording {
                    let now = ProcessInfo.processInfo.systemUptime
                    self.lock.withLock {
                        self.runtime.acceptingFrames = true
                        self.runtime.startedAt = now
                        self.runtime.nextCaptureAt = now
                    }
                    self.progress = nil
                    self.statusText = "Recording after reviewed frame \(last + 1)"
                } else {
                    self.stop()
                }
            }
        }
    }

    func updateNRTProgress(_ value: Double) {
        DispatchQueue.main.async { self.progress = min(1, max(0, value)); self.statusText = "Rendering offline…" }
    }

    func signal(_ event: CaptureTrigger, active: Bool? = nil, actionID: UUID? = nil) {
        lock.withLock {
            switch event {
            case .mouseDown: runtime.mouseDown = active ?? true
            case .mouseUp: runtime.mouseDown = false; runtime.mouseDragging = false
            case .dragBegin: runtime.mouseDragging = true
            case .dragEnd: runtime.mouseDragging = false
            case .drawBegin: runtime.drawActive = true
            case .drawEnd: runtime.drawActive = false
            case .washBegin: runtime.washActive = true
            case .washEnd: runtime.washActive = false
            default: break
            }
            if matches(event, configured: configuration.trigger) {
                runtime.eventPending = event
                runtime.pendingActionID = actionID
            }
        }
    }

    func updateInkActivity(solverActive: Bool, change: Double) {
        lock.withLock { runtime.inkSolverActive = solverActive; runtime.inkChange = change }
    }

    func updateStreamMetrics(layerID: UUID, pixelBuffer: CVPixelBuffer) {
        guard isRecording, configuration.gates.contains(where: { $0.enabled && $0.layerID == layerID }) else { return }
        let previous = lock.withLock { runtime.layerMetricFrames[layerID] }
        let measured = reduceMetrics(pixelBuffer, previous: previous)
        let retained = copyPixelBuffer(pixelBuffer) ?? pixelBuffer
        lock.withLock {
            runtime.layerMetrics[layerID] = [
                .meanLuma: measured.meanLuma,
                .alphaCoverage: measured.alphaCoverage,
                .thresholdCoverage: measured.thresholdCoverage,
                .frameChange: measured.frameChange,
                .motionMagnitude: measured.frameChange
            ]
            runtime.layerMetricFrames[layerID] = retained
        }
    }

    /// Called from the live publication queue. When inactive this is one lock + branch.
    func offerFrame(_ pixelBuffer: CVPixelBuffer, frameIndex: Int, wallTime: Double = ProcessInfo.processInfo.systemUptime) {
        guard configuration.renderMode == .live else { return }
        offer(pixelBuffer, frameIndex: frameIndex, wallTime: wallTime, offline: false)
    }

    /// Called only by the isolated deterministic renderer. `renderTime` is its
    /// synthetic clock and is independent of wall time and playback FPS.
    func offerOfflineFrame(_ pixelBuffer: CVPixelBuffer, frameIndex: Int, renderTime: Double) {
        guard configuration.renderMode != .live else { return }
        offer(pixelBuffer, frameIndex: frameIndex, wallTime: renderTime, offline: true)
    }

    private func offer(_ pixelBuffer: CVPixelBuffer, frameIndex: Int, wallTime: Double, offline: Bool) {
        if isRecording, needsMetrics {
            let previous = lock.withLock { runtime.metricFrame }
            let measured = reduceMetrics(pixelBuffer, previous: previous)
            let retained = copyPixelBuffer(pixelBuffer) ?? pixelBuffer
            lock.withLock {
                runtime.metrics[.meanLuma] = measured.meanLuma
                runtime.metrics[.alphaCoverage] = measured.alphaCoverage
                runtime.metrics[.thresholdCoverage] = measured.thresholdCoverage
                runtime.metrics[.frameChange] = measured.frameChange
                runtime.metrics[.motionMagnitude] = measured.frameChange
                runtime.metricFrame = retained
                if configuration.trigger == .streamCrossing {
                    let condition = gatesPass(runtime)
                    if condition, !runtime.streamConditionWasTrue { runtime.eventPending = .streamCrossing }
                    runtime.streamConditionWasTrue = condition
                }
            }
        }
        let decision: (count: Int, trigger: CaptureTrigger, elapsed: Double, actionID: UUID?)? = lock.withLock {
            guard runtime.active, runtime.acceptingFrames else { return nil }
            let elapsed = wallTime - runtime.startedAt
            if configuration.maximumDuration > 0, elapsed >= configuration.maximumDuration { return (0, .manual, elapsed, nil) }
            if configuration.maximumFrames > 0, runtime.acceptedCount >= configuration.maximumFrames { return (0, .manual, elapsed, nil) }
            guard gatesPass(runtime) else { return nil }
            var count = 0; var trigger = configuration.trigger
            var actionID: UUID?
            if runtime.manualPending > 0 { runtime.manualPending -= 1; count = 1; trigger = .manual }
            else if let event = runtime.eventPending, wallTime - runtime.lastCaptureAt >= configuration.minimumEventInterval {
                runtime.eventPending = nil; count = 1; trigger = event
                actionID = runtime.pendingActionID; runtime.pendingActionID = nil
            } else if configuration.trigger == .cadence || configuration.trigger == .interval {
                let interval = configuration.trigger == .interval ? max(0.001, 1 / configuration.captureFPS) : 1 / configuration.captureFPS
                while wallTime + 0.000_001 >= runtime.nextCaptureAt {
                    count += 1; runtime.nextCaptureAt += interval
                    if count >= 120 { break }
                }
            }
            guard count > 0 else { return nil }
            runtime.lastCaptureAt = wallTime
            return (count, trigger, elapsed, actionID)
        }
        guard let decision else { return }
        if decision.count == 0 { DispatchQueue.main.async { self.stop() }; return }
        let cadence = decision.trigger == .cadence || decision.trigger == .interval
        if offline {
            writerSlots.wait()
        } else if cadence, writerSlots.wait(timeout: .now()) != .success {
            let index = lock.withLock { runtime.acceptedCount }
            lock.withLock {
                runtime.metadata.append(ExportFrameMetadata(
                    frameIndex: index, renderTime: decision.elapsed,
                    wallTime: Date().timeIntervalSince1970, trigger: decision.trigger,
                    duplicated: false, dropped: true, sourceTime: sourceTimeProvider?(),
                    actionID: decision.actionID
                ))
            }
            DispatchQueue.main.async { self.droppedFrames += decision.count }
            return
        }
        let source = copyPixelBuffer(pixelBuffer) ?? pixelBuffer
        lastFrame = source
        let config = configuration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            defer { if offline || cadence { self.writerSlots.signal() } }
            let sourceExtent = CGRect(x: 0, y: 0,
                                      width: CVPixelBufferGetWidth(source),
                                      height: CVPixelBufferGetHeight(source))
            let sourceImage = self.context.createCGImage(CIImage(cvPixelBuffer: source), from: sourceExtent)
            for slot in 0..<decision.count {
                do {
                    try self.checkDisk(config)
                    let (buffer, image) = try self.render(source, config: config)
                    if self.posterImage == nil { self.posterImage = image }
                    let index = self.lock.withLock { self.runtime.acceptedCount }
                    let time = CMTime(seconds: ExportTiming.presentationTime(frameIndex: index, fps: config.playbackFPS),
                                      preferredTimescale: 600_000)
                    try self.sink?.append(image, pixelBuffer: buffer, time: time)
                    let meta = ExportFrameMetadata(frameIndex: index, renderTime: decision.elapsed,
                        wallTime: Date().timeIntervalSince1970, trigger: decision.trigger,
                        duplicated: slot > 0, dropped: false, sourceTime: self.sourceTimeProvider?(),
                        actionID: decision.actionID)
                    self.lock.withLock {
                        self.runtime.metadata.append(meta)
                        self.runtime.acceptedCount += 1
                    }
                    DispatchQueue.main.async {
                        self.capturedFrames += 1
                        if slot > 0 { self.duplicatedFrames += 1 }
                        self.reviewInputImage = sourceImage
                        self.reviewInputIsPreExport = true
                        self.reviewImage = image
                        self.reviewFrame = index
                        self.reviewFrameCount = index + 1
                        self.onAcceptedFrame?(index)
                    }
                } catch { DispatchQueue.main.async { self.fail(error) }; return }
            }
            if config.outputKind == .still { DispatchQueue.main.async { self.stop() } }
        }
        writerQueue.async(execute: work)
    }

    func exportCurrent(_ pixelBuffer: CVPixelBuffer, to url: URL) {
        destinationURL = url
        restoreConfigurationAfterSession = configuration
        configuration.outputKind = .still
        configuration.renderMode = .live
        configuration.trigger = .manual
        start(); captureNext(); offerFrame(pixelBuffer, frameIndex: 0)
    }

    private func gatesPass(_ r: Runtime) -> Bool {
        configuration.gates.filter(\.enabled).allSatisfy { gate in
            let value: Double
            switch gate.kind {
            case .mouseDown: value = r.mouseDown ? 1 : 0
            case .mouseDragging: value = r.mouseDragging ? 1 : 0
            case .drawActive: value = r.drawActive ? 1 : 0
            case .washActive: value = r.washActive ? 1 : 0
            case .inkSolverActive: value = r.inkSolverActive ? 1 : 0
            case .inkPixelsChanging: value = max(r.inkChange, r.metrics[.frameChange] ?? 0)
            case .streamMetric:
                value = gate.layerID.flatMap { r.layerMetrics[$0]?[gate.metric] } ?? r.metrics[gate.metric] ?? 0
            }
            return ExportTiming.condition(value, comparison: gate.comparison,
                                          lower: gate.lowerBound, upper: gate.upperBound)
        }
    }

    private func matches(_ event: CaptureTrigger, configured: CaptureTrigger) -> Bool {
        event == configured ||
        (configured == .drawBoth && (event == .drawBegin || event == .drawEnd)) ||
        (configured == .washBoth && (event == .washBegin || event == .washEnd))
    }

    private var needsMetrics: Bool {
        configuration.trigger == .streamCrossing || configuration.gates.contains {
            $0.enabled && ($0.kind == .streamMetric || $0.kind == .inkPixelsChanging)
        }
    }

    /// GPU reductions for export gates. Full frames remain in GPU/IOSurface
    /// memory; only four bytes per metric cross back to the CPU.
    private func reduceMetrics(_ buffer: CVPixelBuffer, previous: CVPixelBuffer?) ->
        (meanLuma: Double, alphaCoverage: Double, thresholdCoverage: Double, frameChange: Double) {
        let image = CIImage(cvPixelBuffer: buffer)
        let luma = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
            "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
        ])
        let threshold = luma.applyingFilter("CIColorThreshold", parameters: ["inputThreshold": 0.5])
        let alpha = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)
        ])
        let change: CIImage? = previous.map {
            image.applyingFilter("CIDifferenceBlendMode", parameters: [kCIInputBackgroundImageKey: CIImage(cvPixelBuffer: $0)])
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                    "inputGVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0),
                    "inputBVector": CIVector(x: 0.2126, y: 0.7152, z: 0.0722, w: 0)
                ])
        }
        return (areaAverage(luma), areaAverage(alpha), areaAverage(threshold), change.map(areaAverage) ?? 0)
    }

    private func areaAverage(_ image: CIImage) -> Double {
        let average = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent)
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(average, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return Double(pixel[0]) / 255
    }

    private func render(_ source: CVPixelBuffer, config: ExportConfiguration) throws -> (CVPixelBuffer, CGImage) {
        var output: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, config.width, config.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output)
        guard let output else { throw ExporterError.encodingFailed }
        let target = CGRect(x: 0, y: 0, width: config.width, height: config.height)
        let background = CIImage(color: config.includeAlpha ? .clear : .black).cropped(to: target)
        let base = frameImage(CIImage(cvPixelBuffer: source), into: target,
                              framing: config.framing, background: background)
        let hasTransform = (config.cropLeft ?? 0) > 0 || (config.cropTop ?? 0) > 0 ||
            (config.cropRight ?? 0) > 0 || (config.cropBottom ?? 0) > 0 ||
            config.resolvedRotation != .degrees0 || config.resolvedFlipHorizontal || config.resolvedFlipVertical
        let framed: CIImage
        if hasTransform {
            // Crop lives in final-output coordinates, matching the review UI.
            // Fill the transformed crop back into the requested output frame;
            // this prevents the original Fit letterbox from reappearing.
            framed = frameImage(transformedInput(base, config: config), into: target,
                                framing: .fill, background: background)
        } else {
            framed = base
        }
        let colorSpace = config.colorSpace == .displayP3 ? CGColorSpace(name: CGColorSpace.displayP3)! : CGColorSpace(name: CGColorSpace.sRGB)!
        context.render(framed, to: output, bounds: target, colorSpace: colorSpace)
        // The pixel buffer is the canonical encoded frame. Materializing the
        // lazy pre-render crop graph separately can fail when its transformed
        // extent contains fractional edges, even though CI rendered the exact
        // integral output successfully. Build the CGImage from that finished
        // buffer so still/GIF/sequence sinks see precisely the movie frame.
        let rendered = CIImage(cvPixelBuffer: output)
        guard let cg = context.createCGImage(rendered, from: target, format: .BGRA8,
                                             colorSpace: colorSpace) else {
            throw ExporterError.frameMaterializationFailed
        }
        return (output, cg)
    }

    private func frameImage(_ input: CIImage, into target: CGRect,
                            framing: ExportFraming, background: CIImage) -> CIImage {
        let sx = target.width / input.extent.width, sy = target.height / input.extent.height
        let tx: CGFloat, ty: CGFloat, xScale: CGFloat, yScale: CGFloat
        switch framing {
        case .stretch: xScale = sx; yScale = sy
        case .fit: xScale = min(sx, sy); yScale = xScale
        case .fill: xScale = max(sx, sy); yScale = xScale
        }
        tx = (target.width - input.extent.width * xScale) / 2
        ty = (target.height - input.extent.height * yScale) / 2
        return input.transformed(by: CGAffineTransform(scaleX: xScale, y: yScale))
            .transformed(by: CGAffineTransform(translationX: tx, y: ty)).composited(over: background).cropped(to: target)
    }

    private func transformedInput(_ source: CIImage, config: ExportConfiguration) -> CIImage {
        let extent = source.extent
        let left = CGFloat(config.cropLeft ?? 0), right = CGFloat(config.cropRight ?? 0)
        let top = CGFloat(config.cropTop ?? 0), bottom = CGFloat(config.cropBottom ?? 0)
        let crop = CGRect(x: extent.minX + extent.width * left,
                          y: extent.minY + extent.height * bottom,
                          width: max(1, extent.width * (1 - left - right)),
                          height: max(1, extent.height * (1 - top - bottom)))
        var image = source.cropped(to: crop)
            .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY))
        if config.resolvedFlipHorizontal {
            image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
                                                             tx: image.extent.width, ty: 0))
        }
        if config.resolvedFlipVertical {
            image = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1,
                                                             tx: 0, ty: image.extent.height))
        }
        let angle = CGFloat(config.resolvedRotation.rawValue) * .pi / 180
        if angle != 0 {
            image = image.transformed(by: CGAffineTransform(rotationAngle: -angle))
            image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX,
                                                             y: -image.extent.minY))
        }
        return image
    }

    private func pixelBuffer(from image: CGImage) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        guard let buffer else { throw ExporterError.encodingFailed }
        context.render(CIImage(cgImage: image), to: buffer)
        return buffer
    }

    private func copyPixelBuffer(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        var copy: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, CVPixelBufferGetWidth(source), CVPixelBufferGetHeight(source),
                            CVPixelBufferGetPixelFormatType(source),
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &copy)
        guard let copy else { return nil }
        context.render(CIImage(cvPixelBuffer: source), to: copy)
        return copy
    }

    private func prepareDestination(_ url: URL, config: ExportConfiguration) throws -> URL {
        if config.outputKind == .imageSequence {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var take = url.appendingPathComponent(config.takeName, isDirectory: true)
            if config.resolvedCollisionPolicy == .replace,
               FileManager.default.fileExists(atPath: take.path) {
                try FileManager.default.removeItem(at: take)
            } else {
                var suffix = 2
                while FileManager.default.fileExists(atPath: take.path),
                      !(try FileManager.default.contentsOfDirectory(atPath: take.path)).isEmpty {
                    take = url.appendingPathComponent(String(format: "%@-%03d", config.takeName, suffix), isDirectory: true)
                    suffix += 1
                }
            }
            try FileManager.default.createDirectory(at: take, withIntermediateDirectories: true)
            return take
        } else if FileManager.default.fileExists(atPath: url.path) {
            if config.resolvedCollisionPolicy == .replace {
                try FileManager.default.removeItem(at: url)
            } else {
                let folder = url.deletingLastPathComponent()
                let ext = url.pathExtension
                let stem = url.deletingPathExtension().lastPathComponent
                var suffix = 2
                var candidate: URL
                repeat {
                    candidate = folder.appendingPathComponent(String(format: "%@-%03d", stem, suffix))
                    if !ext.isEmpty { candidate.appendPathExtension(ext) }
                    suffix += 1
                } while FileManager.default.fileExists(atPath: candidate.path)
                return candidate
            }
        }
        return url
    }

    private func checkDisk(_ config: ExportConfiguration) throws {
        guard let destinationURL,
              let values = try? destinationURL.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return }
        if Double(bytes) < config.minimumFreeDiskGB * 1_000_000_000 { throw ExporterError.diskSpace }
    }

    private func fail(_ error: Error) {
        lock.withLock { runtime.active = false }
        state = .failed; statusText = error.localizedDescription
        sink?.finish(cancelled: false) { _ in }
        sink = nil
        if let restore = restoreConfigurationAfterSession {
            configuration = restore
            restoreConfigurationAfterSession = nil
            invalidateIncompatibleDestination()
            persistConfiguration()
        }
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder { let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }
}
