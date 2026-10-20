import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import SketchCamCore

struct MicrophoneDevice: Identifiable {
    var id: AudioDeviceID
    var name: String
}

/// Mic and file use the same PCM, feature and clock contract. The tap copies
/// its borrowed buffer and hands it off; FFT, pitch and ASR stay off the audio
/// render thread. A bounded semaphore drops analysis blocks under overload.
final class AudioStreamSource {
    let source: AudioSourceStreamID
    private let store: TemporalStreamStore
    private let queue: DispatchQueue
    private let pending = DispatchSemaphore(value: 3)
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var tapNode: AVAudioNode?
    private var scopedURL: URL?
    private var generation = UUID()
    private let stateLock = NSLock()
    private var activeGeneration = UUID()
    private var notification: NSObjectProtocol?
    var onStopped: ((String?) -> Void)?

    init(source: AudioSourceStreamID, store: TemporalStreamStore) {
        self.source = source; self.store = store
        queue = DispatchQueue(label: "sketchcam.audio.\(source.rawValue)", qos: .userInitiated)
    }
    deinit { stop() }

    static func microphones() -> [MicrophoneDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return ids.compactMap { id in
            var streamsAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }
            var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: CFString = "Microphone" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            _ = AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name)
            return MicrophoneDevice(id: id, name: name as String)
        }
    }

    func startMicrophone(deviceID: AudioDeviceID?) throws {
        stop()
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if var deviceID, let unit = input.audioUnit {
            let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global, 0, &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw SourceError.noInput }
        self.engine = engine
        installTap(on: input, format: format)
        // Mic never connects to speakers (no feedback).
        do { engine.prepare(); try engine.start(); observeConfiguration(engine) }
        catch { stop(); throw error }
    }

    func playFile(_ url: URL, audible: Bool) throws {
        stop()
        let hasScope = url.startAccessingSecurityScopedResource()
        scopedURL = hasScope ? url : nil
        do {
            let file = try AVAudioFile(forReading: url)
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
            engine.mainMixerNode.outputVolume = audible ? 1 : 0
            self.engine = engine; self.player = player
            installTap(on: player, format: file.processingFormat)
            let token = generation
            player.scheduleFile(file, at: nil, completionCallbackType: .dataPlayedBack) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.generation == token else { return }
                    self.stop(); self.onStopped?(nil)
                }
            }
            engine.prepare(); try engine.start(); player.play(); observeConfiguration(engine)
        } catch { stop(); throw error }
    }
    func setAudible(_ audible: Bool) { engine?.mainMixerNode.outputVolume = audible ? 1 : 0 }

    func stop() {
        stateLock.withLock { activeGeneration = UUID() }
        generation = UUID()
        if let notification { NotificationCenter.default.removeObserver(notification) }
        notification = nil
        tapNode?.removeTap(onBus: 0); tapNode = nil
        player?.stop(); engine?.stop(); player = nil; engine = nil
        if let scopedURL { scopedURL.stopAccessingSecurityScopedResource() }
        scopedURL = nil
        // Ordered after all old queued packets; new sessions follow this reset.
        queue.async { [store, source] in store.clear(source) }
    }

    private func observeConfiguration(_ engine: AVAudioEngine) {
        notification = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange,
            object: engine, queue: .main) { [weak self] _ in
                self?.stop(); self?.onStopped?("Audio device changed. Start the source again.")
            }
    }

    private func installTap(on node: AVAudioNode, format: AVAudioFormat) {
        let token = UUID(); generation = token
        stateLock.withLock { activeGeneration = token }
        let analyzer = AudioFeatureAnalyzer()
        var framePosition: Int64 = 0
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self, let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength), channelCount = Int(buffer.format.channelCount)
            let position = framePosition; framePosition += Int64(count)
            guard count > 0, self.pending.wait(timeout: .now()) == .success else { return }
            var mono = [Float](repeating: 0, count: count)
            let interleaved = buffer.format.isInterleaved
            for ch in 0..<channelCount {
                for n in 0..<count {
                    mono[n] += (interleaved ? channels[0][n * channelCount + ch] : channels[ch][n]) / Float(channelCount)
                }
            }
            let packet = AudioPacket(source: self.source, session: token,
                timestamp: ProcessInfo.processInfo.systemUptime,
                mediaTime: Double(position) / format.sampleRate, sampleRate: format.sampleRate, samples: mono)
            self.queue.async {
                defer { self.pending.signal() }
                guard self.stateLock.withLock({ self.activeGeneration == token }) else { return }
                self.store.publish(packet, features: analyzer.analyze(packet))
            }
        }
        tapNode = node
    }
    enum SourceError: LocalizedError {
        case noInput
        var errorDescription: String? { "No audio input is available." }
    }
}
