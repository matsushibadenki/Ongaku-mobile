import AVFoundation
import Foundation

/// Transport-only waveform probes. Signal positions use the quantized seek;
/// all DSP/slice/timeline methods are shared with shipping code or the tone test.
@main
struct PlaybackHandoffBroadbandRegression {
    typealias Transport = PlaybackHandoffWaveformRegression
    static func energy(_ signal: [Float], _ range: Range<Int>) -> Double {
        range.reduce(0) { $0 + pow(Double(signal[$1]), 2) }
    }
    static func residualDB(_ a: [Float], _ b: [Float], _ range: Range<Int>) -> Double {
        let residual = range.reduce(0.0) { $0 + pow(Double(a[$1] - b[$1]), 2) }
        return 10 * log10(max(1e-30, residual) / max(1e-30, energy(a, range)))
    }
    static func sample(_ signal: String, time: Double, channel: Int) -> Float {
        let sign = channel == 0 ? 1.0 : -0.5
        let frequencies = [137.0, 997, 3901, 8033, 12007, 16001]
        if signal == "multitone" {
            return Float(sign * frequencies.enumerated().reduce(0.0) {
                $0 + 0.025 * sin(2 * .pi * $1.element * time + Double($1.offset) * 0.37)
            })
        }
        if signal == "chirp" {
            // A 200 Hz -> 18 kHz sweep over the rendered half second.
            return Float(sign * 0.15 * sin(2 * .pi * (200 * time + 17_800 * time * time)))
        }
        // Gaussian-windowed wideband bursts at fade midpoint and after fade.
        // The first is deliberately centered inside the measured fade window.
        let bursts = [0.282, 0.39].reduce(0.0) { total, center in
            let t = time - center
            let envelope = exp(-0.5 * pow(t / 0.0004, 2))
            return total + envelope * [2000.0, 8000, 16000].reduce(0.0) {
                $0 + 0.05 * cos(2 * .pi * $1 * t)
            }
        }
        return Float(sign * bursts)
    }
    static func main() {
        do { try run() }
        catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = AVAudioFormat(standardFormatWithSampleRate: Transport.graphRate, channels: 2)!
        // Nonuniform blocks test SRC history across unlike render boundaries.
        let pattern = [127, 512, 63, 1024, 256]
        var cases = 0
        for rate in [44_100.0, 48_000.0] {
            for signal in ["multitone", "chirp", "burst"] {
                for seek in [0.0, 0.123457] {
                    let offset = floor(seek * rate) / rate
                    let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
                    let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
                    source.frameLength = source.frameCapacity
                    for ch in 0..<2 { for i in 0..<Int(source.frameLength) {
                        source.floatChannelData![ch][i] = sample(signal, time: Double(i) / rate - offset, channel: ch)
                    } }
                    let url = directory.appendingPathComponent("source.caf")
                    var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
                    do { let writer = try AVAudioFile(forWriting: url, settings: settings); try writer.write(from: source) }
                    for phase in [PrecisionSincPhaseMode.linear, .minimumPhase, .apodizing] {
                        for quality in [PrecisionSincQualityMode.eco, .standard, .master] {
                            let file = try AVAudioFile(forReading: url)
                            let pcm = try ShippingSincMeasurement.makeChunkedPrecisionSincPlaybackBuffer(from: file,
                                sourceFrameCount: AVAudioFrameCount(file.length), sourceFormat: format, targetFormat: target,
                                phaseMode: phase, qualityMode: quality)
                            for outputRate in [44_100.0, 48_000.0, 96_000.0] {
                                let (a, plan) = try Transport.render(file: AVAudioFile(forReading: url), pcm: pcm,
                                    seek: seek, outputRate: outputRate, path: 0, block: 1024, blockPattern: pattern)
                                let (sum, _) = try Transport.render(file: AVAudioFile(forReading: url), pcm: pcm,
                                    seek: seek, outputRate: outputRate, path: 1, block: 1024, blockPattern: pattern)
                                let b = (0..<2).map { ch in zip(sum[ch], a[ch]).map { $0.0 - $0.1 } }
                                let stable = Int(outputRate * 0.36)..<Int(outputRate * 0.46)
                                let fade = Int(outputRate * (plan.delayFromRenderTime + 0.02))..<Int(outputRate * (plan.delayFromRenderTime + 0.044))
                                for controlInterval in [0.0, 0.016] {
                                    let (mixed, _) = try Transport.render(file: AVAudioFile(forReading: url), pcm: pcm,
                                        seek: seek, outputRate: outputRate, path: 2, block: 1024,
                                        blockPattern: pattern, controlInterval: controlInterval)
                                    for ch in 0..<2 {
                                        try Transport.require(energy(a[ch], stable) > 1e-6 && energy(a[ch], fade) > 1e-6,
                                                              "Probe has no energy in measurement windows")
                                        var bestLag = 0, bestCorrelation = -Double.infinity
                                        let referenceEnergy = energy(a[ch], stable)
                                        for lag in -8...8 {
                                            var cross = 0.0, candidateEnergy = 0.0
                                            for i in stable {
                                                let x = Double(a[ch][i]), y = Double(b[ch][i + lag])
                                                cross += x * y; candidateEnergy += y * y
                                            }
                                            let correlation = cross / sqrt(referenceEnergy * max(1e-30, candidateEnergy))
                                            if correlation > bestCorrelation { bestCorrelation = correlation; bestLag = lag }
                                        }
                                        let lag96k = Double(bestLag) * Transport.graphRate / outputRate
                                        let nullDB = residualDB(a[ch], b[ch], stable)
                                        let fadeDB = 10 * log10(energy(mixed[ch], fade) / energy(a[ch], fade))
                                        let completedDB = residualDB(b[ch], mixed[ch], stable)
                                        let peak = mixed[ch].map { abs($0) }.max()!
                                        try Transport.require(abs(lag96k) <= 3, "Broadband alignment exceeds three graph frames")
                                        try Transport.require(bestCorrelation > 0.9 && nullDB < -6, "Broadband waveform correlation/residual failed")
                                        try Transport.require(abs(fadeDB) < 0.5, "Broadband fade energy changed by \(fadeDB) dB")
                                        try Transport.require(completedDB < -50, "Broadband fade did not complete")
                                        try Transport.require(b[ch][0..<Int(outputRate * 0.2)].allSatisfy { abs($0) < 1e-6 }, "Broadband replacement started early")
                                        try Transport.require(mixed[ch].allSatisfy(\.isFinite) && peak > 0.001 && peak < 0.3, "Broadband nonfinite/silent/excessive peak")
                                        print(String(format: "BROADBAND source=%.0f output=%.0f signal=%@ phase=%@ quality=%@ seek=%.6f controlMS=%.0f channel=%d nullDB=%.3f fadeDB=%.4f lag96kFrames=%.4f correlation=%.6f peak=%.6f completedDB=%.3f", rate, outputRate, signal, phase.rawValue, quality.rawValue, seek, controlInterval * 1000, ch, nullDB, fadeDB, lag96k, bestCorrelation, peak, completedDB))
                                    }
                                    cases += 1
                                }
                            }
                        }
                    }
                }
            }
        }
        print("PASS: \(cases) broadband/transient stock-mixer handoffs, both channels, variable blocks and delayed gain updates")
    }
}
