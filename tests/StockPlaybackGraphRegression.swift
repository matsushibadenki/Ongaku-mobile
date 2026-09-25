import AVFoundation
import Foundation

@main
struct StockPlaybackGraphRegression {
    static func main() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for sourceRate in [44_100.0, 48_000.0] {
            let fileURL = folder.appendingPathComponent("tone-\(Int(sourceRate)).caf")
            try writeTone(to: fileURL, rate: sourceRate)
            for effectEnabled in [false, true] {
                for outputRate in [48_000.0, 96_000.0] {
                    try render(fileURL, effectEnabled: effectEnabled, outputRate: outputRate)
                }
            }
        }
        print("PASS: 8 file-backed stock-mixer graphs; 44.1/48 kHz sources, 96 kHz DSP, 48/96 kHz output, enhancement off/on")
    }

    static func writeTone(to url: URL, rate: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
        buffer.frameLength = buffer.frameCapacity
        for ch in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![ch][frame] = Float(0.1 * sin(2 * .pi * 997 * Double(frame) / rate))
            }
        }
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    static func render(_ url: URL, effectEnabled: Bool, outputRate: Double) throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode(), standby = AVAudioPlayerNode()
        let mixer = AVAudioMixerNode()
        let effect = HighQualityEnhancementAudioEffect()
        let processing = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
        let output = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
        engine.attach(player); engine.attach(standby); engine.attach(mixer)
        effect.attach(to: engine)
        effect.connectInternalNodes(engine: engine, format: processing)
        engine.connect(player, to: mixer, fromBus: 0, toBus: 0, format: processing)
        engine.connect(standby, to: mixer, fromBus: 0, toBus: 1, format: processing)
        engine.connect(mixer, to: effect.inputNode, format: processing)
        engine.connect(effect.outputNode, to: engine.mainMixerNode, format: processing)
        player.volume = 1; standby.volume = 0
        var setting = RealtimeAudioEffectSetting(kind: .highQualityEnhancement, isEnabled: effectEnabled)
        setting.parameters["intensity"] = 0.68
        setting.parameters["air"] = 0.58
        setting.parameters["harmonic"] = 0.42
        effect.apply(setting: setting)
        try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 1024)
        let file = try AVAudioFile(forReading: url)
        player.scheduleSegment(file, startingFrame: 0, frameCount: AVAudioFrameCount(file.length), at: nil)
        try engine.start(); player.play()
        let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 1024)!
        var peaks: [Float] = [0, 0]
        for _ in 0..<Int(outputRate / 1024) {
            let status = try engine.renderOffline(1024, to: buffer)
            precondition(status == .success, "stock graph failed to render")
            for ch in 0..<2 {
                for frame in 0..<Int(buffer.frameLength) {
                    let value = buffer.floatChannelData![ch][frame]
                    precondition(value.isFinite)
                    peaks[ch] = max(peaks[ch], abs(value))
                }
            }
        }
        precondition(peaks.allSatisfy { $0 > 0.01 && $0 < 1 }, "silent or invalid stock graph: \(peaks)")
        player.stop(); engine.stop()
    }
}
