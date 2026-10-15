import AVFoundation
import Foundation

@main
struct SpatialTransitionWaveformRegression {
    static let rate = 96_000.0
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func samples(_ pcm: AVAudioPCMBuffer) -> [[Float]] {
        (0..<2).map { Array(UnsafeBufferPointer(start: pcm.floatChannelData![$0], count: Int(pcm.frameLength))) }
    }
    static func render(old oldPCM: AVAudioPCMBuffer, new newPCM: AVAudioPCMBuffer,
                       outputRate: Double, seek: Double, interval: Double, path: Int) throws -> [[Float]] {
        let engine = AVAudioEngine(), old = AVAudioPlayerNode(), new = AVAudioPlayerNode(), mixer = AVAudioMixerNode()
        let graph = oldPCM.format
        let output = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        for node in [old, new, mixer] as [AVAudioNode] { engine.attach(node) }
        engine.connect(old, to: mixer, fromBus: 0, toBus: 0, format: graph)
        engine.connect(new, to: mixer, fromBus: 0, toBus: 1, format: graph)
        engine.connect(mixer, to: engine.mainMixerNode, format: graph)
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
        let oldFrame = Int64(seek * rate)
        let offset = Double(oldFrame) / rate
        let plan = PlaybackHandoffClock.plan(sourceOffset: offset, renderedFrames: 0,
            sourceSampleRate: rate, leadFromRenderTime: 0.25, targetSampleRate: rate,
            targetFrameCount: Int64(newPCM.frameLength))!
        let newFrame = plan.startFrame + ((path == 2 && CommandLine.arguments.contains("--misaligned-fixture")) ? 8 : 0)
        old.scheduleBuffer(ShippingSpatial.playbackSlice(from: oldPCM, startingFrame: oldFrame,
            frameCount: oldPCM.frameLength - AVAudioFrameCount(oldFrame))!)
        new.scheduleBuffer(ShippingSpatial.playbackSlice(from: newPCM, startingFrame: newFrame,
            frameCount: newPCM.frameLength - AVAudioFrameCount(newFrame))!,
            at: AVAudioTime(sampleTime: Int64((plan.delayFromRenderTime * rate).rounded()), atRate: rate))
        old.volume = 1; new.volume = path == 1 ? 1 : 0
        try engine.start(); old.play(); new.play()
        defer { old.stop(); new.stop(); engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512)!
        var result = [[Float](), [Float]()]
        var nextControl = 0.0, block = 0
        while result[0].count < Int(outputRate * 0.65) {
            let time = Double(engine.manualRenderingSampleTime) / outputRate
            if path == 2 && time >= nextControl {
                let elapsed = max(0, time - plan.delayFromRenderTime)
                let progress = PlaybackHandoffClock.fadeProgress(renderedFrames: Int64((elapsed * rate).rounded()), sampleRate: rate)!
                old.volume = 1 - progress; new.volume = progress
                nextControl = time + interval
            }
            if path == 2 && CommandLine.arguments.contains("--mute-fixture") {
                mixer.outputVolume = time >= 0.27 && time < 0.33 ? 0 : 1
            }
            let pattern = [127, 256, 384, 191, 512]
            let count = AVAudioFrameCount(min(pattern[block % pattern.count], Int(outputRate * 0.65) - result[0].count))
            block += 1
            try require(try engine.renderOffline(count, to: buffer) == .success && buffer.frameLength == count, "Spatial render failed")
            for ch in 0..<2 { result[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(count))) }
        }
        return result
    }
    static func energy(_ signal: [Float], _ range: Range<Int>) -> Double {
        range.reduce(0) { $0 + Double(signal[$1]) * Double(signal[$1]) }
    }
    static func run() throws {
        setbuf(stdout, nil)
        try SpatialTransitionStateRegression.run()
        if CommandLine.arguments.contains("--state-only") { return }
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let base = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        base.frameLength = base.frameCapacity
        for ch in 0..<2 { for i in 0..<Int(base.frameLength) {
            let time = Double(i) / rate
            let low = sin(2 * Double.pi * (ch == 0 ? 137.0 : 211.0) * time)
            let mid = sin(2 * Double.pi * (ch == 0 ? 997.0 : 1301.0) * time)
            let sweep = sin(2 * Double.pi * (1500 * time + 6500 * time * time))
            let transient = (i % 13000 < 500) ? sin(2 * Double.pi * 8000 * time) : 0
            base.floatChannelData![ch][i] = Float(0.035 * low + 0.025 * mid + 0.015 * sweep + 0.025 * transient)
        } }
        let untouched = samples(base)
        let presets: [HeadphoneHRTFPreset] = [.natural, .frontal, .wide, .studio]
        func processed(_ preset: HeadphoneHRTFPreset, amount: Double) throws -> AVAudioPCMBuffer {
            let copy = try ShippingSpatial.clonePlaybackBuffer(from: base)
            try ShippingSpatial.applyHeadphoneVirtualizationIfNeeded(to: copy,
                settings: HeadphoneSpatialSettings(isEnabled: true, preset: preset, spatial: amount, crossfeed: amount),
                routeSupportsSpatial: true)
            return copy
        }
        var cases = 0, minWindowRatio = Double.infinity, maxPeak: Float = 0, maxNullDB = -Double.infinity
        for (index, preset) in presets.enumerated() {
            let wet = try processed(preset, amount: 0.25)
            let stronger = try processed(preset, amount: 0.9)
            let next = try processed(presets[(index + 1) % presets.count], amount: 0.9)
            for (scenario, a, b) in [("enable", base, wet), ("disable", wet, base), ("parameters", wet, stronger), ("preset", wet, next)] {
                for outputRate in [44_100.0, 48_000.0, 96_000.0] {
                    for seek in [0.0, 0.123457] {
                        let old = try render(old: a, new: b, outputRate: outputRate, seek: seek, interval: 0, path: 0)
                        let sum = try render(old: a, new: b, outputRate: outputRate, seek: seek, interval: 0, path: 1)
                        let new = (0..<2).map { ch in zip(sum[ch], old[ch]).map { $0.0 - $0.1 } }
                        for interval in [0.0, 0.016] {
                            let mixed = try render(old: a, new: b, outputRate: outputRate, seek: seek, interval: interval, path: 2)
                            for ch in 0..<2 {
                                let stable = Int(outputRate * 0.40)..<Int(outputRate * 0.60)
                                let error = stable.reduce(0.0) { $0 + pow(Double(mixed[ch][$1] - new[ch][$1]), 2) }
                                let nullDB = 10 * log10(max(error, 1e-30) / energy(new[ch], stable))
                                try require(nullDB < -50, "Spatial replacement timeline mismatch: \(nullDB) dB")
                                maxNullDB = max(maxNullDB, nullDB)
                                let prefix = 0..<Int(outputRate * 0.20)
                                try require(prefix.allSatisfy { abs(mixed[ch][$0] - old[ch][$0]) < 1e-6 }, "Spatial source changed before scheduled start")
                                let window = Int(outputRate * 0.010)
                                for start in stride(from: Int(outputRate * 0.23), to: Int(outputRate * 0.38), by: window) {
                                    let range = start..<start + window
                                    let reference = min(energy(old[ch], range), energy(new[ch], range))
                                    // New source is silent before its scheduled start.
                                    if reference > 1e-9 {
                                        let ratio = sqrt(energy(mixed[ch], range) / reference)
                                        minWindowRatio = min(minWindowRatio, ratio)
                                        try require(ratio > 0.15, "Spatial transition created a silent PCM window")
                                    }
                                }
                                let peak = mixed[ch].map { abs($0) }.max()!
                                maxPeak = max(maxPeak, peak)
                                try require(mixed[ch].allSatisfy(\.isFinite) && peak < 0.895, "Spatial transition nonfinite/over-ceiling")
                                let jump = zip(mixed[ch].dropFirst(), mixed[ch]).map { abs($0.0 - $0.1) }.max()!
                                let oldJump = zip(old[ch].dropFirst(), old[ch]).map { abs($0.0 - $0.1) }.max()!
                                let newJump = zip(new[ch].dropFirst(), new[ch]).map { abs($0.0 - $0.1) }.max()!
                                try require(jump < max(oldJump, newJump) * 3 + 0.005, "Spatial transition introduced an impulsive step")
                            }
                            cases += 1
                        }
                        print("SPATIAL preset=\(preset.rawValue) scenario=\(scenario) output=\(Int(outputRate)) seek=\(seek) controls=perBlock,16ms")
                    }
                }
            }
        }
        try require(samples(base) == untouched, "Spatial preparation mutated shared base PCM")
        print(String(format: "PASS: %d stereo spatial transitions; minimum10msRMSRatio=%.6f maximumSamplePeak=%.6f worstSettledNullDB=%.3f", cases, minWindowRatio, maxPeak, maxNullDB))
    }
    static func main() async {
        do {
            try await SpatialTransitionStateRegression.preloadAcceptance()
            try run()
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
