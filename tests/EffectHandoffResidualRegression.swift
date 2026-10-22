import AVFoundation
import Foundation

@main
#if AUDIO_GAIN_TAIL_AUDIT
@MainActor
#endif
struct EffectHandoffResidualRegression {
    static func main() {
        do { try run() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        setbuf(stdout, nil)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let target = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        var cases = 0
        for sourceRate in [44_100.0, 48_000.0] {
            for signal in ["multitone", "tail"] {
                let format = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
                let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sourceRate))!
                source.frameLength = source.frameCapacity
                for ch in 0..<2 { for i in 0..<Int(source.frameLength) {
                    let t = Double(i) / sourceRate
                    let x = [137.0, 997, 3901, 8033, 12007, 16001].enumerated().reduce(0.0) {
                        $0 + 0.025 * sin(2 * .pi * $1.element * t + Double($1.offset) * 0.37)
                    }
                    let window = signal == "multitone" ? 1 : (t > 0.15 && t < 0.23 ? pow(sin(.pi * (t - 0.15) / 0.08), 2) : 0)
                    source.floatChannelData![ch][i] = Float(x * window * (ch == 0 ? 1 : -0.6))
                } }
                let url = folder.appendingPathComponent("source.caf")
                var settings = format.settings; settings[AVLinearPCMIsNonInterleaved] = false
                do { let writer = try AVAudioFile(forWriting: url, settings: settings); try writer.write(from: source) }
                for phase in [PrecisionSincPhaseMode.linear, .minimumPhase, .apodizing] {
                    let file = try AVAudioFile(forReading: url)
                    let pcm = try ShippingSincMeasurement.makeChunkedPrecisionSincPlaybackBuffer(from: file,
                        sourceFrameCount: AVAudioFrameCount(file.length), sourceFormat: format,
                        targetFormat: target, phaseMode: phase, qualityMode: .master)
                    for outputRate in [44_100.0, 48_000.0, 96_000.0] {
                        for name in ["space", "gloss"] {
                            for interval in [0.004, 0.020] {
                                func render(_ path: Int) throws -> [Float] {
                                    let effect: AudioEffectNode = name == "space" ? SpaceAudioEffect() : GlossAudioEffect()
                                    return try PlaybackHandoffWaveformRegression.render(file: AVAudioFile(forReading: url),
                                        pcm: pcm, seek: 0, outputRate: outputRate, path: path, block: 127,
                                        blockPattern: [127, 256, 384], controlInterval: interval, effect: effect,
                                        resetTailAtHandoff: CommandLine.arguments.contains("--reset-rack" )).0.flatMap { $0 }
                                }
                                let reference = try render(0), mixed = try render(2)
                                for ch in 0..<2 {
                                    let offset = ch * Int(outputRate * 0.5)
                                    let range = (offset + Int(outputRate * 0.36))..<(offset + Int(outputRate * 0.46))
                                    let energy = range.reduce(0.0) { $0 + pow(Double(reference[$1]), 2) }
                                    let error = range.reduce(0.0) { $0 + pow(Double(reference[$1] - mixed[$1]), 2) }
                                    let residualDB = 10 * log10(max(1e-30, error) / max(1e-30, energy))
                                    let mixedEnergy = range.reduce(0.0) { $0 + pow(Double(mixed[$1]), 2) }
                                    let levelDB = 10 * log10(max(1e-30, mixedEnergy) / max(1e-30, energy))
                                    try PlaybackHandoffWaveformRegression.require(energy > 1e-10, "Empty effect reference")
                                    try PlaybackHandoffWaveformRegression.require(mixed.allSatisfy(\.isFinite), "Nonfinite effect handoff")
                                    try PlaybackHandoffWaveformRegression.require(residualDB < (signal == "tail" ? -70 : -6), "Shared rack residual failed: \(signal) \(residualDB)")
                                    try PlaybackHandoffWaveformRegression.require(abs(levelDB) < 0.5, "Handoff changed effect level")
                                    if signal == "multitone" {
                                        var bestLag = 0, bestCorrelation = -Double.infinity
                                        for lag in -8...8 {
                                            var cross = 0.0, candidateEnergy = 0.0
                                            for i in range {
                                                cross += Double(reference[i]) * Double(mixed[i + lag])
                                                candidateEnergy += pow(Double(mixed[i + lag]), 2)
                                            }
                                            let correlation = cross / sqrt(energy * max(1e-30, candidateEnergy))
                                            if correlation > bestCorrelation { bestCorrelation = correlation; bestLag = lag }
                                        }
                                        let lagFrames = Double(bestLag) * 96_000 / outputRate
                                        try PlaybackHandoffWaveformRegression.require(abs(lagFrames) <= 3 && bestCorrelation > 0.9,
                                            "Effect handoff alignment failed")
                                        print("EFFECT_ALIGNMENT effect=\(name) source=\(Int(sourceRate)) output=\(Int(outputRate)) phase=\(phase.rawValue) lag96kFrames=\(lagFrames) correlation=\(bestCorrelation)")
                                    }
                                    print("EFFECT_HANDOFF source=\(Int(sourceRate)) output=\(Int(outputRate)) effect=\(name) signal=\(signal) phase=\(phase.rawValue) controlMS=\(interval*1000) channel=\(ch) residualDB=\(residualDB) levelDB=\(levelDB)")
                                }
                                cases += 1
                            }
                        }
                    }
                }
            }
        }
        print("PASS: \(cases) shared-rack effect handoffs, both channels; variable blocks, 4/20 ms controls, preserved tails")
    }
}
