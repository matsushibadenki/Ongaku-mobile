import AVFoundation
import Foundation

@main
struct DSPTransitionRegression {
    typealias Host = ShippingDSPTransition
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func settings(_ tab: AudioEffectPageTab?, amount: Float = 0.5) -> [RealtimeAudioEffectSetting] {
        AudioEffectModuleRegistry.activeKinds.map { kind in
            var value = RealtimeAudioEffectSetting(kind: kind,
                isEnabled: tab.map { AudioEffectModuleRegistry.activeKinds(for: $0).contains(kind) } ?? false)
            for key in value.parameters.keys { value.parameters[key] = Double(amount) }
            value.parameters["flutter"] = 0
            return value
        }
    }
    static func main() {
        do {
            if CommandLine.arguments.contains("--gain-path") { try GainTransitionRegression.run() }
            else { try run() }
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
    static func run() throws {
        setbuf(stdout, nil)
        var cases = 0
        for outputRate in [44_100.0, 48_000.0, 96_000.0] {
            for tab in [AudioEffectPageTab.basic, .pro] {
                for scenario in ["parameters", "disable", "automaticDSP", "handoffDSP", "stopCancel", "stopDSP"] {
                    DispatchQueue.main.reset()
                    let engine = AVAudioEngine(), player = AVAudioPlayerNode(), eq = AVAudioUnitEQ(numberOfBands: 4), output = AVAudioMixerNode()
                    let graph = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
                    let final = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
                    let effects = AudioEffectModuleRegistry.makePipeline()
                    engine.attach(player); engine.attach(eq); engine.attach(output)
                    engine.connect(player, to: eq, format: graph)
                    var upstream: AVAudioNode = eq
                    for effect in effects {
                        effect.attach(to: engine); effect.connectInternalNodes(engine: engine, format: graph)
                        engine.connect(upstream, to: effect.inputNode, format: graph); upstream = effect.outputNode
                    }
                    let limiter = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
                        componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_PeakLimiter,
                        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
                    let ceiling = AVAudioUnitEQ(numberOfBands: 0)
                    engine.attach(limiter); engine.attach(ceiling); EffectOutputSafety.configure(limiter: limiter)
                    ceiling.globalGain = EffectOutputSafety.ceilingDB
                    engine.connect(upstream, to: limiter, format: graph); engine.connect(limiter, to: ceiling, format: graph)
                    engine.connect(ceiling, to: output, format: graph); engine.connect(output, to: engine.mainMixerNode, format: graph)
                    try engine.enableManualRenderingMode(.offline, format: final, maximumFrameCount: 256)
                    let host = Host(player: player, eq: eq, output: output, effects: effects)
                    host.bypassMuteGateForNegativeControl = CommandLine.arguments.contains("--unprotected-fixture")
                    let initial = settings(tab, amount: 0.25), latest = settings(tab, amount: 0.75)
                    host.apply(effectSettings: initial)
                    let source = AVAudioPCMBuffer(pcmFormat: graph, frameCapacity: 96_000 * 2)!
                    source.frameLength = source.frameCapacity
                    for ch in 0..<2 { for i in 0..<Int(source.frameLength) {
                        let time = Double(i) / 96_000
                        source.floatChannelData![ch][i] = Float((ch == 0 ? 1.0 : -0.5) *
                            ([137.0, 997, 3901, 8033].reduce(0.0) { $0 + 0.012 * sin(2 * .pi * $1 * time) }))
                    } }
                    player.scheduleBuffer(source); try engine.start(); player.play()
                    host.mutations.removeAll()
                    let profile = Host.AutomaticDSPProfile(lowShelfGainDB: 4, lowMidGainDB: -2, presenceGainDB: 3, highShelfGainDB: -1)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        switch scenario {
                        case "parameters", "disable", "stopCancel": host.apply(effectSettings: latest)
                        case "automaticDSP", "stopDSP": host.automaticDSPProfile = profile; host.applyAutomaticDSPProfile(profile)
                        default: host.pendingHandoff = true; host.automaticDSPProfile = profile; host.applyAutomaticDSPProfile(profile)
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.205) {
                        switch scenario {
                        case "parameters": host.apply(effectSettings: initial) // Superseded during fade-out.
                        case "disable": host.apply(effectSettings: []) // Omitted modules must turn off.
                        case "automaticDSP": host.setAutomaticDSPVoicing(.safe)
                        case "stopCancel": host.cancelEffectTransitionForStop()
                        case "stopDSP":
                            player.stop(); host.cancelEffectTransitionForStop()
                            host.automaticDSPProfile = .neutral; host.applyAutomaticDSPProfile(.neutral)
                            player.scheduleBuffer(source); player.play()
                        default: break
                        }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.21) {
                        if scenario == "parameters" { host.apply(effectSettings: latest) }
                        if scenario == "automaticDSP" { host.setAutomaticDSPStrength(0.5, effectSettings: initial) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) {
                        if scenario == "handoffDSP" { host.pendingHandoff = nil; host.commitPendingDSPChangesIfReady() }
                    }
                    let buffer = AVAudioPCMBuffer(pcmFormat: final, frameCapacity: 256)!
                    var samples = [[Float](), [Float]()]
                    while samples[0].count < Int(outputRate * 0.8) {
                        DispatchQueue.main.advance(to: Double(engine.manualRenderingSampleTime) / outputRate)
                        let count = AVAudioFrameCount(min(256, Int(outputRate * 0.8) - samples[0].count))
                        try require(try engine.renderOffline(count, to: buffer) == .success && buffer.frameLength == count, "DSP transition render failed")
                        for ch in 0..<2 { samples[ch].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(count))) }
                    }
                    DispatchQueue.main.advance(to: 0.8)
                    try require(abs(output.outputVolume - 1) < 1e-6, "Output remained muted after transition/cancellation")
                    let liveMutations = host.mutations.filter { $0.3 }
                    if scenario == "stopCancel" || scenario == "stopDSP" {
                        try require(liveMutations.isEmpty && host.lastAppliedEffectSettings[initial[0].kind] == initial[0], "Cancelled settings returned after stop")
                    } else {
                        try require(!liveMutations.isEmpty && liveMutations.allSatisfy { $0.2 <= 1e-6 }, "DSP/parameter/gain write escaped mute gate")
                    }
                    if scenario == "stopDSP" {
                        try require(host.pendingAutomaticDSPProfile == nil && host.appliedAutomaticDSPProfile == .neutral,
                                    "Cancelled DSP profile returned after stop")
                    }
                    if scenario == "parameters" {
                        try require(latest.allSatisfy { host.lastAppliedEffectSettings[$0.kind] == $0 }, "Coalesced parameters did not retain latest request")
                    }
                    if scenario == "disable" { try require(effects.allSatisfy { !$0.isEnabled }, "Omitted module stayed enabled") }
                    if scenario == "automaticDSP" {
                        host.setAutomaticDSPStrength(.nan, effectSettings: initial)
                        host.setAutomaticDSPStrength(.infinity, effectSettings: initial)
                        try require(abs(eq.bands[0].gain - 0.7) < 1e-5 && host.pendingAutomaticDSPProfile == nil, "Latest strength/voicing lost")
                    }
                    if scenario == "handoffDSP" {
                        try require(host.mutations.filter { $0.0 == "automaticDSP" }.allSatisfy { $0.1 >= 0.30 - 1e-8 }, "Shared EQ changed before source handoff finished")
                    }
                    for ch in 0..<2 {
                        let peak = samples[ch].map { abs($0) }.max()!
                        let settled = samples[ch][Int(outputRate * 0.6)..<Int(outputRate * 0.8)]
                        let rms = sqrt(settled.reduce(0.0) { $0 + pow(Double($1), 2) } / Double(settled.count))
                        let jump = zip(samples[ch].dropFirst(), samples[ch]).map { abs($0.0 - $0.1) }.max()!
                        try require(samples[ch].allSatisfy(\.isFinite) && peak > 0.001 && peak <= 0.895 && rms > 0.0001, "Nonfinite/silent/over-ceiling transition")
                        print(String(format: "DSP_TRANSITION output=%.0f tab=%@ scenario=%@ channel=%d peak=%.6f rms=%.6f maximumAdjacentStep=%.6f mutations=%d", outputRate, tab.rawValue, scenario, ch, peak, rms, jump, liveMutations.count))
                    }
                    player.stop(); engine.stop(); DispatchQueue.main.reset()
                    cases += 1
                }
            }
        }
        print("PASS: \(cases) shipping effect/automatic-DSP transitions, latest-request coalescing, handoff deferral and stop cancellation")
    }
}
