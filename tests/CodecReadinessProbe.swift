import AVFoundation
import Foundation

@main struct CodecReadinessProbe {
    static func main() {
        var stage = "open"
        var decoded: Int64 = 0
        do {
            let file = try AVAudioFile(forReading: URL(fileURLWithPath: CommandLine.arguments[1]))
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            stage = "decode"
            for _ in 0..<2000 {
                if file.framePosition >= file.length { break }
                try file.read(into: buffer)
                guard buffer.frameLength > 0 else { break }
                guard let channels = buffer.floatChannelData else { throw CocoaError(.fileReadCorruptFile) }
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) where !channels[channel][frame].isFinite { throw CocoaError(.fileReadCorruptFile) }
                }
                decoded += Int64(buffer.frameLength)
            }
            var seekFrames: [Int] = []
            stage = "seek"
            for fraction in [0.1, 0.5, 0.9] {
                file.framePosition = Int64(Double(file.length) * fraction)
                try file.read(into: buffer, frameCount: 1024)
                seekFrames.append(Int(buffer.frameLength))
            }
            let result: [String: Any] = ["opened": true, "completedProbe":true, "declaredFrames": file.length, "decodedFrames": decoded,
                                       "seekFrames": seekFrames, "sampleRate": file.processingFormat.sampleRate]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            let data = try! JSONSerialization.data(withJSONObject: ["opened":stage != "open","completedProbe":false,"decodedFrames":decoded,"stage":stage,"error":String(describing:error)])
            print(String(decoding:data,as:UTF8.self))
        }
    }
}
