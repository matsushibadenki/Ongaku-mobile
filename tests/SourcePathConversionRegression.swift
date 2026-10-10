import AVFoundation
import Foundation

// Measurement contract: stereo float PCM, unity stock mixer, 96 kHz internal
// graph, no effects. This isolates source and final-output conversion; it does
// not model precision-sinc preparation, device clocks, or a running handoff.
#if !EXTENDED_SOURCE_MEASUREMENT
@main
#endif
struct SourcePathConversionRegression {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }

    static func prepared(_ source: AVAudioPCMBuffer, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let converter = AVAudioConverter(from: source.format, to: format)!
        let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * format.sampleRate / source.format.sampleRate)) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if consumed { state.pointee = .endOfStream; return nil }
            consumed = true
            state.pointee = .haveData
            return source
        }
        if let error { throw error }
        try require(status == .haveData || status == .endOfStream, "PCM conversion failed")
        return output
    }

    static func render(file: AVAudioFile, pcm: AVAudioPCMBuffer?, outputRate: Double, effectTab: AudioEffectPageTab? = nil) throws -> [[Float]] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        let internalFormat = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let outputFormat = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        engine.attach(player); engine.attach(mixer)
        engine.connect(player, to: mixer, format: internalFormat)
        let effects = effectTab == nil ? [] : AudioEffectModuleRegistry.makePipeline()
        var upstream: AVAudioNode = mixer
        for effect in effects {
            effect.attach(to: engine)
            effect.connectInternalNodes(engine: engine, format: internalFormat)
            engine.connect(upstream, to: effect.inputNode, format: internalFormat)
            upstream = effect.outputNode
        }
        if effectTab != nil {
            let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            let ceiling = AVAudioUnitEQ(numberOfBands: 0)
            engine.attach(limiter); engine.attach(ceiling)
            EffectOutputSafety.configure(limiter: limiter)
            ceiling.globalGain = EffectOutputSafety.ceilingDB
            engine.connect(upstream, to: limiter, format: internalFormat)
            engine.connect(limiter, to: ceiling, format: internalFormat)
            upstream = ceiling
        }
        engine.connect(upstream, to: engine.mainMixerNode, format: internalFormat)
        try engine.enableManualRenderingMode(.offline, format: outputFormat, maximumFrameCount: 1024)
        if let effectTab {
            for effect in effects {
                var setting = RealtimeAudioEffectSetting(kind: effect.kind,
                    isEnabled: AudioEffectModuleRegistry.activeKinds(for: effectTab).contains(effect.kind))
                setting.parameters["flutter"] = 0 // Deterministic measurement; no timer modulation.
                effect.apply(setting: setting)
            }
        }
        if let pcm { player.scheduleBuffer(pcm) }
        else { player.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(file.length), at: nil) }
        try engine.start(); player.play()
        defer { player.stop(); engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 1024)!
        var result = [[Float](), [Float]()]
        let length = Int(outputRate)
        while result[0].count < length {
            let count = AVAudioFrameCount(min(1024, length - result[0].count))
            let status = try engine.renderOffline(count, to: buffer)
            try require(status == .success && buffer.frameLength == count, "Offline render failed")
            for channel in 0..<2 {
                result[channel].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(count)))
            }
        }
        try require(result.flatMap { $0 }.allSatisfy(\.isFinite), "Nonfinite conversion output")
        return result
    }

    static func main() throws {
        setbuf(stdout, nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cases = 0
        for sourceRate in [44_100.0, 48_000.0] {
            for frequency in [0.0, 997.0, 12_000.0] {
                let format = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
                let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sourceRate))!
                source.frameLength = source.frameCapacity
                for ch in 0..<2 {
                    for i in 0..<Int(source.frameLength) {
                        source.floatChannelData![ch][i] = Float((ch == 0 ? 0.2 : -0.1) *
                            (frequency == 0 ? (i == Int(sourceRate / 4) ? 1 : 0) : sin(2 * .pi * frequency * Double(i) / sourceRate)))
                    }
                }
                let url = directory.appendingPathComponent("signal.caf")
                var settings = format.settings
                settings[AVLinearPCMIsNonInterleaved] = false
                do { let writer = try AVAudioFile(forWriting: url, settings: settings); try writer.write(from: source) }
                let pcm = try prepared(source, format: AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!)
                for outputRate in [44_100.0, 48_000.0, 96_000.0] {
                    let normal = try render(file: AVAudioFile(forReading: url), pcm: nil, outputRate: outputRate)
                    let converted = try render(file: AVAudioFile(forReading: url), pcm: pcm, outputRate: outputRate)
                    for ch in 0..<2 {
                        let a = normal[ch], b = converted[ch]
                        let peakA = a.map { abs($0) }.max()!, peakB = b.map { abs($0) }.max()!
                        try require(peakA > 0.01 && peakB > 0.01 && peakA < 0.3 && peakB < 0.3, "Silent or excessive output")
                        if frequency == 0 {
                            let indexA = a.indices.max { abs(a[$0]) < abs(a[$1]) }!
                            let indexB = b.indices.max { abs(b[$0]) < abs(b[$1]) }!
                            // Final SRC may add common delay. Bound it to 1 ms and require
                            // the two source paths to align within one output frame.
                            let expected = Int(outputRate / 4)
                            try require(abs(indexA - expected) <= Int(outputRate * 0.001) && abs(indexB - expected) <= Int(outputRate * 0.001) && abs(indexB - indexA) <= 1, "Impulse timing shifted: file=\(indexA), pcm=\(indexB), expected=\(expected)")
                            print("IMPULSE source=\(Int(sourceRate)) output=\(Int(outputRate)) channel=\(ch) fileFrame=\(indexA) pcmFrame=\(indexB) delay=\(indexB - indexA)")
                        } else {
                            let range = Int(outputRate * 0.1)..<Int(outputRate * 0.9)
                            let energyA = range.reduce(0.0) { $0 + Double(a[$1]) * Double(a[$1]) }
                            let energyB = range.reduce(0.0) { $0 + Double(b[$1]) * Double(b[$1]) }
                            let errorEnergy = range.reduce(0.0) { $0 + pow(Double(a[$1] - b[$1]), 2) }
                            let gain = 10 * log10(energyB / energyA)
                            let nullDB = errorEnergy == 0 ? -Double.infinity : 10 * log10(errorEnergy / energyA)
                            let expectedEnergy = Double(range.count) * pow(ch == 0 ? 0.2 : 0.1, 2) / 2
                            try require(abs(10 * log10(energyA / expectedEnergy)) < 0.1, "Final SRC level mismatch")
                            try require(abs(gain) < 0.1, "Source conversion level mismatch")
                            try require(nullDB < -40, "Source conversion null mismatch")
                            print(String(format: "SINE source=%.0f output=%.0f frequency=%.0f channel=%d gainDB=%.6f nullDB=%.3f", sourceRate, outputRate, frequency, ch, gain, nullDB))
                        }
                    }
                    cases += 1
                }
            }
        }
        print("PASS: \(cases) source-path comparisons, both channels; 96 kHz internal graph")
    }
}
