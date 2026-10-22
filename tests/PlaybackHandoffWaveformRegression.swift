import AVFoundation
import Foundation

/// Shipping stock-mixer transport, shipping sinc/slice code and clock plan.
/// Offline sample clocks stand in for device host clocks; main-thread timer
/// jitter and changing DSP settings are deliberately outside this contract.
#if !EXTENDED_HANDOFF_MEASUREMENT
@main
#endif
#if AUDIO_GAIN_TAIL_AUDIT
@MainActor
#endif
struct PlaybackHandoffWaveformRegression {
    static let graphRate = 96_000.0
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func render(file: AVAudioFile, pcm: AVAudioPCMBuffer, seek: Double,
                       outputRate: Double, path: Int, block: Int, blockPattern: [Int] = [],
                       controlInterval: Double = 0, effect: AudioEffectNode? = nil, resetTailAtHandoff: Bool = false) throws -> ([[Float]], PlaybackHandoffClock.Plan) {
        let engine = AVAudioEngine(), old = AVAudioPlayerNode(), new = AVAudioPlayerNode(), mixer = AVAudioMixerNode()
        let graph = AVAudioFormat(standardFormatWithSampleRate: graphRate, channels: 2)!
        let output = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        for node in [old, new, mixer] as [AVAudioNode] { engine.attach(node) }
        engine.connect(old, to: mixer, format: graph)
        engine.connect(new, to: mixer, format: graph)
#if AUDIO_GAIN_TAIL_AUDIT
        let effectGain = AudioThreadGainStage(gain: 1), transportGain = AudioThreadGainStage(gain: 1)
        engine.attach(effectGain.node); engine.attach(transportGain.node)
        engine.connect(effectGain.node, to: transportGain.node, format: graph)
        engine.connect(transportGain.node, to: engine.mainMixerNode, format: graph)
        let outputInput: AVAudioNode = effectGain.node
#else
        let outputInput: AVAudioNode = engine.mainMixerNode
#endif
        if let effect {
            effect.attach(to: engine)
            effect.connectInternalNodes(engine: engine, format: graph)
            engine.connect(mixer, to: effect.inputNode, format: graph)
            engine.connect(effect.outputNode, to: outputInput, format: graph)
            effect.apply(setting: RealtimeAudioEffectSetting(kind: effect.kind, isEnabled: true))
        } else {
            engine.connect(mixer, to: outputInput, format: graph)
        }
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 1024)
        let sourceFrame = Int64(seek * file.processingFormat.sampleRate)
        let offset = Double(sourceFrame) / file.processingFormat.sampleRate
        let plan = PlaybackHandoffClock.plan(sourceOffset: offset, renderedFrames: 0,
            sourceSampleRate: file.processingFormat.sampleRate, leadFromRenderTime: 0.25,
            targetSampleRate: pcm.format.sampleRate, targetFrameCount: Int64(pcm.frameLength))!
        old.scheduleSegment(file, startingFrame: sourceFrame, frameCount: AVAudioFrameCount(file.length - sourceFrame), at: nil)
        // Negative control changes the content position without changing its clock.
        let sliceFrame = plan.startFrame + (CommandLine.arguments.contains("--misaligned-fixture") ? 8 : 0)
        let slice = ShippingSincMeasurement.playbackSlice(from: pcm, startingFrame: sliceFrame,
            frameCount: pcm.frameLength - AVAudioFrameCount(sliceFrame))!
        new.scheduleBuffer(slice, at: AVAudioTime(sampleTime: Int64((plan.delayFromRenderTime * graphRate).rounded()), atRate: graphRate))
        old.volume = 1
        new.volume = path == 1 ? 1 : 0
        try engine.start()
#if AUDIO_GAIN_TAIL_AUDIT
        effectGain.synchronizeAfterStart(); transportGain.synchronizeAfterStart()
#endif
        old.play()
        new.play()
        defer { old.stop(); new.stop(); engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1024)!
        var result = [[Float](), [Float]()]
        var blockIndex = 0
        var nextControlTime = 0.0
        var completedHandoff = false
        while result[0].count < Int(outputRate * 0.5) {
            let renderSeconds = Double(engine.manualRenderingSampleTime) / outputRate
            if path == 2 && renderSeconds >= nextControlTime {
                // Render-clock control-rate fallback. Updates are deliberately
                // quantized to the render block, as on the shipping main timer.
                let elapsed = Double(engine.manualRenderingSampleTime) / outputRate - plan.delayFromRenderTime
                let progress = PlaybackHandoffClock.fadeProgress(renderedFrames: Int64(max(0, elapsed * graphRate).rounded()), sampleRate: graphRate)!
                old.volume = 1 - progress; new.volume = progress
                if effect != nil && progress >= 1 && !completedHandoff {
                    completedHandoff = true
                    old.stop() // Production retires only the old source, not the shared rack.
                    if resetTailAtHandoff { effect?.resetTailState() }
                }
                nextControlTime = renderSeconds + controlInterval
            }
            let requestedBlock = blockPattern.isEmpty ? block : blockPattern[blockIndex % blockPattern.count]
            blockIndex += 1
            let count = AVAudioFrameCount(min(requestedBlock, Int(outputRate * 0.5) - result[0].count))
            try require(try engine.renderOffline(count, to: buffer) == .success, "Handoff render failed")
            for ch in 0..<2 { result[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(count))) }
        }
        return (result, plan)
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
        let target = AVAudioFormat(standardFormatWithSampleRate: graphRate, channels: 2)!
        var cases = 0
        for rate in [44_100.0, 48_000.0] {
            for frequency in [997.0, 12_000.0] {
                let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
                let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
                source.frameLength = source.frameCapacity
                for ch in 0..<2 { for i in 0..<Int(source.frameLength) {
                    source.floatChannelData![ch][i] = Float((ch == 0 ? 0.2 : -0.1) * sin(2 * .pi * frequency * Double(i) / rate))
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
                        for seek in [0.0, 0.123457] {
                            for outputRate in [44_100.0, 48_000.0, 96_000.0] {
                                let block = outputRate == 44_100 ? 127 : outputRate == 48_000 ? 256 : 384
                                let (a, plan) = try render(file: AVAudioFile(forReading: url), pcm: pcm, seek: seek, outputRate: outputRate, path: 0, block: block)
                                let (sum, _) = try render(file: AVAudioFile(forReading: url), pcm: pcm, seek: seek, outputRate: outputRate, path: 1, block: block)
                                // Keep the old branch running in every graph. Muting it
                                // can change offline pull/scheduling at 44.1 kHz; use
                                // linear stock-mixer superposition to isolate new PCM.
                                let b = (0..<2).map { ch in zip(sum[ch], a[ch]).map { $0.0 - $0.1 } }
                                let (mixed, _) = try render(file: AVAudioFile(forReading: url), pcm: pcm, seek: seek, outputRate: outputRate, path: 2, block: block)
                                for ch in 0..<2 {
                                    let stable = Int(outputRate * 0.36)..<Int(outputRate * 0.46)
                                    let fade = Int(outputRate * (plan.delayFromRenderTime + 0.02))..<Int(outputRate * (plan.delayFromRenderTime + 0.044))
                                    func energy(_ signal: [Float], _ range: Range<Int>) -> Double { range.reduce(0) { $0 + pow(Double(signal[$1]), 2) } }
                                    let null = stable.reduce(0.0) { $0 + pow(Double(a[ch][$1] - b[ch][$1]), 2) }
                                    let nullDB = 10 * log10(max(1e-30, null) / energy(a[ch], stable))
                                    var realA = 0.0, imagA = 0.0, realB = 0.0, imagB = 0.0
                                    for i in stable {
                                        let angle = 2 * Double.pi * frequency * Double(i) / outputRate
                                        realA += Double(a[ch][i]) * cos(angle); imagA -= Double(a[ch][i]) * sin(angle)
                                        realB += Double(b[ch][i]) * cos(angle); imagB -= Double(b[ch][i]) * sin(angle)
                                    }
                                    let phaseDelta = atan2(imagB, realB) - atan2(imagA, realA)
                                    let wrapped = atan2(sin(phaseDelta), cos(phaseDelta))
                                    let phaseDelayFrames = -wrapped / (2 * .pi * frequency) * graphRate
                                    try require(abs(phaseDelayFrames) < 1.5, "Scheduled phase exceeds 1.5 graph frames")
                                    let fadeDB = 10 * log10(energy(mixed[ch], fade) / energy(a[ch], fade))
                                    let completedError = stable.reduce(0.0) { $0 + pow(Double(mixed[ch][$1] - b[ch][$1]), 2) }
                                    try require(10 * log10(max(1e-30, completedError) / energy(b[ch], stable)) < -50, "Fade did not complete onto replacement")
                                    let prefix = 0..<Int(outputRate * 0.2)
                                    try require(b[ch][prefix].allSatisfy { abs($0) < 1e-6 }, "Replacement started before scheduled time")
                                    try require(mixed[ch].allSatisfy(\.isFinite), "Nonfinite fade")
                                    try require(abs(fadeDB) < 0.3, "Phase cancellation in handoff: \(fadeDB) dB")
                                    // Nonlinear-phase filtering and subframe clock rounding
                                    // intentionally prevent a unity null. Bound their effect.
                                    try require(nullDB < -8, "Scheduled waveform misalignment: \(nullDB) dB rate=\(rate) frequency=\(frequency) phase=\(phase) seek=\(seek)")
                                    print(String(format: "HANDOFF source=%.0f output=%.0f frequency=%.0f phase=%@ quality=%@ seek=%.6f channel=%d nullDB=%.3f fadeDB=%.4f phaseDelay96kFrames=%.4f", rate, outputRate, frequency, phase.rawValue, quality.rawValue, seek, ch, nullDB, fadeDB, phaseDelayFrames))
                                }
                                cases += 1
                            }
                        }
                    }
                }
            }
        }
        print("PASS: \(cases) scheduled stock-mixer waveform/seek comparisons, both channels")
    }
}
