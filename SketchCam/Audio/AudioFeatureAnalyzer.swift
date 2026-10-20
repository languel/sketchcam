import Accelerate
import Foundation
import SketchCamCore

/// One analyzer per source, confined to that source's analysis queue.
/// Pitch is a voiced-period estimate, not a note/speech classifier.
final class AudioFeatureAnalyzer {
    private let size = 2048
    private let logSize: vDSP_Length = 11
    private let fft = vDSP_create_fftsetup(11, FFTRadix(kFFTRadix2))!
    private var window = [Float](repeating: 0, count: 2048)
    private var history: [Float] = []
    private var rate: Double = 0

    init() { vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM)) }
    deinit { vDSP_destroy_fftsetup(fft) }

    func analyze(_ packet: AudioPacket) -> AudioFeatures {
        if rate != packet.sampleRate { history = []; rate = packet.sampleRate }
        history.append(contentsOf: packet.samples)
        if history.count > size { history.removeFirst(history.count - size) }
        var result = AudioFeatures()
        result.timestamp = packet.timestamp
        guard !packet.samples.isEmpty, rate > 0 else { return result }
        var sum: Float = 0
        vDSP_svesq(packet.samples, 1, &sum, vDSP_Length(packet.samples.count))
        result.rms = sqrt(sum / Float(packet.samples.count))
        result.peak = packet.samples.reduce(0) { max($0, abs($1)) }
        result.decibels = max(-120, 20 * log10(max(0.000001, result.rms)))
        // Simple energy gate for the first pass; not a semantic speech detector.
        result.speechActive = result.decibels > -42
        guard history.count == size else { return result }
        var input = zip(history, window).map { pair in pair.0 * pair.1 }
        var real = [Float](repeating: 0, count: size / 2)
        var imaginary = real
        var power = real
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                input.withUnsafeMutableBufferPointer { values in
                    values.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(fft, &split, 1, logSize, FFTDirection(FFT_FORWARD))
                // Real FFT packs Nyquist into imagp[0]; don't treat it as DC.
                let nyquist = split.imagp[0]
                split.imagp[0] = 0
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
                power.append(nyquist * nyquist)
            }
        }
        let scale = Float(1.0 / Double(size))
        result.spectrum = power.map { sqrt($0) * scale }
        result.spectrumHzPerBin = Float(rate / Double(size))
        var bands: [Float] = [0, 0, 0]
        for (index, energy) in power.enumerated() {
            let hz = Float(index) * result.spectrumHzPerBin
            bands[hz < 250 ? 0 : hz < 2000 ? 1 : 2] += energy * scale * scale
        }
        result.bands = bands.map { sqrt($0) }
        if result.speechActive {
            // Remove DC, decimate to keep the bounded autocorrelation inexpensive.
            let step = max(1, Int(rate / 12000))
            let mean = history.reduce(0, +) / Float(size)
            let samples = stride(from: 0, to: size, by: step).map { history[$0] - mean }
            let pitchRate = rate / Double(step)
            let minimum = max(2, Int(pitchRate / 800))
            let maximum = min(samples.count / 2, Int(pitchRate / 65))
            var scores = [Float](repeating: 0, count: maximum + 1)
            if maximum > minimum {
                for lag in minimum...maximum {
                    var cross: Float = 0, a: Float = 0, b: Float = 0
                    for n in 0..<(samples.count - lag) {
                        let x = samples[n], y = samples[n + lag]
                        cross += x * y; a += x * x; b += y * y
                    }
                    scores[lag] = cross / max(0.00000001, sqrt(a * b))
                }
                // Prefer the first strong local maximum to octave multiples.
                let best = scores[minimum...maximum].max() ?? 0
                if best > 0.7, let lag = (minimum..<maximum).first(where: {
                    scores[$0] > max(0.7, best * 0.92) && scores[$0] >= scores[$0 - 1] && scores[$0] >= scores[$0 + 1]
                }) {
                    result.pitchHz = Float(pitchRate / Double(lag))
                    result.pitchConfidence = scores[lag]
                }
            }
        }
        return result
    }
}
