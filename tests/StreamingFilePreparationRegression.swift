import AVFoundation
import Foundation

@main struct StreamingFilePreparationRegression {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let samples = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        samples.frameLength = 4096
        for channel in 0..<2 {
            for index in 0..<4096 { samples.floatChannelData![channel][index] = Float(sin(Double(index) * 0.1) * 0.3) }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: samples)
        }
        let opened = try await StreamingAudioFilePreparation.open(url: url)
        precondition(opened.file.length == 4096 && opened.file.processingFormat.sampleRate == 44_100)
        let decoded = AVAudioPCMBuffer(pcmFormat: opened.file.processingFormat, frameCapacity: 4096)!
        try opened.file.read(into: decoded)
        for channel in 0..<2 {
            for index in 0..<4096 {
                precondition(abs(decoded.floatChannelData![channel][index] - samples.floatChannelData![channel][index]) < 0.00001)
            }
        }
        print("PASS: worker-opened stereo PCM preserves all 8,192 samples and format")
        for suffix in ["partial", "range-partial"] {
            let staging = directory.appendingPathComponent("source.\(suffix)")
            try FileManager.default.copyItem(at: url, to: staging)
            do {
                _ = try await StreamingAudioFilePreparation.open(url: staging) { _ in
                    preconditionFailure("Staging data reached AVAudioFile")
                }
                preconditionFailure("Staging file accepted")
            } catch is CocoaError {}
        }
        print("PASS: incomplete staging files never reach the audio decoder")

        var ticks = 0
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(5))
                if !Task.isCancelled { ticks += 1 }
            }
        }
        _ = try await StreamingAudioFilePreparation.open(url: url) { source in
            precondition(!Thread.isMainThread, "File opening must not run on the UI thread")
            Thread.sleep(forTimeInterval: 0.2) // Simulate a slow local/provider open.
            return try AVAudioFile(forReading: source)
        }
        heartbeat.cancel()
        precondition(ticks > 0)
        print("PASS: MainActor continued for \(ticks) ticks during a simulated 200 ms file open")

        let pending = Task {
            try await StreamingAudioFilePreparation.open(url: url) { source in
                Thread.sleep(forTimeInterval: 0.2)
                return try AVAudioFile(forReading: source)
            }
        }
        try await Task.sleep(for: .milliseconds(30))
        pending.cancel()
        do { _ = try await pending.value; preconditionFailure("Cancelled open was delivered") }
        catch is CancellationError { print("PASS: cancelled in-flight open cannot deliver its file") }

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await StreamingAudioFilePreparation.open(url: url) { _ in
                preconditionFailure("Already-cancelled request performed file I/O")
            }
        }
        do { _ = try await cancelled.value; preconditionFailure("Cancelled request succeeded") }
        catch is CancellationError { print("PASS: already-cancelled requests perform no file I/O") }

        do {
            _ = try await StreamingAudioFilePreparation.open(url: directory.appendingPathComponent("missing.wav"))
            preconditionFailure("Missing source succeeded")
        } catch { print("PASS: file-opening errors propagate to the existing recovery path") }
    }
}
