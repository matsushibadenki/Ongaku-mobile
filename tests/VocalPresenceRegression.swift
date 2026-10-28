import AVFoundation
import Foundation

@main struct VocalPresenceRegression {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func render(rate: Double, frequency: Double, setting: RealtimeAudioEffectSetting?) throws -> [Float] {
        let engine = AVAudioEngine(), player = AVAudioPlayerNode()
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        engine.attach(player)
        if let setting {
            let effect = VocalPresenceAudioEffect()
            effect.attach(to: engine); effect.apply(setting: setting)
            engine.connect(player, to: effect.inputNode, format: format)
            engine.connect(effect.outputNode, to: engine.mainMixerNode, format: format)
            try require(abs(effect.estimatedGainBoostDB - (setting.isEnabled ? 1.2 * (setting.parameters["intensity"] ?? 0.35) : 0)) < 0.0001, "reference gain")
        } else { engine.connect(player, to: engine.mainMixerNode, format: format) }
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        let count = Int(rate * 0.25)
        let source = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        source.frameLength = source.frameCapacity
        for c in 0..<2 { for i in 0..<count {
            source.floatChannelData![c][i] = Float(0.1 * sin(2 * .pi * frequency * Double(i) / rate)) * (c == 0 ? 1 : -0.5)
        } }
        player.scheduleBuffer(source); try engine.start(); player.play()
        defer { player.stop(); engine.stop() }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
        var output = [Float]()
        while output.count < count {
            let n = min(512, count - output.count)
            try require(try engine.renderOffline(AVAudioFrameCount(n), to: buffer) == .success, "offline render")
            output.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: n))
        }
        return output
    }
    static func level(_ pcm: [Float]) -> Double {
        let values = pcm.dropFirst(pcm.count / 2)
        return sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(values.count))
    }
    static func main() throws {
        let defaults = AudioEffectModuleRegistry.makeDefaultSettings()
        let setting = defaults.first { $0.kind == .vocalPresence }!
        try require(!setting.isEnabled && setting.parameters["intensity"] == 0.35, "default OFF and strength")
        for rate in [44_100.0, 48_000, 96_000, 192_000] {
            for frequency in [250.0, 2_800, 8_000] {
                let dry = try render(rate: rate, frequency: frequency, setting: nil)
                let off = try render(rate: rate, frequency: frequency, setting: setting)
                var active = setting; active.isEnabled = true
                let normal = try render(rate: rate, frequency: frequency, setting: active)
                active.parameters["intensity"] = 1
                let maximum = try render(rate: rate, frequency: frequency, setting: active)
                let error = zip(dry, off).map { abs($0 - $1) }.max()!
                let gain = 20 * log10(level(normal) / level(dry))
                let maxGain = 20 * log10(level(maximum) / level(dry))
                try require(error < 0.00001 && normal.allSatisfy(\.isFinite) && maximum.allSatisfy(\.isFinite), "OFF transparency and finite PCM")
                if frequency == 2_800 { try require(abs(gain - 0.42) < 0.04 && abs(maxGain - 1.2) < 0.05, "center response") }
                print("VOCAL rate=\(rate) hz=\(frequency) offMax=\(error) defaultDB=\(gain) maxDB=\(maxGain)")
            }
        }
        print("PASS: default OFF, real EQ graph, four rates, finite PCM, center response and reference gain")
    }
}
