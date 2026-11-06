import AVFoundation
import Foundation

@main
struct SpectralTransientFallbackRegression {
    static func require(_ value: Bool, _ reason: String) throws {
        if !value { throw NSError(domain: "SpectralFallback", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
    }
    @MainActor
    static func render(rate: Double, effect: SpectralTransientAudioEffect?) throws -> [Float] {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        for ch in 0..<2 {
            for i in 0..<4096 {
                buffer.floatChannelData![ch][i] = Float(0.1 * sin(Double(i) * 2 * .pi * 997 / rate)) * (ch == 0 ? 1 : -0.5)
            }
        }
        engine.attach(player)
        let node: AVAudioNode
        if let effect {
            effect.attach(to: engine)
            node = effect.inputNode
        } else {
            let unity = AVAudioMixerNode()
            engine.attach(unity)
            node = unity
        }
        engine.connect(player, to: node, format: format)
        engine.connect(effect?.outputNode ?? node, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 256)
        engine.prepare()
        try engine.start()
        defer { engine.stop() }
        player.scheduleBuffer(buffer)
        player.play()
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 256)!
        var pcm: [Float] = []
        for block in 0..<16 {
            if let effect {
                var setting = RealtimeAudioEffectSetting(kind: .spectralTransient, isEnabled: block.isMultiple(of: 2))
                setting.parameters["intensity"] = 1
                effect.apply(setting: setting)
                effect.resetTailState()
                try require(!effect.isEnabled && effect.estimatedGainBoostDB == 0, "Unavailable unit claimed active gain")
            }
            try require(try engine.renderOffline(256, to: output) == .success, "Offline render failed")
            for i in 0..<Int(output.frameLength) {
                for ch in 0..<2 { pcm.append(output.floatChannelData![ch][i]) }
            }
        }
        try require(pcm.count == 8192 && pcm.allSatisfy(\.isFinite), "Invalid output PCM")
        return pcm
    }
    @MainActor
    static func main() throws {
        for rate in [44100.0, 48000.0, 96000.0] {
            let reference = try render(rate: rate, effect: nil)
            try require(reference.reduce(0.0) { $0 + Double($1 * $1) } > 1, "Empty reference")
            for wrongType in [false, true] {
                let effect = SpectralTransientAudioEffect(makeNode: { wrongType ? AVAudioUnitEQ(numberOfBands: 1) : nil })
                let actual = try render(rate: rate, effect: effect)
                let difference = zip(actual, reference).map { abs($0 - $1) }.max() ?? .infinity
                try require(difference < 0.000001, "Fallback changed PCM: \(difference)")
                print("PASS: fallback rate=\(Int(rate)) wrongType=\(wrongType) maxDifference=\(difference) toggles/reset=16")
            }
        }
    }
}
