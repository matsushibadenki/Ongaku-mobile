import AVFoundation
import Foundation

private final class LatencyProbe: AudioEffectNode {
    let kind: RealtimeAudioEffectKind = .warm
    var isEnabled = false
    let node = AVAudioMixerNode()
    var nodes: [AVAudioNode] { [node] }
    var inputNode: AVAudioNode { node }
    var outputNode: AVAudioNode { node }
    var estimatedGainBoostDB: Double { 0 }
    var transitionLatency: TimeInterval { isEnabled ? 0.007 : 0 }
    func attach(to engine: AVAudioEngine) { engine.attach(node) }
    func detach(from engine: AVAudioEngine) { engine.detach(node) }
    func connectInternalNodes(engine: AVAudioEngine, format: AVAudioFormat?) {}
    func apply(setting: RealtimeAudioEffectSetting) { isEnabled = EffectTransitionPolicy.effectiveEnabled(setting) }
}

@main
struct EffectLatencyStateRegression {
    static func main() throws {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode(), output = AVAudioMixerNode()
        let effect = LatencyProbe()
        let format = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        engine.attach(player); engine.attach(output)
        engine.connect(player, to: output, format: format)
        engine.connect(output, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 96_000)!
        source.frameLength = source.frameCapacity
        let host = ShippingDSPTransition(player: player, eq: AVAudioUnitEQ(numberOfBands: 4), output: output, effects: [effect])
        let on = RealtimeAudioEffectSetting(kind: .warm, isEnabled: true)
        var off = RealtimeAudioEffectSetting(kind: .warm, isEnabled: true)
        off.parameters["intensity"] = 0
        host.apply(effectSettings: [on])
        try engine.start(); player.scheduleBuffer(source); player.play()
        defer { player.stop(); engine.stop() }
        host.apply(effectSettings: [off])
        DispatchQueue.main.advance(to: 0.0081)
        precondition(!effect.isEnabled && output.outputVolume == 0)
        DispatchQueue.main.advance(to: 0.0249)
        precondition(output.outputVolume == 0)
        DispatchQueue.main.advance(to: 0.05)
        precondition(output.outputVolume == 1 && host.effectDeclickRestoreVolume == nil)
        host.apply(effectSettings: [on])
        DispatchQueue.main.advance(to: 0.060)
        precondition(effect.isEnabled && output.outputVolume == 0)
        host.cancelEffectTransitionForStop()
        DispatchQueue.main.advance(to: 0.20)
        precondition(output.outputVolume == 1 && host.effectDeclickRestoreVolume == nil)
        host.pendingTransportPause = 0.5
        host.apply(effectSettings: [off])
        DispatchQueue.main.advance(to: 0.3)
        precondition(effect.isEnabled && host.pendingDeclickEffectSettings != nil)
        host.pendingTransportPause = nil
        output.outputVolume = 0
        host.applyPendingEffectSettings()
        precondition(!effect.isEnabled && output.outputVolume == 0)
        print("PASS: shipping iPhone zero-intensity bypass commit at zero, 17 ms latency drain, restored output stale restore cancellation and pause-request deferral")
    }
}
