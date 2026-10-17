import AVFoundation
import Foundation

@main @MainActor struct DesktopEffectTransitionRegression {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func settings(_ tab: AudioEffectPageTab, _ amount: Double) -> [RealtimeAudioEffectSetting] {
        AudioEffectModuleRegistry.activeKinds.map { kind in
            var value = RealtimeAudioEffectSetting(kind: kind, isEnabled: AudioEffectModuleRegistry.activeKinds(for: tab).contains(kind))
            for key in value.parameters.keys { value.parameters[key] = amount }
            value.parameters["flutter"] = 0
            return value
        }
    }
    static func main() throws {
        setbuf(stdout, nil)
        var rows = [[String: Any]]()
        for rate in [44_100.0, 48_000, 96_000] {
        for protected in [false, true] {
        for tab in [AudioEffectPageTab.basic, .pro] {
        for scenario in ["coalesce", "gesture", "overlap", "offRestore", "bypassOverlap", "lateOverlap", "stopOut", "stopIn"] {
            let engine = AVAudioEngine(), a = AVAudioPlayerNode(), b = AVAudioPlayerNode(), sourceMixer = AVAudioMixerNode()
            let input = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
            let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let effects = AudioEffectModuleRegistry.makePipeline(), protection = EffectOutputProtection()
            let final = FinalOutputProtection(enabled: protected)
            for node in [a,b,sourceMixer] as [AVAudioNode] { engine.attach(node) }
            protection.attach(to: engine); final.attach(to: engine)
            engine.connect(a, to: sourceMixer, fromBus: 0, toBus: 0, format: input)
            engine.connect(b, to: sourceMixer, fromBus: 0, toBus: 1, format: input)
            var upstream: AVAudioNode = sourceMixer
            for effect in effects {
                effect.attach(to: engine); effect.connectInternalNodes(engine: engine, format: input)
                engine.connect(upstream, to: effect.inputNode, format: input); upstream = effect.outputNode
            }
            protection.connect(from: upstream, engine: engine, format: input, destination: final.inputNode(in: engine))
            try final.connect(engine: engine, outputFormat: output)
            final.setVolume(0.67, engine: engine)
            let envelope = final.inputNode(in: engine) as! AVAudioMixerNode
            try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
            let clock = EffectTestClock()
            let host = ShippingDesktopEffectTransition(a,b,effects,protection,envelope,clock,engine,final)
            host.effectSettings = settings(tab, 0.25); host.applyEffectSettings(immediately: true, force: true)
            host.writes.removeAll(); host.bypassCommits.removeAll()
            host.immediateDefect = CommandLine.arguments.contains("--unprotected-fixture")
            host.unsafeBypassDefect = CommandLine.arguments.contains("--unsafe-bypass-fixture")
            host.muteDefect = CommandLine.arguments.contains("--mute-fixture")
            let source = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: 57_600)!
            source.frameLength = source.frameCapacity
            for c in 0..<2 { for f in 0..<Int(source.frameLength) {
                let t = Double(f) / 96_000
                source.floatChannelData![c][f] = Float([137.0,997,3901,8033].reduce(0.0) { $0 + 0.012 * sin(2 * .pi * $1 * t) }) * (c == 0 ? 1 : -0.5)
            } }
            a.volume = 1; b.volume = 0
            a.scheduleBuffer(source); b.scheduleBuffer(source)
            try engine.start(); a.play(); b.play()
            let bypassScenario = !["coalesce", "gesture", "overlap"].contains(scenario)
            if ["overlap", "bypassOverlap"].contains(scenario) { clock.schedule(0.145) { host.prerolledTrack = .init() } }
            if scenario == "lateOverlap" { clock.schedule(0.154) { host.prerolledTrack = .init() } }
            clock.schedule(0.15) {
                host.effectSettings = settings(tab, 0.75)
                if bypassScenario { host.effectsBypassed = true }
                host.applyEffectSettings()
            }
            switch scenario {
            case "coalesce":
                clock.schedule(0.155) { host.effectSettings = settings(tab, 0.3); host.applyEffectSettings() }
                clock.schedule(0.165) { host.effectSettings = settings(tab, 0.65); host.applyEffectSettings() }
            case "gesture":
                for n in 0..<40 { clock.schedule(0.151 + Double(n) * 0.003) {
                    host.effectSettings = settings(tab, 0.25 + Double(n) / 39 * 0.5); host.applyEffectSettings()
                } }
            case "overlap", "bypassOverlap", "lateOverlap":
                clock.schedule(0.20) { host.effectSettings = settings(tab, 0.65); host.applyEffectSettings() }
                clock.schedule(0.25) { host.prerolledTrack = nil }
                if bypassScenario { clock.schedule(0.30) { host.effectsBypassed = false; host.applyEffectSettings() } }
            case "stopOut", "stopIn":
                clock.schedule(scenario == "stopOut" ? 0.154 : 0.162) { host.stopPlayerNodes() }
                clock.schedule(0.18) { host.effectSettings = settings(tab, 0.65); host.effectsBypassed = false; host.applyEffectSettings() }
                clock.schedule(0.19) {
                    a.scheduleBuffer(source); b.scheduleBuffer(source)
                    try! engine.start(); a.play(); b.play(); a.volume = 1; b.volume = 0
                }
            default:
                clock.schedule(0.155) { host.effectSettings = settings(tab, 0.9); host.applyEffectSettings() }
                clock.schedule(0.17) { host.effectsBypassed = false; host.applyEffectSettings() }
                clock.schedule(0.18) { host.effectSettings = settings(tab, 0.65); host.applyEffectSettings() }
            }
            var pcm = [[Float](),[Float]()], index = 0
            let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512)!
            let blocks = [127,512,61,256]
            while pcm[0].count < Int(rate * 0.5) {
                clock.advance(to: Double(pcm[0].count) / rate)
                if ["overlap", "bypassOverlap", "lateOverlap"].contains(scenario) {
                    let gain = Float(min(1, max(0, (clock.now - 0.145) / 0.105)))
                    a.volume = 1-gain; b.volume = gain
                }
                if !bypassScenario || clock.now >= 0.36 {
                    try require(envelope.outputVolume == 0.67, "Continuous controls changed output envelope")
                }
                if protected { try require(engine.mainMixerNode.outputVolume == 1, "Gain placed after true-peak stage") }
                let n = min(blocks[index % blocks.count], Int(rate * 0.5) - pcm[0].count); index += 1
                if !engine.isRunning {
                    for c in 0..<2 { pcm[c].append(contentsOf: repeatElement(0, count: n)) }
                    continue
                }
                try require(try engine.renderOffline(AVAudioFrameCount(n), to: buffer) == .success, "render failed")
                for c in 0..<2 { pcm[c].append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![c], count: n)) }
            }
            a.stop(); b.stop(); engine.stop()
            try require(host.bypassCommits.allSatisfy { !$0.audible || $0.gain == 0 }, "Audible bypass committed without zero-gain protection")
            let first = host.writes.filter { $0.1.isEnabled }.first?.0 ?? -1
            if !bypassScenario { try require(first >= 0.159, "Continuous update bypassed interpolation") }
            if ["overlap", "bypassOverlap", "lateOverlap"].contains(scenario) {
                try require(!host.writes.contains { $0.0 < 0.25 }, "Shared rack changed during overlap")
            }
            if scenario == "offRestore" {
                try require(!host.writes.contains { $0.0 >= 0.155 && $0.0 < 0.17 && $0.1.isEnabled }, "Stale update resurrected OFF")
            }
            let settled = Dictionary(host.writes.map { ($0.1.kind, $0.1) }, uniquingKeysWith: { _,last in last })
            let expected = settings(tab, scenario == "gesture" ? 0.75 : 0.65)
            for value in expected { try require(settled[value.kind] == value, "Latest target was lost") }
            if scenario == "coalesce" {
                let ticks = Set(host.writes.map { $0.0 })
                try require(ticks.count == 8 && clock.events.isEmpty, "Coalescing restarted or duplicated interpolation")
            }
            try require(pcm.joined().allSatisfy(\.isFinite), "Nonfinite PCM")
            let peak = pcm.joined().map(abs).max()!
            try require(peak < 1.25, "Unexpected output overload")
            var minRatio = Double.infinity
            for samples in pcm {
                func rms(_ start: Double, _ end: Double) -> Double {
                    let values = samples[Int(start * rate)..<Int(end * rate)]
                    return sqrt(values.reduce(0.0) { $0 + Double($1)*Double($1) } / Double(values.count))
                }
                let floor = min(rms(0.12,0.14), rms(0.42,0.46))
                try require(floor > 0.00001, "Silent reference")
                for start in stride(from: 0.14, through: 0.4, by: 0.01) {
                    let ratio = rms(start,start+0.01) / floor
                    minRatio = min(minRatio,ratio)
                    // Bypass deliberately contains a short attenuation. Test resumed/recovered
                    // audio outside that window; continuous gestures still forbid any dropout.
                    if !bypassScenario || start >= 0.36 { try require(ratio > 0.1, "10 ms audio dropout") }
                }
            }
            let reconstructed = protected ? ReconstructedPeak.measure(pcm, factor: 16) : peak
            if protected { try require(reconstructed <= pow(10,-1.0/20), "Protected transition exceeded ceiling") }
            rows.append(["outputRate":rate,"truePeakEnabled":protected,"tab":tab.rawValue,"scenario":scenario,
                         "samplePeak":peak,"measuredPeak":reconstructed,"minimumWindowRMSRatio":minRatio,"firstWrite":first])
            print("DESKTOP CONTINUITY rate=\(rate) protected=\(protected) tab=\(tab.rawValue) scenario=\(scenario) peak=\(reconstructed) minWindowRatio=\(minRatio)")
        } } } }
        if let report = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("--") }) {
            try JSONSerialization.data(withJSONObject: ["cases":rows,"count":rows.count], options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:report))
        }
        print("PASS: \(rows.count) desktop transition PCM cases")
    }
}
