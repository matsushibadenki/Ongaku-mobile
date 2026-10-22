import AVFoundation
import Foundation

final class TailTestClock: @unchecked Sendable {
    var now = 0.0
    private var serial = 0
    private var events: [(Double, Int, @Sendable () -> Void)] = []
    func schedule(_ delay: Double, _ action: @escaping @Sendable () -> Void) {
        serial += 1; events.append((now + delay, serial, action))
    }
    func advance(_ target: Double) {
        while let next = events.enumerated().filter({ $0.element.0 <= target })
            .min(by: { ($0.element.0, $0.element.1) < ($1.element.0, $1.element.1) }) {
            let event = events.remove(at: next.offset); now = event.0; event.2()
        }
        now = target
    }
}

@main
@MainActor
struct TailLatencyRegression {
    static func require(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static func effect(_ name: String, clock: TailTestClock) -> AudioEffectNode {
        switch name {
        case "space": return SpaceAudioEffect(tailSchedule: clock.schedule)
        case "gloss": return GlossAudioEffect(tailSchedule: clock.schedule)
        case "body": return BodyAudioEffect(tailSchedule: clock.schedule)
        default: return WarmAudioEffect(tailSchedule: clock.schedule)
        }
    }
    static func render(_ name: String, rate: Double, mode: String, continuous: Bool = false) throws -> [[Float]] {
        let clock = TailTestClock(), engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let fx = effect(name, clock: clock)
        let format = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let output = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.attach(player); fx.attach(to: engine); fx.connectInternalNodes(engine: engine, format: format)
        engine.connect(player, to: fx.inputNode, format: format)
#if AUDIO_GAIN_TAIL_AUDIT
        let effectGain = AudioThreadGainStage(gain: 1), transportGain = AudioThreadGainStage(gain: 1)
        engine.attach(effectGain.node); engine.attach(transportGain.node)
        engine.connect(fx.outputNode, to: effectGain.node, format: format)
        engine.connect(effectGain.node, to: transportGain.node, format: format)
        // Main mixer retains SRC; the gain units stay at the rack's stereo rate.
        engine.connect(transportGain.node, to: engine.mainMixerNode, format: format)
#else
        engine.connect(fx.outputNode, to: engine.mainMixerNode, format: format)
#endif
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        source.frameLength = source.frameCapacity
        for ch in 0..<2 { for i in 0..<96_000 {
            let t = Double(i) / 96_000
            let envelope = continuous ? 1 : (t > 0.18 && t < 0.28 ? pow(sin(.pi * (t - 0.18) / 0.1), 2) : 0)
            source.floatChannelData![ch][i] = Float(envelope * (ch == 0 ? 1 : -0.6) *
                (0.06 * sin(2 * .pi * 997 * t) + 0.025 * sin(2 * .pi * 6011 * t)))
        } }
        var setting = RealtimeAudioEffectSetting(kind: fx.kind, isEnabled: mode != "dry")
        if name == "warm" { setting.parameters["flutter"] = 0 }
        fx.apply(setting: setting)
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 256)
        try engine.start()
#if AUDIO_GAIN_TAIL_AUDIT
        effectGain.synchronizeAfterStart(); transportGain.synchronizeAfterStart()
#endif
        player.scheduleBuffer(source); player.play()
        defer { engine.stop(); fx.resetTailState() }
        let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 256)!
        var result = [[Float](), [Float]()], changed = false, restarted = false
        while result[0].count < Int(rate) {
            let t = Double(engine.manualRenderingSampleTime) / rate
            clock.advance(t)
            if t >= 0.3 && !changed && mode != "on" && mode != "dry" {
                let before = fx.transitionLatency
                setting.isEnabled = false; fx.apply(setting: setting); changed = true
                if mode == "off" && !continuous {
                    print("BYPASS_LATENCY effect=\(name) output=\(Int(rate)) before=\(before) after=\(fx.transitionLatency) settle=\(EffectTransitionPolicy.settleDuration(before: before, after: fx.transitionLatency))")
                }
                if CommandLine.arguments.contains("--cut-tail") { fx.resetTailState() }
            }
            if t >= 0.35 && mode == "restart" && !restarted {
                setting.isEnabled = true; fx.apply(setting: setting); restarted = true
            }
            if t > 0.31 && t < 0.34 && mode == "off" { fx.apply(setting: setting) }
            let frames = AVAudioFrameCount(min(127, Int(rate) - result[0].count))
            try require(try engine.renderOffline(frames, to: buffer) == .success, "Tail offline render")
            for ch in 0..<2 { result[ch] += UnsafeBufferPointer(start: buffer.floatChannelData![ch], count: Int(frames)) }
        }
        clock.advance(2) // Expose stale callbacks after re-enable or teardown.
        return result
    }
    static func energy(_ a: [Float], _ range: Range<Int>) -> Double {
        range.reduce(0) { $0 + Double(a[$1]) * Double(a[$1]) }
    }
    static func run() throws {
        setbuf(stdout, nil)
        try require(EffectTransitionPolicy.settleDuration(before: 0, after: 0) == 0, "Unchanged latency should not mute")
        try require(abs(EffectTransitionPolicy.settleDuration(before: 0.007, after: 0) - 0.017) < 1e-9, "Latency drain")
        try require(EffectTransitionPolicy.settleDuration(before: .nan, after: 0) == 0.060, "Invalid latency bound")
        for name in ["space", "gloss", "body", "warm"] {
            for rate in [44_100.0, 48_000.0, 96_000.0] {
                let off = try render(name, rate: rate, mode: "off")
                let natural = try render(name, rate: rate, mode: "on")
                let continuous = try render(name, rate: rate, mode: "off", continuous: true)
                let dry = try render(name, rate: rate, mode: "dry", continuous: true)
                let restarted = try render(name, rate: rate, mode: "restart", continuous: true)
                let always = try render(name, rate: rate, mode: "on", continuous: true)
                for ch in 0..<2 {
                    let hold = Int(rate * 0.35)..<Int(rate * 0.44)
                    let end = Int(rate * 0.85)..<Int(rate * 0.95)
                    let tail = energy(off[ch], hold), reference = energy(natural[ch], hold)
                    let residual = hold.reduce(0.0) { $0 + pow(Double(off[ch][$1] - natural[ch][$1]), 2) }
                    let nullDB = 10 * log10(max(1e-30, residual) / max(1e-30, reference))
                    try require(reference > 1e-9 && tail > reference * 0.1, "Tail was abruptly cut: \(name)")
                    try require(nullDB < -20, "Tail hold lost history: \(name) \(nullDB)")
                    try require(energy(off[ch], end) < 1e-16, "Tail failed to reach silence")
                    let dryError = end.map { abs(continuous[ch][$0] - dry[ch][$0]) }.max()!
                    try require(dryError < 2e-5, "OFF keeps feeding wet signal: \(name) \(dryError)")
                    // Re-enable cancels every old release; a new wet signal must survive.
                    let wetEnergy = end.reduce(0.0) { $0 + pow(Double(restarted[ch][$1] - dry[ch][$1]), 2) }
                    let expectedWet = end.reduce(0.0) { $0 + pow(Double(always[ch][$1] - dry[ch][$1]), 2) }
                    try require(wetEnergy > expectedWet * 0.1, "Stale OFF muted re-enabled wet path")
                    try require(continuous[ch].allSatisfy(\.isFinite), "Nonfinite tail")
                    print("TAIL effect=\(name) output=\(Int(rate)) channel=\(ch) holdResidualDB=\(nullDB) tailEnergy=\(tail) offDryMaxError=\(dryError)")
                }
            }
        }
        print("PASS: 12 effect/rate cases, both channels; tail history, repeated OFF, exact dry settling, rapid ON and latency policy")
    }
    static func main() {
        do { try run() } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
