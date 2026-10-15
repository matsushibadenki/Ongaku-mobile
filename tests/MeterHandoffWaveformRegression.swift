import AVFoundation
import Foundation

@main struct MeterHandoffWaveformRegression {
    typealias Host = ShippingDSPTransition
    static let rate = 96_000.0
    static let seconds = 0.80
    struct PathCase {
        let name: String
        let old: AVAudioPCMBuffer
        let new: AVAudioPCMBuffer
        let file: URL?
    }
    struct Reading { let input: (Float, Float); let output: (Float, Float) }
    struct Rendered { let pcm: [[Float]]; let gains: [(Double, Float, Float, Float)]; let staleRejects: Int }
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static func setting(_ trim: Double) -> RealtimeAudioEffectSetting {
        var result = RealtimeAudioEffectSetting(kind: .equalizer, isEnabled: true)
        for key in ["lfGain", "hfGain", "lmfGain", "hmfGain"] { result.parameters[key] = 0.5 }
        result.parameters["hpf"] = 0; result.parameters["trim"] = trim
        return result
    }
    static func samples(_ pcm: AVAudioPCMBuffer) -> [[Float]] {
        (0..<2).map { Array(UnsafeBufferPointer(start: pcm.floatChannelData![$0], count: Int(pcm.frameLength))) }
    }
    static func levels(_ data: [[Float]], start: Double) -> (Float, Float) {
        let begin = Int(start * rate), end = min(data[0].count, begin + 960)
        var peak: Float = 0, energy: Double = 0
        for ch in 0..<2 { for i in begin..<end {
            peak = max(peak, abs(data[ch][i])); energy += Double(data[ch][i] * data[ch][i])
        } }
        return (20 * log10(max(1e-6, peak)), Float(10 * log10(max(1e-12, energy / Double((end - begin) * 2)))))
    }
    static func verifyDeferredControls() throws {
        DispatchQueue.main.reset()
        let output = AVAudioMixerNode()
        output.outputVolume = 1
        let host = Host(player: AVAudioPlayerNode(), eq: AVAudioUnitEQ(numberOfBands: 4),
                        output: output, effects: [EqualizerAudioEffect()])
        let enabled = setting(0.5)
        var disabled = enabled; disabled.isEnabled = false
        host.apply(effectSettings: [enabled])
        host.mutations.removeAll()
        host.pendingHandoff = true
        host.applyWithDeclick(effectSettings: [disabled])
        DispatchQueue.main.advance(to: 0.1)
        try require(output.outputVolume == 1 && host.mutations.isEmpty,
                    "Protected bypass muted an occupied handoff: volume=\(output.outputVolume) mutations=\(host.mutations)")
        // Repeated requests replace the pending target without spawning a fade.
        host.apply(effectSettings: [setting(0.55)])
        host.apply(effectSettings: [disabled])
        DispatchQueue.main.advance(to: 0.2)
        try require(output.outputVolume == 1 && host.mutations.isEmpty,
                    "Superseding mode request changed an occupied handoff")
        host.pendingHandoff = nil
        DispatchQueue.main.advance(to: 0.4)
        try require(host.lastAppliedEffectSettings[.equalizer] == disabled
                    && host.pendingDeclickEffectSettings == nil && output.outputVolume == 1,
                    "Deferred bypass did not commit and restore")

        host.pendingHandoff = true
        host.applyWithDeclick(effectSettings: [enabled])
        host.cancelEffectTransitionForStop()
        host.mutations.removeAll()
        host.pendingHandoff = nil
        DispatchQueue.main.advance(to: 0.6)
        try require(host.mutations.isEmpty && output.outputVolume == 1,
                    "Stopped deferred transition wrote a late setting")
        print("PASS: deferred bypass/coalescing preserves output; stop cancels waiting controls")
    }
    // Render the shipping effect separately to obtain pre-trim PCM meter data.
    // Delivery is virtualized later; these are not values invented in dB.
    static func meterOutput(_ pcm: AVAudioPCMBuffer, setting: RealtimeAudioEffectSetting) throws -> [[Float]] {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), effect = EqualizerAudioEffect()
        engine.attach(player); effect.attach(to: engine)
        effect.connectInternalNodes(engine: engine, format: pcm.format)
        engine.connect(player, to: effect.inputNode, format: pcm.format)
        engine.connect(effect.outputNode, to: engine.mainMixerNode, format: pcm.format)
        try engine.enableManualRenderingMode(.offline, format: pcm.format, maximumFrameCount: 512)
        effect.apply(setting: setting)
        player.scheduleBuffer(pcm); try engine.start(); player.play()
        defer { player.stop(); engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: 512)!
        var output = [[Float](), [Float]()]
        while output[0].count < Int(pcm.frameLength) {
            let n = AVAudioFrameCount(min(512, Int(pcm.frameLength) - output[0].count))
            try require(try engine.renderOffline(n, to: buffer) == .success, "Meter calibration render failed")
            for ch in 0..<2 { output[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(n))) }
        }
        return output
    }

    static func render(_ path: PathCase, outputRate: Double, seek: Double, delayedControls: Bool,
                       adversarial: Bool, oldReading: Reading, freshReadings: [Reading]) throws -> Rendered {
        DispatchQueue.main.reset()
        let engine = AVAudioEngine(), old = AVAudioPlayerNode(), new = AVAudioPlayerNode()
        let sourceMixer = AVAudioMixerNode(), output = AVAudioMixerNode(), eq = AVAudioUnitEQ(numberOfBands: 4)
        let effect = EqualizerAudioEffect()
        let host = Host(player: old, eq: eq, output: output, effects: [effect])
        host.useObservedMeters = true; host.useRealGainPath = true
        host.acceptStaleForNegativeControl = adversarial && CommandLine.arguments.contains("--stale-fixture")
        host.ignoreHandoffForNegativeControl = adversarial && CommandLine.arguments.contains("--handoff-fixture")
        host.meterLevels = LegacyMeterLevelStore(count: 3)
        let format = path.new.format
        let final = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        for node in [old, new, sourceMixer, host.inputGainEQ, host.loudnessCompensationEQ, eq, host.outputSafetyEQ, output] as [AVAudioNode] { engine.attach(node) }
        engine.connect(old, to: sourceMixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(new, to: sourceMixer, fromBus: 0, toBus: 1, format: format)
        engine.connect(sourceMixer, to: host.inputGainEQ, format: format)
        engine.connect(host.inputGainEQ, to: host.loudnessCompensationEQ, format: format)
        engine.connect(host.loudnessCompensationEQ, to: eq, format: format)
        effect.attach(to: engine); effect.connectInternalNodes(engine: engine, format: format)
        engine.connect(eq, to: effect.inputNode, format: format)
        engine.connect(effect.outputNode, to: host.outputSafetyEQ, format: format)
        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        let ceiling = AVAudioUnitEQ(numberOfBands: 0)
        engine.attach(limiter); engine.attach(ceiling); host.outputLimiter = limiter
        EffectOutputSafety.configure(limiter: limiter); ceiling.globalGain = EffectOutputSafety.ceilingDB
        engine.connect(host.outputSafetyEQ, to: limiter, format: format)
        engine.connect(limiter, to: ceiling, format: format)
        engine.connect(ceiling, to: output, format: format)
        engine.connect(output, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: final, maximumFrameCount: 512)
        let initial = setting(0.5), latest = setting(0.52)
        host.signalDiagnostics = Host.analyzeSignalLevels(in: path.old)
        host.applyLoudnessCompensation(for: 0.8); host.apply(effectSettings: [initial])
        let sourceRate = try path.file.map { try AVAudioFile(forReading: $0).processingFormat.sampleRate } ?? rate
        let sourceFrame = Int64(seek * sourceRate), offset = Double(sourceFrame) / sourceRate
        let plan = PlaybackHandoffClock.plan(sourceOffset: offset, renderedFrames: 0,
            sourceSampleRate: sourceRate, leadFromRenderTime: 0.30, targetSampleRate: rate,
            targetFrameCount: Int64(path.new.frameLength))!
        if let url = path.file {
            let file = try AVAudioFile(forReading: url)
            old.scheduleSegment(file, startingFrame: sourceFrame, frameCount: AVAudioFrameCount(file.length - sourceFrame), at: nil)
        } else {
            old.scheduleBuffer(ShippingSincMeasurement.playbackSlice(from: path.old, startingFrame: sourceFrame,
                frameCount: path.old.frameLength - AVAudioFrameCount(sourceFrame))!)
        }
        let faultOffset = adversarial && CommandLine.arguments.contains("--offset-fixture") ? 8 : 0
        let newFrame = plan.startFrame + Int64(faultOffset)
        new.scheduleBuffer(ShippingSincMeasurement.playbackSlice(from: path.new, startingFrame: newFrame,
            frameCount: path.new.frameLength - AVAudioFrameCount(newFrame))!,
            at: AVAudioTime(sampleTime: Int64((plan.delayFromRenderTime * rate).rounded()), atRate: rate))
        old.volume = 1; new.volume = 0
        try engine.start(); old.play(); new.play()
        defer { old.stop(); new.stop(); engine.stop() }
        host.gainWrites.removeAll(); host.mutations.removeAll()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { host.apply(effectSettings: [latest]) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            host.pendingHandoff = true
            host.invalidateEffectLevelAudits()
            host.signalDiagnostics = Host.analyzeSignalLevels(in: path.new)
            host.applyAutomaticDSPProfile(.init(lowShelfGainDB: 0.4, lowMidGainDB: 0,
                                                presenceGainDB: 0.2, highShelfGainDB: 0.3))
        }
        var rejects = 0
        func deliver(_ reading: Reading, inputTime: Double, outputTime: Double) {
            host.meterLevels.tryUpdate(index: 0, levels: EffectMeterObservation(
                peakDBFS: reading.input.0, rmsDBFS: reading.input.1, renderedAt: inputTime, duration: 0.01))
            host.meterLevels.tryUpdate(index: 1, levels: EffectMeterObservation(
                peakDBFS: reading.output.0, rmsDBFS: reading.output.1, renderedAt: outputTime, duration: 0.01))
            if host.refreshEffectLevelAudits().isEmpty { rejects += 1 }
        }
        if adversarial {
            // Old graph PCM arrives during the lead, fade and after completion.
            for arrival in [0.23, 0.32, 0.48, 0.72] {
                DispatchQueue.main.asyncAfter(deadline: .now() + arrival) {
                    deliver(oldReading, inputTime: 0.05, outputTime: 0.15)
                }
            }
        }
        // Fresh readings, then duplicates; an old callback after these must not
        // replace them. Separate reference/candidate graphs use the same schedule.
        for (index, arrival) in [0.56, 0.60, 0.64, 0.68].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + arrival) {
                deliver(freshReadings[index], inputTime: arrival - 0.04, outputTime: arrival - 0.04)
            }
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: final, frameCapacity: 512)!
        var result = [[Float](), [Float]()], nextControl = 0.0, nextGain = 0.0
        var finished = false, finishTime = Double.infinity, block = 0
        while result[0].count < Int(seconds * outputRate) {
            let time = Double(engine.manualRenderingSampleTime) / outputRate
            DispatchQueue.main.advance(to: time)
            if time >= nextControl {
                let elapsed = max(0, time - plan.delayFromRenderTime)
                let progress = PlaybackHandoffClock.fadeProgress(renderedFrames: Int64((elapsed * rate).rounded()), sampleRate: rate)!
                old.volume = 1 - progress; new.volume = progress
                if progress >= 1 && !finished {
                    finished = true; finishTime = time
                    host.invalidateEffectLevelAudits(); host.pendingHandoff = nil
                    host.commitPendingDSPChangesIfReady()
                }
                nextControl = time + (delayedControls ? 0.016 : 0)
            }
            // Exercise the real gain consumer at an explicit 20 ms cadence.
            // This is a test stimulus, not a new production gain polling loop.
            if time >= nextGain {
                host.applyGainStaging(effectSettings: [latest]); nextGain = time + 0.02
            }
            if adversarial && CommandLine.arguments.contains("--mute-fixture") {
                output.outputVolume = time >= 0.31 && time < 0.35 ? 0 : 1
            }
            let pattern = [127, 256, 384, 191, 512]
            let n = AVAudioFrameCount(min(pattern[block % pattern.count], Int(seconds * outputRate) - result[0].count)); block += 1
            try require(try engine.renderOffline(n, to: buffer) == .success, "Combined render failed")
            for ch in 0..<2 { result[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(n))) }
        }
        try require(host.mutations.filter { $0.1 >= 0.20 && $0.1 < finishTime }.isEmpty,
                    "Shared effect/gain changed during source handoff")
        try require(host.lastAppliedEffectSettings[.equalizer] == latest && host.pendingDeclickEffectSettings == nil,
                    "Latest parameters lost after handoff")
        try require(host.pendingAutomaticDSPProfile == nil, "DSP profile not resumed after handoff")
        return Rendered(pcm: result, gains: host.gainWrites, staleRejects: rejects)
    }

    static func run() throws {
        setbuf(stdout, nil)
        if CommandLine.arguments.contains("--continuous") {
            try ContinuousMeterHandoffRegression.run(); return
        }
        try verifyDeferredControls()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: dir) }
        func signal(_ sampleRate: Double) -> AVAudioPCMBuffer {
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
            let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sampleRate * 1.1))!
            pcm.frameLength = pcm.frameCapacity
            for ch in 0..<2 { for i in 0..<Int(pcm.frameLength) {
                let t = Double(i) / sampleRate
                let amplitude = t < 0.14 ? 0.006 : 0.12
                let a = sin(2 * Double.pi * (ch == 0 ? 997.0 : 1301.0) * t)
                let b = sin(2 * Double.pi * (137 * t + 3800 * t * t))
                let transient = i % 13000 < 350 ? sin(2 * Double.pi * 8000 * t) : 0
                pcm.floatChannelData![ch][i] = Float(amplitude * (a + 0.4 * b + 0.2 * transient))
            } }
            return pcm
        }
        let base = signal(rate)
        func wet(_ preset: HeadphoneHRTFPreset) throws -> AVAudioPCMBuffer {
            let pcm = try ShippingHRTF.clonePlaybackBuffer(from: base)
            try ShippingHRTF.applyHeadphoneVirtualizationIfNeeded(to: pcm,
                settings: HeadphoneSpatialSettings(isEnabled: true, preset: preset, spatial: 0.8, crossfeed: 0.7), routeSupportsSpatial: true)
            return pcm
        }
        let natural = try wet(.natural), frontal = try wet(.frontal), wide = try wet(.wide), studio = try wet(.studio)
        var paths = [PathCase(name: "spatial-enable", old: base, new: natural, file: nil),
                     PathCase(name: "spatial-disable", old: frontal, new: base, file: nil),
                     PathCase(name: "natural-frontal", old: natural, new: frontal, file: nil),
                     PathCase(name: "wide-studio", old: wide, new: studio, file: nil)]
        for (phase, inputRate) in [(PrecisionSincPhaseMode.linear, 44_100.0), (.minimumPhase, 48_000.0), (.apodizing, 44_100.0)] {
            let source = signal(inputRate), url = dir.appendingPathComponent("\(phase.rawValue).caf")
            var fileSettings = source.format.settings; fileSettings[AVLinearPCMIsNonInterleaved] = false
            do { let file = try AVAudioFile(forWriting: url, settings: fileSettings); try file.write(from: source) }
            let prepared = try ShippingSincMeasurement.makeChunkedPrecisionSincPlaybackBuffer(
                from: AVAudioFile(forReading: url), sourceFrameCount: source.frameLength,
                sourceFormat: source.format, targetFormat: base.format, phaseMode: phase, qualityMode: .standard)
            paths.append(PathCase(name: "quality-\(phase.rawValue)", old: base, new: prepared, file: url))
        }
        if CommandLine.arguments.contains("--quick") { paths = Array(paths.prefix(1)) }
        var cases = 0, maxDifference: Float = 0, maxPeak: Float = 0, minRatio = Double.infinity
        for path in paths {
            let oldOut = try meterOutput(path.old, setting: setting(0.5))
            let newOut = try meterOutput(path.new, setting: setting(0.52))
            let oldReading = Reading(input: levels(samples(path.old), start: 0.05), output: levels(oldOut, start: 0.15))
            for outputRate in CommandLine.arguments.contains("--quick") ? [48_000.0] : [44_100.0, 48_000.0, 96_000.0] {
                for seek in CommandLine.arguments.contains("--quick") ? [0.0] : [0.0, 0.123457] {
                    let freshReadings = [0.56, 0.60, 0.64, 0.68].map { arrival in
                        Reading(input: levels(samples(path.new), start: seek + arrival - 0.04),
                                output: levels(newOut, start: seek + arrival - 0.04))
                    }
                    let baseline = try render(path, outputRate: outputRate, seek: seek, delayedControls: seek != 0,
                                              adversarial: false, oldReading: oldReading, freshReadings: freshReadings)
                    let candidate = try render(path, outputRate: outputRate, seek: seek, delayedControls: seek != 0,
                                               adversarial: true, oldReading: oldReading, freshReadings: freshReadings)
                    for ch in 0..<2 {
                        let a = baseline.pcm[ch], b = candidate.pcm[ch]
                        let difference = zip(a, b).map { abs($0 - $1) }.max()!
                        maxDifference = max(maxDifference, difference)
                        let peak = b.map { abs($0) }.max()!; maxPeak = max(maxPeak, peak)
                        try require(b.allSatisfy(\.isFinite) && peak < 0.895, "Combined output nonfinite/over-ceiling")
                        let window = Int(outputRate * 0.01)
                        for start in stride(from: Int(outputRate * 0.20), to: Int(outputRate * 0.76), by: window) {
                            let range = start..<start + window
                            let refEnergy = range.reduce(0.0) { $0 + Double(a[$1] * a[$1]) }
                            let energy = range.reduce(0.0) { $0 + Double(b[$1] * b[$1]) }
                            let ratio = sqrt(energy / max(refEnergy, 1e-20)); minRatio = min(minRatio, ratio)
                            try require(ratio > 0.9, "Delayed meter handoff created a level dip")
                            try require(energy / Double(window) > 1e-8, "Combined handoff has a silent window")
                        }
                        try require(difference < 2e-6, "Delayed meter or timeline changed reference waveform")
                    }
                    try require(candidate.gains.count == baseline.gains.count, "Delayed readings changed gain cadence")
                    for (a, b) in zip(candidate.gains, baseline.gains) {
                        try require(a.0 == b.0 && a.1 == b.1 && a.2 == b.2 && a.3 == b.3, "Delayed readings changed gain plan")
                    }
                    try require(candidate.staleRejects >= 3, "Stale measurements were not rejected")
                    cases += 1
                    print("COMBINED \(path.name) output=\(Int(outputRate)) seek=\(seek)")
                }
            }
        }
        print(String(format: "PASS: %d stereo meter/handoff cases; maxSampleDifference=%.9f min10msRMSRatio=%.6f maximumPeak=%.6f", cases, maxDifference, minRatio, maxPeak))
    }
    static func main() {
        do { try run() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
