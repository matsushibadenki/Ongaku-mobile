import AVFoundation
import Foundation

/// The real analysis/gain/EQ law with controlled audit snapshots. Render-thread
/// meter delivery and physical route changes are outside this fixture.
struct GainTransitionRegression {
    typealias Host = ShippingDSPTransition
    typealias Probe = DSPTransitionRegression
    static func run() throws {
        setbuf(stdout, nil)
        var cases = 0
        for outputRate in [44_100.0, 48_000.0, 96_000.0] {
            for tab in [AudioEffectPageTab.basic, .pro] {
                for amplitude in [0.012, 0.20] {
                    let scenarios = CommandLine.arguments.contains("--duplicate-gain-fixture")
                        ? ["restoreCombined"] : CommandLine.arguments.contains("--inactive-gain-fixture")
                            ? ["inactiveParameters"] : ["restoreParameters", "restoreDSP", "restoreCombined", "restoreLoudness", "audits", "inactiveParameters"]
                    for scenario in scenarios {
                        DispatchQueue.main.reset()
                        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), eq = AVAudioUnitEQ(numberOfBands: 4), output = AVAudioMixerNode()
                        let graph = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
                        let final = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
                        let effects = AudioEffectModuleRegistry.makePipeline()
                        let host = Host(player: player, eq: eq, output: output, effects: effects)
                        host.useRealGainPath = true
                        host.recomputeInactiveGainForNegativeControl = CommandLine.arguments.contains("--inactive-gain-fixture")
                        host.duplicateGainForNegativeControl = CommandLine.arguments.contains("--duplicate-gain-fixture")
                        host.bypassMuteGateForNegativeControl = CommandLine.arguments.contains("--unprotected-fixture")
                        host.forceMuteForNegativeControl = CommandLine.arguments.contains("--mute-fixture")
                        for node in [player, host.inputGainEQ, host.loudnessCompensationEQ, eq, host.outputSafetyEQ, output] as [AVAudioNode] {
                            engine.attach(node)
                        }
                        engine.connect(player, to: host.inputGainEQ, format: graph)
                        engine.connect(host.inputGainEQ, to: host.loudnessCompensationEQ, format: graph)
                        engine.connect(host.loudnessCompensationEQ, to: eq, format: graph)
                        var upstream: AVAudioNode = eq
                        for effect in effects {
                            effect.attach(to: engine); effect.connectInternalNodes(engine: engine, format: graph)
                            engine.connect(upstream, to: effect.inputNode, format: graph); upstream = effect.outputNode
                        }
                        let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
                        let ceiling = AVAudioUnitEQ(numberOfBands: 0)
                        engine.attach(limiter); engine.attach(ceiling); host.outputLimiter = limiter
                        EffectOutputSafety.configure(limiter: limiter); ceiling.globalGain = EffectOutputSafety.ceilingDB
                        engine.connect(upstream, to: host.outputSafetyEQ, format: graph)
                        engine.connect(host.outputSafetyEQ, to: limiter, format: graph)
                        engine.connect(limiter, to: ceiling, format: graph)
                        engine.connect(ceiling, to: output, format: graph)
                        engine.connect(output, to: engine.mainMixerNode, format: graph)
                        try engine.enableManualRenderingMode(.offline, format: final, maximumFrameCount: 256)
                        let source = AVAudioPCMBuffer(pcmFormat: graph, frameCapacity: 96_000)!
                        source.frameLength = source.frameCapacity
                        for ch in 0..<2 { for i in 0..<Int(source.frameLength) {
                            let time = Double(i) / 96_000
                            source.floatChannelData![ch][i] = Float((ch == 0 ? 1.0 : -0.5) *
                                [137.0, 997, 3901, 8033].reduce(0.0) { $0 + amplitude * sin(2 * .pi * $1 * time) })
                        } }
                        let diagnostics = Host.analyzeSignalLevels(in: source)
                        let profile = Host.analyzeAutomaticDSP(in: source, diagnostics: diagnostics)
                        host.signalDiagnostics = diagnostics; host.automaticDSPProfile = profile
                        host.applyAutomaticDSPProfile(profile); host.applyLoudnessCompensation(for: 0.8)
                        let initial = Probe.settings(tab, amount: 0.25)
                        let first = Probe.settings(tab, amount: 0.75)
                        let latest = Probe.settings(tab, amount: 0.65)
                        func inactiveSettings(_ amount: Double) -> [RealtimeAudioEffectSetting] {
                            initial.map { original in
                                guard !original.isEnabled else { return original }
                                var value = original
                                for key in value.parameters.keys { value.parameters[key] = amount }
                                value.parameters["flutter"] = 0
                                return value
                            }
                        }
                        host.apply(effectSettings: initial)
                        let restoreVolume: Float = scenario == "restoreParameters" ? 0.4 : 1
                        output.outputVolume = restoreVolume
                        host.mutations.removeAll(); host.gainWrites.removeAll()
                        player.scheduleBuffer(source); try engine.start(); player.play()
                        // A second gesture at 360/365 ms starts after the first
                        // interpolation; its latest request replaces the target.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            switch scenario {
                            case "restoreDSP": host.setAutomaticDSPStrength(1.5, effectSettings: initial)
                            case "restoreCombined": host.setAutomaticDSPStrength(1.5, effectSettings: first)
                            case "restoreLoudness": host.applyLoudnessCompensation(for: 0.2)
                            case "inactiveParameters": host.apply(effectSettings: inactiveSettings(0.75))
                            default:
                                if scenario == "audits" {
                                    host.controlledEffectLevelAudits = AudioEffectModuleRegistry.activeKinds.map {
                                        EffectLevelAudit(kind: $0, isEnabled: true, inputPeakDBFS: -24, inputRMSDBFS: -36,
                                                         outputPeakDBFS: 0, outputRMSDBFS: -12)
                                    }
                                }
                                host.apply(effectSettings: first)
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.36) {
                            switch scenario {
                            case "restoreDSP", "restoreCombined": host.setAutomaticDSPVoicing(.safe)
                            case "inactiveParameters": host.apply(effectSettings: inactiveSettings(0.25))
                            case "restoreLoudness":
                                host.loudnessCompensationRouteProfile = .headphone
                                host.applyLoudnessCompensation(for: 0.15)
                            default: host.apply(effectSettings: initial)
                            }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.365) {
                            switch scenario {
                            case "restoreDSP": host.setAutomaticDSPStrength(0.25, effectSettings: initial)
                            case "inactiveParameters": host.apply(effectSettings: inactiveSettings(0.65))
                            case "restoreCombined": host.setAutomaticDSPStrength(0.25, effectSettings: latest)
                            case "restoreLoudness":
                                host.loudnessCompensationRouteProfile = .bluetooth
                                host.applyLoudnessCompensation(for: 0.8)
                            default:
                                if scenario == "audits" {
                                    host.controlledEffectLevelAudits = AudioEffectModuleRegistry.activeKinds.map {
                                        EffectLevelAudit(kind: $0, isEnabled: true, inputPeakDBFS: -120, inputRMSDBFS: -120,
                                                         outputPeakDBFS: -120, outputRMSDBFS: -120)
                                    }
                                }
                                host.apply(effectSettings: latest)
                            }
                        }
                        let buffer = AVAudioPCMBuffer(pcmFormat: final, frameCapacity: 256)!
                        var samples = [[Float](), [Float]()]
                        while samples[0].count < Int(outputRate * 0.8) {
                            DispatchQueue.main.advance(to: Double(engine.manualRenderingSampleTime) / outputRate)
                            let count = AVAudioFrameCount(min(256, Int(outputRate * 0.8) - samples[0].count))
                            try Probe.require(abs(output.outputVolume - restoreVolume) < 1e-6, "Continuous controls changed output envelope")
                            try Probe.require(try engine.renderOffline(count, to: buffer) == .success && buffer.frameLength == count, "Gain transition render failed")
                            for ch in 0..<2 { samples[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(count))) }
                        }
                        DispatchQueue.main.advance(to: 0.8)
                        try Probe.require(abs(output.outputVolume - restoreVolume) < 1e-6, "Restoration lost original nonunity volume")
                        let liveMutations = host.mutations.filter { $0.3 }
                        if scenario == "inactiveParameters" {
                            try Probe.require(liveMutations.isEmpty && host.gainWrites.isEmpty,
                                              "Disabled-only changes triggered gain or mute")
                            try Probe.require(inactiveSettings(0.65).allSatisfy { host.lastAppliedEffectSettings[$0.kind] == $0 },
                                              "Latest inactive parameters lost")
                        } else {
                            try Probe.require(!liveMutations.isEmpty && liveMutations.allSatisfy { abs($0.2 - restoreVolume) < 1e-6 && $0.1 >= 0.21 - 1e-8 }, "Continuous update bypassed interpolation")
                            try Probe.require(host.gainWrites.count == 16, "Gain planning repeated or missed during one commit")
                        }
                        try Probe.require(host.gainWrites.allSatisfy { $0.1 >= -12 && $0.1 <= 6 && $0.2 <= 0 && $0.3 >= 0 && $0.3 <= 12 }, "Gain/audit bounds failed")
                        try Probe.require(abs(host.outputSafetyEQ.globalGain - min(0, host.plannedOutputTrimDB - EffectOutputSafety.ceilingDB)) < 1e-5,
                                          "Limiter headroom margin applied incorrectly")
                        try Probe.require(diagnostics.sourcePeakDBFS.isFinite && diagnostics.sourceRMSDBFS.isFinite && diagnostics.sourceIntegratedLoudnessLUFS.isFinite,
                                          "Source analysis is nonfinite")
                        if scenario == "restoreParameters" || scenario == "restoreCombined" || scenario == "audits" {
                            try Probe.require(latest.allSatisfy { host.lastAppliedEffectSettings[$0.kind] == $0 }, "Latest restore-phase parameters lost")
                        }
                        if scenario == "restoreDSP" || scenario == "restoreCombined" {
                            try Probe.require(abs(eq.bands[0].gain - profile.lowShelfGainDB * 0.35 * 0.25) < 1e-5, "Latest restore-phase DSP strength/voicing lost")
                        }
                        if scenario == "restoreLoudness" {
                            try Probe.require(host.loudnessCompensationEQ.bypass && host.appliedLoudnessCompensationVolume == 0.8 && host.appliedLoudnessCompensationRoute == .bluetooth,
                                              "Latest loudness route/volume lost")
                            host.applyLoudnessCompensation(for: .nan)
                            try Probe.require(host.pendingLoudnessCompensationVolume == nil, "Nonfinite loudness was queued")
                        }
                        if scenario == "audits" { try Probe.require(host.gainWrites.contains { $0.3 > 0 }, "Valid audits did not influence gain planning") }
                        for ch in 0..<2 {
                            let peak = samples[ch].map { abs($0) }.max()!
                            let settled = samples[ch][Int(outputRate * 0.65)..<Int(outputRate * 0.8)]
                            let rms = sqrt(settled.reduce(0.0) { $0 + pow(Double($1), 2) } / Double(settled.count))
                            try Probe.require(samples[ch].allSatisfy(\.isFinite) && peak > 0.001 && peak <= 0.895 && rms > 0.00001, "Gain-path nonfinite/silent/over-ceiling audio")
                            let window = Int(outputRate * 0.01)
                            let baseline = sqrt(samples[ch][Int(outputRate * 0.1)..<Int(outputRate * 0.18)].reduce(0.0) { $0 + Double($1 * $1) } / (outputRate * 0.08))
                            for start in stride(from: Int(outputRate * 0.18), to: Int(outputRate * 0.55), by: window) {
                                let energy = sqrt(samples[ch][start..<start + window].reduce(0.0) { $0 + Double($1 * $1) } / Double(window))
                                try Probe.require(energy > min(baseline, rms) * 0.1, "Continuous control created a silent PCM window")
                            }
                            print(String(format: "GAIN_TRANSITION output=%.0f tab=%@ amplitude=%.3f scenario=%@ channel=%d peak=%.6f rms=%.6f inputTrimDB=%.4f preLimiterTrimDB=%.4f plannedTrimDB=%.4f measuredBoostDB=%.4f restores=%.3f", outputRate, tab.rawValue, amplitude, scenario, ch, peak, rms, host.inputGainEQ.globalGain, host.outputSafetyEQ.globalGain, host.plannedOutputTrimDB, host.smoothedMeasuredEffectBoostDB, output.outputVolume))
                        }
                        player.stop(); engine.stop(); DispatchQueue.main.reset(); cases += 1
                    }
                }
            }
        }
        print("PASS: \(cases) shipping analysis/gain/loudness and restore-phase transition cases, both channels")
    }
}
