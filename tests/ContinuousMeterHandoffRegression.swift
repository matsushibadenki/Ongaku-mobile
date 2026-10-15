import AVFoundation
import Foundation

/// Offline instrumentation only: identity EQs expose post-render PCM without
/// AVAudioEngine tap dispatch. No callback allocation/thread-safety claim is
/// made for this test collector; manual rendering and draining are serial.
private final class RenderPCMCollector {
    let node = AVAudioUnitEQ(numberOfBands: 0)
    var pcm = [[Float](), [Float]()]
    var nextFrame: Int64 = 0
    var clockError = false
    private static let callback: AURenderCallback = { context, flags, stamp, _, frames, buffers in
        guard flags.pointee.contains(.unitRenderAction_PostRender), let buffers else { return noErr }
        let collector = Unmanaged<RenderPCMCollector>.fromOpaque(context).takeUnretainedValue()
        let list = UnsafeMutableAudioBufferListPointer(buffers)
        guard list.count == 2, stamp.pointee.mFlags.contains(.sampleTimeValid),
              Int64(stamp.pointee.mSampleTime) == collector.nextFrame else {
            collector.clockError = true; return noErr
        }
        for ch in 0..<2 {
            guard let pointer = list[ch].mData?.assumingMemoryBound(to: Float.self),
                  list[ch].mDataByteSize >= frames * 4 else { collector.clockError = true; return noErr }
            collector.pcm[ch].append(contentsOf: UnsafeBufferPointer(start: pointer, count: Int(frames)))
        }
        collector.nextFrame += Int64(frames)
        return noErr
    }
    func install() throws {
        try ContinuousMeterHandoffRegression.require(AudioUnitAddRenderNotify(node.audioUnit, Self.callback,
            Unmanaged.passUnretained(self).toOpaque()) == noErr, "Cannot install PCM collector")
    }
    func remove() {
        AudioUnitRemoveRenderNotify(node.audioUnit, Self.callback, Unmanaged.passUnretained(self).toOpaque())
    }
    func observation(start: Int, count: Int) -> EffectMeterObservation {
        var peak: Float = 0, energy = 0.0
        for ch in 0..<2 { for i in start..<start + count {
            let sample = pcm[ch][i]; peak = max(peak, abs(sample)); energy += Double(sample) * Double(sample)
        } }
        return EffectMeterObservation(peakDBFS: 20 * log10(max(1e-6, peak)),
            rmsDBFS: Float(10 * log10(max(1e-12, energy / Double(2 * count)))),
            renderedAt: Double(start) / 96_000, duration: Double(count) / 96_000)
    }
}

/// Windowed-sinc reconstruction, not an ITU-certified true-peak meter or a
/// production limiter. Include every original sample; only reconstruct where
/// the complete kernel fits, avoiding invented silence at cropped boundaries.
enum ReconstructedPeak {
    static func measure(_ pcm: [[Float]], factor: Int = 8) -> Float {
        let radius = 48
        let kernels: [[Double]] = (1..<factor).map { phase in
            let fraction = Double(phase) / Double(factor)
            var kernel = (-radius...radius).map { offset -> Double in
                let x = fraction - Double(offset)
                guard abs(x) < Double(radius) else { return 0 }
                let sinc = abs(x) < 1e-12 ? 1 : sin(.pi * x) / (.pi * x)
                let window = 0.42 + 0.5 * cos(.pi * x / Double(radius)) + 0.08 * cos(2 * .pi * x / Double(radius))
                return sinc * window
            }
            let sum = kernel.reduce(0, +)
            for i in kernel.indices { kernel[i] /= sum }
            return kernel
        }
        var maximum = pcm.flatMap { $0 }.map { abs($0) }.max() ?? 0
        for channel in pcm {
            // No threshold pruning. A captured stream may continue beyond its
            // last sample; do not fabricate a discontinuity by zero-padding it.
            guard channel.count > 2 * radius else { continue }
            for i in radius..<channel.count - radius {
                for kernel in kernels {
                    var value = 0.0
                    for offset in -radius...radius {
                        value += Double(channel[i + offset]) * kernel[offset + radius]
                    }
                    maximum = max(maximum, Float(abs(value)))
                }
            }
        }
        return maximum
    }
    static func validate() throws {
        // An Fs/4 sine at pi/4 has a known between-sample maximum.
        let tone = (0..<4096).map { Float(1.12 * sin(.pi * Double($0) / 2 + .pi / 4)) }
        // Taper endpoints so this is a sinusoid test, not an abrupt truncation test.
        let tapered = tone.enumerated().map { i, x in x * Float(min(1, Double(min(i, tone.count - 1 - i)) / 128)) }
        let sample = tapered.map { abs($0) }.max()!
        let eight = measure([tapered]), sixteen = measure([tapered], factor: 16)
        try ContinuousMeterHandoffRegression.require(sample < 0.8 && abs(eight - 1.12) < 0.001
            && abs(eight - sixteen) < 0.0001, "Intersample peak calibration failed")
        print("PASS: intersample calibration sample=\(sample) reconstructed8x=\(eight) reconstructed16x=\(sixteen)")
    }
}

enum ContinuousMeterHandoffRegression {
    typealias Host = ShippingDSPTransition
    typealias Shared = MeterHandoffWaveformRegression
    static let rate = 96_000.0
    static let duration = 1.6
    static func require(_ condition: Bool, _ message: String) throws { try Shared.require(condition, message) }
    struct Result {
        let output: [[Float]]
        let source: [[Float]]
        let gains: [(Double, Float, Float, Float)]
        let windows: Int
        let consumed: Int
        let boost: Float
        let latency: Int64
        let finalBoost: Float
    }
    static func settings(_ name: String, latest: Bool) -> [RealtimeAudioEffectSetting] {
        switch name {
        case "eq-feedback": return [Shared.setting(1)]
        case "exciter":
            var s = RealtimeAudioEffectSetting(kind: .exciter, isEnabled: true)
            s.parameters["mode"] = 1; s.parameters["intensity"] = latest ? 0.9 : 0.5
            s.parameters["frequency"] = 0.8
            return [s]
        case "warm-latency":
            var s = RealtimeAudioEffectSetting(kind: .warm, isEnabled: latest)
            s.parameters["flutter"] = 0; s.parameters["drive"] = 0.85
            s.parameters["intensity"] = 0.8
            return [s]
        default:
            var s = RealtimeAudioEffectSetting(kind: .space, isEnabled: true)
            s.parameters["amount"] = 0.8; s.parameters["size"] = latest ? 0.85 : 0.2
            s.parameters["preDelay"] = latest ? 0.9 : 0.1
            return [s]
        }
    }
    static func signal(_ sampleRate: Double, overloaded: Bool) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(2 * sampleRate))!
        pcm.frameLength = pcm.frameCapacity
        for ch in 0..<2 { for i in 0..<Int(pcm.frameLength) {
            let t = Double(i) / sampleRate
            // Quiet/loud changes and short overloads occur before, during and
            // after the handoff; final 400 ms is stationary for settling checks.
            let envelope = t >= 0.90 && t < 1.10 ? 0.01 : 1.0
            let level = envelope * (overloaded ? (t < 0.14 ? 0.01 : (t < 0.8 ? 3.2 : 1.6)) : 0.22)
            let a = sin(2 * .pi * (ch == 0 ? 997.0 : 1301.0) * t)
            let b = sin(2 * .pi * (173 * t + 2700 * min(t, 0.8) * min(t, 0.8)))
            let high = sin(2 * .pi * sampleRate * 0.25 * t + .pi / 4)
            pcm.floatChannelData![ch][i] = Float(level * (0.55 * a + 0.25 * b + 0.45 * high))
        } }
        return pcm
    }
    static func render(_ path: Shared.PathCase, effectName: String, outputRate: Double,
                       adversarial: Bool, modern: Bool, feedback: Bool = true) throws -> Result {
        DispatchQueue.main.reset()
        let engine = AVAudioEngine(), old = AVAudioPlayerNode(), new = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode(), output = AVAudioMixerNode(), eq = AVAudioUnitEQ(numberOfBands: 4)
        let effect: AudioEffectNode
        switch effectName {
        case "exciter": effect = ExciterAudioEffect()
        case "warm-latency": effect = WarmAudioEffect()
        case "eq-feedback": effect = EqualizerAudioEffect()
        default: effect = SpaceAudioEffect()
        }
        let host = Host(player: old, eq: eq, output: output, effects: [effect])
        host.useObservedMeters = true; host.useRealGainPath = true
        host.meterLevels = modern ? ModernMeterLevelStore(count: 3) : LegacyMeterLevelStore(count: 3)
        let source = RenderPCMCollector(), before = RenderPCMCollector(), after = RenderPCMCollector()
        let collectors = [source, before, after]
        let format = path.new.format
        let final = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        for node in [old, new, mixer, output, eq, host.inputGainEQ, host.loudnessCompensationEQ,
                     host.outputSafetyEQ] + collectors.map(\.node) as [AVAudioNode] { engine.attach(node) }
        engine.connect(old, to: mixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(new, to: mixer, fromBus: 0, toBus: 1, format: format)
        engine.connect(mixer, to: source.node, format: format)
        engine.connect(source.node, to: host.inputGainEQ, format: format)
        engine.connect(host.inputGainEQ, to: host.loudnessCompensationEQ, format: format)
        engine.connect(host.loudnessCompensationEQ, to: eq, format: format)
        engine.connect(eq, to: before.node, format: format)
        effect.attach(to: engine); effect.connectInternalNodes(engine: engine, format: format)
        engine.connect(before.node, to: effect.inputNode, format: format)
        engine.connect(effect.outputNode, to: after.node, format: format)
        engine.connect(after.node, to: host.outputSafetyEQ, format: format)
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
        for collector in collectors { try collector.install() }
        defer { for collector in collectors { collector.remove() }; old.stop(); new.stop(); engine.stop() }
        let initial = settings(effectName, latest: false), latest = settings(effectName, latest: true)
        host.signalDiagnostics = Host.analyzeSignalLevels(in: path.old)
        host.applyLoudnessCompensation(for: 0.8); host.apply(effectSettings: initial)
        let initialLatency = effect.estimatedLatencyFrames
        let sourceRate = try path.file.map { try AVAudioFile(forReading: $0).processingFormat.sampleRate } ?? rate
        let sourceFrame = Int64(0.123457 * sourceRate), offset = Double(sourceFrame) / sourceRate
        let plan = PlaybackHandoffClock.plan(sourceOffset: offset, renderedFrames: 0, sourceSampleRate: sourceRate,
            leadFromRenderTime: 0.30, targetSampleRate: rate, targetFrameCount: Int64(path.new.frameLength))!
        if let file = path.file {
            let audioFile = try AVAudioFile(forReading: file)
            old.scheduleSegment(audioFile, startingFrame: sourceFrame,
                frameCount: AVAudioFrameCount(audioFile.length - sourceFrame), at: nil)
        } else {
            old.scheduleBuffer(ShippingSincMeasurement.playbackSlice(from: path.old, startingFrame: sourceFrame,
                frameCount: path.old.frameLength - AVAudioFrameCount(sourceFrame))!)
        }
        let fault = adversarial && CommandLine.arguments.contains("--continuous-offset-fixture") ? 8 : 0
        let start = plan.startFrame + Int64(fault)
        new.scheduleBuffer(ShippingSincMeasurement.playbackSlice(from: path.new, startingFrame: start,
            frameCount: path.new.frameLength - AVAudioFrameCount(start))!,
            at: AVAudioTime(sampleTime: Int64((plan.delayFromRenderTime * rate).rounded()), atRate: rate))
        old.volume = 1; new.volume = 0
        try engine.start(); old.play(); new.play()
        host.gainWrites.removeAll(); host.mutations.removeAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            host.pendingHandoff = true; host.invalidateEffectLevelAudits()
            host.signalDiagnostics = Host.analyzeSignalLevels(in: path.new)
            host.applyAutomaticDSPProfile(.init(lowShelfGainDB: 0.4, lowMidGainDB: 0,
                presenceGainDB: 0.2, highShelfGainDB: 0.3))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { host.apply(effectSettings: latest) }
        let buffer = AVAudioPCMBuffer(pcmFormat: final, frameCapacity: 512)!
        var pcm = [[Float](), [Float]()], nextControl = 0.0, nextGain = 0.0
        var finished = false, finishTime = Double.infinity, block = 0, windowStart = 0, consumed = 0
        var lastConsumed: Double?
        var maxBoost: Float = 0
        while pcm[0].count < Int(duration * outputRate) {
            let time = Double(engine.manualRenderingSampleTime) / outputRate
            DispatchQueue.main.advance(to: time)
            if time >= nextControl {
                let progress = PlaybackHandoffClock.fadeProgress(
                    renderedFrames: Int64((max(0, time - plan.delayFromRenderTime) * rate).rounded()), sampleRate: rate)!
                old.volume = 1 - progress; new.volume = progress
                if progress >= 1 && !finished {
                    finished = true; finishTime = time
                    host.invalidateEffectLevelAudits(); host.pendingHandoff = nil
                    host.commitPendingDSPChangesIfReady()
                }
                nextControl = time + 0.016
            }
            if time >= nextGain {
                host.applyGainStaging(effectSettings: latest); nextGain = time + 0.02
                if let value = host.lastConsumedAuditTime, value != lastConsumed { consumed += 1; lastConsumed = value }
                maxBoost = max(maxBoost, host.smoothedMeasuredEffectBoostDB)
            }
            if adversarial && CommandLine.arguments.contains("--continuous-mute-fixture") {
                output.outputVolume = time >= 0.8 && time < 0.85 ? 0 : 1
            }
            let count = min([127, 256, 384, 191, 512][block % 5], Int(duration * outputRate) - pcm[0].count)
            block += 1
            try require(try engine.renderOffline(AVAudioFrameCount(count), to: buffer) == .success, "Continuous render failed")
            for ch in 0..<2 { pcm[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: count)) }
            // Gather every complete 10 ms PCM window from this render, then feed
            // it back 40 ms after its end. No calibration replay or invented dB.
            while min(before.pcm[0].count, after.pcm[0].count) >= windowStart + 960 {
                let readings = [before, after].map { $0.observation(start: windowStart, count: 960) }
                let arrival = readings[0].renderedAt + 0.01 + 0.04
                func schedule(_ deadline: Double) {
                    DispatchQueue.main.asyncAfter(deadline: TransitionDeadline(seconds: deadline)) {
                        guard feedback else { return }
                        for (index, reading) in readings.enumerated() {
                            let value = adversarial && CommandLine.arguments.contains("--continuous-stamp-fixture")
                                && deadline > arrival + 0.5
                                ? EffectMeterObservation(peakDBFS: reading.peakDBFS, rmsDBFS: reading.rmsDBFS,
                                    renderedAt: deadline - 0.01, duration: reading.duration) : reading
                            host.meterLevels.tryUpdate(index: index, levels: value)
                        }
                    }
                }
                schedule(max(arrival, time + Double(count) / outputRate))
                if adversarial {
                    schedule(arrival + 0.025) // duplicate/reordered PCM
                    schedule(arrival + 0.8875) // late callbacks from much older windows
                }
                windowStart += 960
            }
        }
        try require(collectors.allSatisfy { !$0.clockError && $0.pcm[0].count >= Int(duration * rate) },
                    "Continuous collector lost or repeated render frames")
        try require(windowStart / 960 >= 150 && (!feedback || consumed >= 35), "Continuous feedback was not consumed")
        try require(host.mutations.filter { $0.1 >= 0.20 && $0.1 < finishTime }.isEmpty,
                    "Continuous shared mutation during handoff")
        try require(host.lastAppliedEffectSettings[effect.kind] == latest[0] && host.pendingDeclickEffectSettings == nil
            && host.pendingAutomaticDSPProfile == nil && output.outputVolume == 1, "Continuous latest target lost")
        if effectName == "warm-latency" {
            try require(initialLatency == 0 && effect.estimatedLatencyFrames > 0, "Warm latency did not change")
        }
        return Result(output: pcm, source: source.pcm, gains: host.gainWrites, windows: windowStart / 960,
                      consumed: consumed, boost: maxBoost, latency: effect.estimatedLatencyFrames,
                      finalBoost: host.smoothedMeasuredEffectBoostDB)
    }
    /// Isolate the shipping final safety stage: full-track normalization in
    /// the combined graph can otherwise keep the limiter below overload.
    static func verifyOutputSafety() throws {
        for outputRate in [44_100.0, 48_000.0, 96_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let final = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
            let engine = AVAudioEngine(), player = AVAudioPlayerNode()
            let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            let ceiling = AVAudioUnitEQ(numberOfBands: 0)
            for node in [player, limiter, ceiling] as [AVAudioNode] { engine.attach(node) }
            engine.connect(player, to: limiter, format: format)
            engine.connect(limiter, to: ceiling, format: format)
            engine.connect(ceiling, to: engine.mainMixerNode, format: format)
            EffectOutputSafety.configure(limiter: limiter); ceiling.globalGain = EffectOutputSafety.ceilingDB
            if CommandLine.arguments.contains("--continuous-limiter-fixture") { limiter.bypass = true }
            let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
            source.frameLength = source.frameCapacity
            for ch in 0..<2 { for i in 0..<Int(source.frameLength) {
                let t = Double(i) / rate
                let gain = t < 0.1 ? 0.2 : (t < 0.3 ? 4.0 : 1.12)
                // Ch0: intersample-prone high sine. Ch1: multitone/bursts.
                let value = ch == 0 ? sin(2 * .pi * outputRate * 0.25 * t + .pi / 4)
                    : 0.6 * sin(2 * .pi * 997 * t) + 0.4 * sin(2 * .pi * 13111 * t)
                source.floatChannelData![ch][i] = Float(gain * value)
            } }
            try engine.enableManualRenderingMode(.offline, format: final, maximumFrameCount: 512)
            player.scheduleBuffer(source); try engine.start(); player.play()
            defer { player.stop(); engine.stop() }
            var pcm = [[Float](), [Float]()]
            let buffer = AVAudioPCMBuffer(pcmFormat: final, frameCapacity: 512)!
            while pcm[0].count < Int(outputRate * 0.5) {
                let count = min(512, Int(outputRate * 0.5) - pcm[0].count)
                try require(try engine.renderOffline(AVAudioFrameCount(count), to: buffer) == .success, "Safety render failed")
                for ch in 0..<2 { pcm[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: count)) }
            }
            let sample = pcm.flatMap { $0 }.map { abs($0) }.max()!
            let peak = ReconstructedPeak.measure(pcm)
            try require(pcm.flatMap { $0 }.allSatisfy(\.isFinite) && peak < 1, "Overloaded safety output exceeds 0 dBFS: \(peak)")
            print("SAFETY output=\(Int(outputRate)) inputPeak=\(Shared.samples(source).flatMap { $0 }.map { abs($0) }.max()!) samplePeak=\(sample) reconstructed8x=\(peak)")
        }
    }
    static func run() throws {
        try ReconstructedPeak.validate()
        try verifyOutputSafety()
        let calibration = signal(rate, overloaded: false)
        let convergence = try render(Shared.PathCase(name: "steady-gain", old: calibration, new: calibration, file: nil),
                                     effectName: "eq-feedback", outputRate: 48_000, adversarial: false, modern: true)
        try require(abs(convergence.finalBoost - 4.8) < 0.001, "PCM feedback failed +6 dB convergence: \(convergence.finalBoost)")
        print("PASS: continuously rendered +6 dB EQ converges to weighted gain target 4.8 dB: \(convergence.finalBoost)")
        let quick = CommandLine.arguments.contains("--quick")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var cases = 0
        for overload in quick ? [true] : [false, true] {
            let base = signal(rate, overloaded: overload)
            let spatial = try ShippingHRTF.clonePlaybackBuffer(from: base)
            try ShippingHRTF.applyHeadphoneVirtualizationIfNeeded(to: spatial,
                settings: HeadphoneSpatialSettings(isEnabled: true, preset: .frontal, spatial: 0.8, crossfeed: 0.7),
                routeSupportsSpatial: true)
            let source = signal(44_100, overloaded: overload)
            let url = directory.appendingPathComponent("source-\(overload).caf")
            var fileSettings = source.format.settings; fileSettings[AVLinearPCMIsNonInterleaved] = false
            do { let file = try AVAudioFile(forWriting: url, settings: fileSettings); try file.write(from: source) }
            let prepared = try ShippingSincMeasurement.makeChunkedPrecisionSincPlaybackBuffer(
                from: AVAudioFile(forReading: url), sourceFrameCount: source.frameLength, sourceFormat: source.format,
                targetFormat: base.format, phaseMode: .minimumPhase, qualityMode: .standard)
            let paths = [Shared.PathCase(name: "hrtf", old: base, new: spatial, file: nil),
                         Shared.PathCase(name: "sinc-minimum", old: base, new: prepared, file: url)]
            for path in quick ? Array(paths.prefix(1)) : paths {
                for effect in ["exciter", "space-delay", "warm-latency"] {
                    for outputRate in quick ? [48_000.0] : [44_100.0, 48_000.0, 96_000.0] {
                        let baseline = try render(path, effectName: effect, outputRate: outputRate, adversarial: false, modern: false)
                        let candidate = try render(path, effectName: effect, outputRate: outputRate, adversarial: true, modern: true)
                        if effect == "space-delay" && outputRate == 48_000 && overload && path.name == "hrtf" {
                            let openLoop = try render(path, effectName: effect, outputRate: outputRate,
                                                      adversarial: false, modern: false, feedback: false)
                            let response = zip(candidate.output.flatMap { $0 }, openLoop.output.flatMap { $0 }).map { abs($0 - $1) }.max()!
                            try require(response > 0.0001, "Collected PCM feedback never affected rendered gain")
                            print("PASS: measured feedback changes rendered output by \(response) versus estimate-only control")
                        }
                        let sourceError = zip(baseline.source.flatMap { $0 }, candidate.source.flatMap { $0 }).map { abs($0 - $1) }.max()!
                        try require(sourceError < 2e-6, "Continuous source timeline mismatch")
                        let difference = zip(baseline.output.flatMap { $0 }, candidate.output.flatMap { $0 }).map { abs($0 - $1) }.max()!
                        try require(candidate.output.flatMap { $0 }.allSatisfy(\.isFinite), "Continuous output nonfinite")
                        try require(difference < 2e-5, "Continuous processed reference mismatch: \(difference)")
                        try require(candidate.gains.count == baseline.gains.count, "Continuous gain cadence mismatch")
                        for (a, b) in zip(baseline.gains, candidate.gains) {
                            try require(a.0 == b.0 && abs(a.1 - b.1) < 1e-5 && abs(a.2 - b.2) < 1e-5 && abs(a.3 - b.3) < 1e-5,
                                        "Continuous gain feedback mismatch")
                        }
                        let samplePeak = candidate.output.flatMap { $0 }.map { abs($0) }.max()!
                        let peak = ReconstructedPeak.measure(candidate.output)
                        let sixteen = ReconstructedPeak.measure(candidate.output, factor: 16)
                        try require(abs(20 * log10(sixteen / peak)) < 0.05, "8x/16x reconstruction disagreement")
                        try require(sixteen < 1, "Continuous reconstructed output exceeds 0 dBFS: \(sixteen)")
                        for ch in 0..<2 {
                            let window = Int(outputRate * 0.01)
                            // Protected Warm enable deliberately fades; check settled recovery.
                            for start in stride(from: Int(outputRate * 0.6), to: Int(outputRate * 1.5), by: window) {
                                let energy = candidate.output[ch][start..<start + window].reduce(0.0) { $0 + Double($1 * $1) } / Double(window)
                                try require(energy > 1e-8, "Continuous settled output silent")
                            }
                        }
                        cases += 1
                        print(String(format: "CONTINUOUS %@ %@ overload=%@ output=%d windows=%d consumed=%d boost=%.6f latency=%lld sourceNull=%.9f processedNull=%.9f samplePeak=%.6f reconstructed8x=%.6f reconstructed16x=%.6f",
                                     path.name, effect, String(overload), Int(outputRate), candidate.windows, candidate.consumed,
                                     candidate.boost, candidate.latency, sourceError, difference, samplePeak, peak, sixteen))
                    }
                }
            }
        }
        print("PASS: \(cases) continuous PCM feedback / nonlinear / changing latency stereo cases")
    }
}
