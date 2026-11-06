import AVFoundation
import Foundation

@main struct MixerCapacityRegression {
    @MainActor static func main() throws {
        for sourceRate in [44_100.0, 48_000] {
            for outputRate in [44_100.0, 48_000, 88_200, 96_000] {
                let engine = AVAudioEngine()
                let player = AVAudioPlayerNode()
                let mixer = AudioMixerCapacity.makeMixer()
                AudioMixerCapacity.reserve(engine.mainMixerNode)
                engine.attach(player); engine.attach(mixer)
                let source = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 2)!
                let processing = AVAudioFormat(standardFormatWithSampleRate: 96_000, channels: 2)!
                let output = AVAudioFormat(standardFormatWithSampleRate: outputRate, channels: 2)!
                engine.connect(player, to: mixer, format: source)
                engine.connect(mixer, to: engine.mainMixerNode, format: processing)
                try engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 2048)
                let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 48_000)!
                input.frameLength = input.frameCapacity
                for c in 0..<2 { for i in 0..<Int(input.frameLength) { input.floatChannelData![c][i] = 0.1 * sin(Float(i) * 0.04) } }
                player.scheduleBuffer(input, at: nil, options: .loops, completionHandler: nil)
                engine.prepare(); try engine.start(); player.play()
                let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 2048)!
                var peak: Float = 0
                for frames: AVAudioFrameCount in [512, 558, 1024, 2048, 558] {
                    let status = try engine.renderOffline(frames, to: buffer)
                    guard status == .success, buffer.frameLength == frames else { fatalError("render failed: \(status)") }
                    for i in 0..<Int(frames) { let v = buffer.floatChannelData![0][i]; guard v.isFinite else { fatalError("nonfinite") }; peak = max(peak, abs(v)) }
                }
                guard peak > 0.01 else { fatalError("silent output") }
                print("PASS source=\(sourceRate) processing=96000 output=\(outputRate) capacity=\(mixer.auAudioUnit.maximumFramesToRender) peak=\(peak)")
                player.stop(); engine.stop()
            }
        }
    }
}
