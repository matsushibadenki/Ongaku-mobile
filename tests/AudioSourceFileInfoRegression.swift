import AVFoundation
import Foundation

@main struct AudioSourceFileInfoRegression {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { print("FAIL: \(message)"); exit(1) }
    }
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceInfo-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for ext in ["wav", "aiff", "m4a", "alac"] {
            for ch in [1, 2] {
                let url = root.appendingPathComponent("source-\(ext)-\(ch).\(ext == "alac" ? "m4a" : ext)")
                let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: UInt32(ch))!
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
                pcm.frameLength = pcm.frameCapacity
                for c in 0..<ch { for f in 0..<44_100 { pcm.floatChannelData![c][f] = Float(0.2 * sin(Double(f) * 0.1)) } }
                var settings: [String: Any] = [AVSampleRateKey: 44_100, AVNumberOfChannelsKey: ch]
                settings[AVFormatIDKey] = ext == "m4a" ? kAudioFormatMPEG4AAC : (ext == "alac" ? kAudioFormatAppleLossless : kAudioFormatLinearPCM)
                if ext == "m4a" { settings[AVEncoderBitRateKey] = 128_000 }
                else if ext == "alac" { settings[AVEncoderBitDepthHintKey] = 16 }
                else { settings[AVLinearPCMBitDepthKey] = 16; settings[AVLinearPCMIsFloatKey] = false; settings[AVLinearPCMIsBigEndianKey] = ext == "aiff" }
                do { let file = try AVAudioFile(forWriting: url, settings: settings); try file.write(from: pcm) }
                let result = await AudioSourceFileInfo.read(url: url)
                check(result.readSucceeded && result.hasURL, "metadata unavailable")
                check(result.sampleRate == 44_100 && result.channels == UInt32(ch), "source format replaced by DSP format")
                check(result.codec == (ext == "m4a" ? "AAC" : (ext == "alac" ? "ALAC" : "PCM")), "codec inferred incorrectly")
                if ext == "alac" { check(result.bitDepth == nil || result.bitDepth == 16, "ALAC source depth") }
                else { check(result.bitDepth == (ext == "m4a" ? nil : 16), "decoded Float32 reported as source depth") }
                if ext == "wav" || ext == "aiff" {
                    check(abs(Double(result.bitRate ?? 0) - 44_100 * Double(ch) * 16) < 1, "source PCM bitrate")
                }
                check(result.byteCount! > 0 && result.protectedAsset == false, "size/protection")
                print("PASS: \(ext), \(ch) channels, original metadata")
            }
        }
        let renamed = root.appendingPathComponent("misleading.m4a")
        try FileManager.default.copyItem(at: root.appendingPathComponent("source-wav-2.wav"), to: renamed)
        let info = await AudioSourceFileInfo.read(url: renamed)
        check(info.container == "M4A" && info.codec != "AAC", "extension must not be used as codec")
        let absent = await AudioSourceFileInfo.read(url: nil, protectedAsset: true)
        check(!absent.hasURL && !absent.readSucceeded && absent.sampleRate == nil && absent.protectedAsset == true, "missing Music URL")
        let missing = await AudioSourceFileInfo.read(url: root.appendingPathComponent("missing.wav"))
        check(!missing.readSucceeded && missing.errorCode != nil && missing.sampleRate == nil, "missing file must not invent metadata")
        print("PASS: extension/codec distinction, missing URL, protected flag, failed read and unknown source fields")
    }
}
