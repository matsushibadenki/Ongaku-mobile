import AVFoundation
import Foundation

@main
struct EffectMatrixAudit {
    struct Result {
        let channels: [[Float]]
        let inputs: [[Float]]
        var peak: Double { channels.flatMap { $0 }.map { abs(Double($0)) }.max() ?? 0 }
        var nullError: Double {
            zip(channels, inputs).flatMap { out, input in zip(out, input).map { abs(Double($0 - $1)) } }.max() ?? 0
        }
        var gainDB: Double {
            let start = channels[0].count / 2
            let out = channels.flatMap { $0.dropFirst(start) }.reduce(0.0) { $0 + Double($1) * Double($1) }
            let input = inputs.flatMap { $0.dropFirst(start) }.reduce(0.0) { $0 + Double($1) * Double($1) }
            return 10 * log10(max(1e-30, out) / max(1e-30, input))
        }
    }
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        checks += 1
        guard condition else { fatalError("FAIL: \(message)") }
    }
    static func render(_ settings: [RealtimeAudioEffectSetting], rate: Double = 48_000,
                       amplitude: Double = 0.1, frequency: Double = 1_000,
                       protected: Bool = false, impulse: Bool = false, volume: Float = 1,
                       toggledOff: Bool = false) throws -> Result {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.attach(player)
        let effects = settings.map { setting in
            AudioEffectModuleRegistry.makePipeline().first { $0.kind == setting.kind }!
        }
        var upstream: AVAudioNode = player
        for effect in effects {
            effect.attach(to: engine)
            effect.connectInternalNodes(engine: engine, format: format)
            engine.connect(upstream, to: effect.inputNode, format: format)
            upstream = effect.outputNode
        }
        if protected {
            let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
            let trim = AVAudioUnitEQ(numberOfBands: 0)
            engine.attach(limiter); engine.attach(trim)
            EffectOutputSafety.configure(limiter: limiter)
            trim.globalGain = EffectOutputSafety.ceilingDB
            engine.connect(upstream, to: limiter, format: format)
            engine.connect(limiter, to: trim, format: format)
            upstream = trim
        }
        engine.connect(upstream, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = volume
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
        for (effect, setting) in zip(effects, settings) {
            effect.apply(setting: setting)
            if toggledOff {
                var off = setting; off.isEnabled = false
                effect.apply(setting: off)
            }
        }
        defer { engine.stop(); effects.forEach { $0.detach(from: engine) } }
        let length = Int(rate)
        let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(length))!
        input.frameLength = input.frameCapacity
        for ch in 0..<2 {
            for i in 0..<length {
                // Different frequencies/levels catch dropped or swapped channels.
                let f = frequency * (ch == 0 ? 1 : 1.13)
                input.floatChannelData![ch][i] = Float(impulse ? (i == 4096 ? amplitude : 0) :
                    amplitude * (ch == 0 ? 1 : 0.7) * sin(2 * .pi * f * Double(i) / rate))
            }
        }
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        player.scheduleBuffer(input)
        try engine.start(); player.play()
        var samples = [[Float](), [Float]()]
        while samples[0].count < length {
            let frames = AVAudioFrameCount(min(1024, length - samples[0].count))
            let status = try engine.renderOffline(frames, to: output)
            guard status == .success, output.frameLength > 0 else {
                throw NSError(domain: "EffectAuditRender", code: Int(status.rawValue))
            }
            for ch in 0..<2 {
                samples[ch].append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![ch], count: Int(output.frameLength)))
            }
        }
        check(samples.flatMap { $0 }.allSatisfy(\.isFinite), "finite output \(settings.map(\.kind))")
        return Result(channels: samples, inputs: (0..<2).map {
            Array(UnsafeBufferPointer(start: input.floatChannelData![$0], count: length))
        })
    }

    static func main() throws {
        setbuf(stdout, nil)
        try parameterChecks()
        var individualCases = 0
        var largestFinalPeak = 0.0
        for rate in [44_100.0, 48_000, 96_000] {
            for var setting in AudioEffectModuleRegistry.makeDefaultSettings() {
                let off = try render([setting], rate: rate)
                check(off.nullError < 0.00001, "sample-exact bypass \(setting.kind) \(rate): \(off.nullError)")
                setting.isEnabled = true
                setting.parameters["flutter"] = 0
                let toggled = try render([setting], rate: rate, toggledOff: true)
                check(toggled.nullError < 0.00001, "on/off restores bypass \(setting.kind)")
                for maximum in [false, true] {
                    var active = setting
                    if maximum { for key in active.parameters.keys { active.parameters[key] = 1 } }
                    active.parameters["flutter"] = 0
                    var peak = 0.0, minGain = Double.infinity, maxGain = -Double.infinity
                    for frequency in [80.0, 250, 1_000, 6_000, 12_000] {
                        let result = try render([active], rate: rate, amplitude: 0.9, frequency: frequency)
                        check(result.channels.allSatisfy { $0.contains { abs($0) > 0.00001 } }, "both channels audible \(active.kind)")
                        peak = max(peak, result.peak)
                        minGain = min(minGain, result.gainDB); maxGain = max(maxGain, result.gainDB)
                        individualCases += 1
                    }
                    print(String(format: "MATRIX %.0f %@ %@ peak=%.6f gainDB=%.3f...%.3f", rate, setting.kind.rawValue, maximum ? "maximum" : "default", peak, minGain, maxGain))
                }
                if setting.kind != .equalizer {
                    setting.parameters["intensity"] = 0
                    let zero = try render([setting], rate: rate)
                    check(zero.nullError < 0.00001, "zero intensity \(setting.kind)")
                }
            }
            for tab in AudioEffectPageTab.allCases {
                for maximum in [false, true] {
                    var settings = AudioEffectModuleRegistry.makeDefaultSettings()
                    for i in settings.indices {
                        settings[i].isEnabled = AudioEffectModuleRegistry.activeKinds(for: tab).contains(settings[i].kind)
                        if maximum { for key in settings[i].parameters.keys { settings[i].parameters[key] = 1 } }
                        settings[i].parameters["flutter"] = 0
                    }
                    for frequency in [80.0, 250, 1_000, 6_000, 12_000] {
                        let result = try render(settings, rate: rate, amplitude: 0.99, frequency: frequency, protected: true)
                        check(result.peak <= 0.895 && result.peak > 0.0001, "final ceiling \(rate) \(tab) \(result.peak)")
                        largestFinalPeak = max(largestFinalPeak, result.peak)
                    }
                }
            }
            for impulse in [false, true] {
                let overload = try render([], rate: rate, amplitude: 16, protected: true, impulse: impulse)
                check(overload.peak <= 0.895 && overload.peak > 0.01, "overload ceiling \(rate) \(overload.peak)")
            }
        }
        try behaviorChecks()
        print("PASS checks=\(checks) individualCases=\(individualCases) finalCases=60 largestFinalPeak=\(largestFinalPeak)")
    }

    static func parameterChecks() throws {
        for effect: AudioEffectNode in [OptoFETAudioEffect(), ExciterAudioEffect(), WarmAudioEffect()] {
            let engine = AVAudioEngine()
            effect.attach(to: engine)
            defer { effect.detach(from: engine) }
            if effect.kind == .warm || effect.kind == .exciter {
                check(effect.nodes.compactMap { $0 as? AVAudioUnitEQ }.allSatisfy { $0.bands.allSatisfy { !$0.bypass } }, "EQ bands enabled \(effect.kind)")
            }
            var setting = RealtimeAudioEffectSetting(kind: effect.kind, isEnabled: true)
            setting.parameters["mode"] = 1
            setting.parameters["flutter"] = 0
            effect.apply(setting: setting)
            for unit in effect.nodes.compactMap({ $0 as? AVAudioUnitEffect })
            where unit.audioComponentDescription.componentSubType == kAudioUnitSubType_DynamicsProcessor {
                let tree = unit.auAudioUnit.parameterTree!
                for id: AUParameterAddress in [4, 5] {
                    let p = tree.parameter(withAddress: id)!
                    check(p.value >= p.minValue && p.value <= p.maxValue, "dynamics time range")
                }
                check(tree.parameter(withAddress: 2)!.value == 1, "expansion disabled")
                check(tree.parameter(withAddress: 4)!.value < 0.1, "attack uses seconds")
                check(tree.parameter(withAddress: 5)!.value < 1, "release uses seconds")
            }
            if let speed = effect.nodes.compactMap({ $0 as? AVAudioUnitVarispeed }).first {
                check(speed.rate == 1, "zero flutter is stationary")
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
                effect.connectInternalNodes(engine: engine, format: format)
                for bus in 0..<5 {
                    check(engine.inputConnectionPoint(for: effect.outputNode, inputBus: AVAudioNodeBus(bus)) != nil, "Warm independent bus \(bus)")
                }
                setting.parameters["flutter"] = 1
                effect.apply(setting: setting)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                check(abs(speed.rate - 1) > 0.0001, "flutter modulates pitch")
                setting.isEnabled = false
                effect.apply(setting: setting)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                check(speed.rate == 1, "disabling Warm stops modulation")
            }
        }
        check(EffectOutputSafety.preLimiterTrim(totalTrimDB: -8, hasLimiter: true) == -7, "margin applied once")
        check(EffectOutputSafety.preLimiterTrim(totalTrimDB: -8, hasLimiter: false) == -8, "fallback trim")
        check(EffectOutputSafety.preLimiterTrim(totalTrimDB: 0, hasLimiter: true) == 0, "no unexpected gain")
    }

    static func behaviorChecks() throws {
        var eq = RealtimeAudioEffectSetting(kind: .equalizer, isEnabled: true)
        check(try render([eq]).nullError < 0.00001, "flat EQ unity")
        eq.parameters["trim"] = 1
        check(abs(try render([eq]).gainDB - 6) < 0.02, "EQ +6dB output trim")
        eq.parameters["trim"] = 0
        check(abs(try render([eq]).gainDB + 18) < 0.02, "EQ -18dB output trim")
        let opto = RealtimeAudioEffectSetting(kind: .optoFET, isEnabled: true)
        let quiet = try render([opto], amplitude: 0.025)
        let loud = try render([opto], amplitude: 0.9)
        check(loud.gainDB < quiet.gainDB - 3, "OptoFET compresses louder input")
        for kind: RealtimeAudioEffectKind in [.exciter, .highQualityEnhancement] {
            var setting = RealtimeAudioEffectSetting(kind: kind, isEnabled: true)
            setting.parameters["intensity"] = 0.002
            check(try render([setting]).nullError < 0.002, "low intensity continuity \(kind)")
        }
        var settings = AudioEffectModuleRegistry.makeDefaultSettings()
        for i in settings.indices { settings[i].isEnabled = true; settings[i].parameters["flutter"] = 0 }
        check(try render(settings, amplitude: 0, protected: true).peak < 0.00001, "silence remains silent")
        let full = try render(settings, protected: true)
        let half = try render(settings, protected: true, volume: 0.5)
        check(zip(full.channels, half.channels).allSatisfy { a, b in zip(a, b).allSatisfy { abs($0 * 0.5 - $1) < 0.00001 } }, "final volume is after DSP")
    }
}
