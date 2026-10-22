import AVFoundation
import Foundation

@main
struct MusicAssetPreparationRegression {
    @MainActor static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                buffer.floatChannelData![channel][frame] = Float(sin(Double(frame) * 0.02)) * (channel == 0 ? 0.4 : 0.2)
            }
        }
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        var snapshot: MusicAssetPreparation.Snapshot? = try await MusicAssetPreparation.snapshot(url: url)
        let snapshotURL = snapshot!.url
        let input = try AVAudioFile(forReading: snapshotURL)
        let copied = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: AVAudioFrameCount(input.length))!
        try input.read(into: copied)
        precondition(copied.frameLength == buffer.frameLength)
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                precondition(copied.floatChannelData![channel][frame] == buffer.floatChannelData![channel][frame])
            }
        }
        snapshot = nil
        precondition(!FileManager.default.fileExists(atPath: snapshotURL.path))
        precondition(FileManager.default.fileExists(atPath: url.path))
        print("PASS: passthrough preserves stereo PCM and timing; scoped snapshot cleanup preserves original")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MusicAssetPreparation.snapshot(url: url)
        }
        do { _ = try await task.value; fatalError("Cancelled export succeeded") }
        catch is CancellationError { }
        print("PASS: cancelled preparation never publishes a snapshot")
        // Reproduce export failure without requiring a Music account: the
        // production fallback must decode the real asset, preserving every PCM sample.
        let fallback = try await MusicAssetPreparation.playableSnapshot(url: url, passthrough: { _ in
            throw MusicAssetPreparation.Failure.unsupported
        })
        let decoded = try AVAudioFile(forReading: fallback.url)
        let pcm = AVAudioPCMBuffer(pcmFormat: decoded.processingFormat, frameCapacity: AVAudioFrameCount(decoded.length))!
        try decoded.read(into: pcm)
        precondition(pcm.frameLength == buffer.frameLength)
        precondition(pcm.format.sampleRate == buffer.format.sampleRate && pcm.format.channelCount == 2)
        for channel in 0..<2 {
            for frame in 0..<Int(buffer.frameLength) {
                precondition(pcm.floatChannelData![channel][frame] == buffer.floatChannelData![channel][frame])
            }
        }
        print("PASS: unsupported passthrough falls back to disk PCM with exact stereo samples/rate/timing")
        do {
            _ = try await MusicAssetPreparation.decodedSnapshot(url: url, maximumBytes: 128)
            fatalError("PCM budget was ignored")
        } catch MusicAssetPreparation.Failure.tooLarge { }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await MusicAssetPreparation.decodedSnapshot(url: url)
        }
        do { _ = try await cancelled.value; fatalError("Cancelled PCM reader succeeded") }
        catch is CancellationError { }
        print("PASS: PCM fallback rejects oversize and cancellation")
        do {
            _ = try await MusicAssetPreparation.playableSnapshot(url: url, timeout: .milliseconds(10), passthrough: { input in
                try await Task.sleep(for: .seconds(5))
                return try await MusicAssetPreparation.snapshot(url: input)
            })
            fatalError("Stalled preparation did not time out")
        } catch MusicAssetPreparation.Failure.timedOut { }
        print("PASS: stalled preparation times out and cancels its worker")
        let invalidDirectory = directory.appendingPathComponent("invalid-export", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidDirectory, withIntermediateDirectories: true)
        let invalidURL = invalidDirectory.appendingPathComponent("source.mov")
        try Data("unreadable output".utf8).write(to: invalidURL)
        let recovered = try await MusicAssetPreparation.playableSnapshot(url: url, passthrough: { _ in
            MusicAssetPreparation.Snapshot(url: invalidURL, directory: invalidDirectory)
        })
        let recoveredFile = try AVAudioFile(forReading: recovered.url)
        precondition(recoveredFile.length == Int64(buffer.frameLength))
        precondition(!FileManager.default.fileExists(atPath: invalidDirectory.path))
        print("PASS: an unreadable exported container is discarded and decoded instead")

        // Exercise the same initial-playback retry used by the ViewModel.
        // Direct source opening can fail for a Music asset even though AVAsset
        // can export/decode it. Both RMS and spectrum require the local engine.
        let openFailure = AudioPreparationFailure(stage: .streamingOpen,
            reason: .preparationFailed, underlying: MusicAssetPreparation.Failure.unsupported)
        var attempts: [URL] = []
        var initialSnapshot: MusicAssetPreparation.Snapshot? = try await MusicAssetPreparation.loadForPlayback(
            url: url, protectedAsset: false
        ) { candidate in
            attempts.append(candidate)
            if candidate == url { throw openFailure }
            let file = try AVAudioFile(forReading: candidate)
            precondition(file.length == Int64(buffer.frameLength))
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: buffer.frameLength)!
            try file.read(into: pcm)
            for ch in 0..<2 { for f in 0..<Int(buffer.frameLength) {
                precondition(pcm.floatChannelData![ch][f] == buffer.floatChannelData![ch][f])
            } }
        }
        precondition(attempts.count == 2 && initialSnapshot != nil)
        let initialCopy = initialSnapshot!.url
        precondition(FileManager.default.fileExists(atPath: initialCopy.path))
        initialSnapshot = nil
        precondition(!FileManager.default.fileExists(atPath: initialCopy.path))
        print("PASS: initial open failure retries readable local PCM, preserving samples and scoped lifetime")

        var exports = 0
        for blocked in [true, false] {
            var calls = 0
            do {
                _ = try await MusicAssetPreparation.loadForPlayback(url: url, protectedAsset: blocked,
                    makeSnapshot: { source in
                        exports += 1
                        return try await MusicAssetPreparation.playableSnapshot(url: source)
                    }, load: { _ in
                        calls += 1
                        if blocked { throw openFailure }
                        throw AudioPreparationFailure(stage: .streamingSession, reason: .preparationFailed,
                            underlying: MusicAssetPreparation.Failure.unsupported)
                    })
                fatalError("Non-source error or protected source retried")
            } catch is AudioPreparationFailure { }
            precondition(calls == 1 && exports == 0)
        }
        let direct = try await MusicAssetPreparation.loadForPlayback(url: url, protectedAsset: false,
            makeSnapshot: { _ in fatalError("Readable source should not export") }, load: { source in
                _ = try AVAudioFile(forReading: source)
            })
        precondition(direct == nil)
        print("PASS: native readable sources stay immediate; DRM/session errors do not enter export recovery")

        let cancelledRetry = Task { @MainActor in
            var calls = 0
            do {
                _ = try await MusicAssetPreparation.loadForPlayback(url: url, protectedAsset: false,
                    makeSnapshot: { source in
                        let copy = try await MusicAssetPreparation.playableSnapshot(url: source)
                        withUnsafeCurrentTask { $0?.cancel() }
                        return copy
                    }, load: { _ in calls += 1; throw openFailure })
                fatalError("Cancelled retry reached the graph")
            } catch is CancellationError { precondition(calls == 1) }
        }
        try await cancelledRetry.value
        print("PASS: cancellation between export and reload prevents stale graph mutation")

        for ext in ["wav", "aiff", "m4a"] {
            for channels: AVAudioChannelCount in [1, 2] {
                let source = directory.appendingPathComponent("cd-\(channels).\(ext)")
                let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: channels)!
                let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
                pcm.frameLength = pcm.frameCapacity
                for ch in 0..<Int(channels) { for f in 0..<Int(pcm.frameLength) {
                    pcm.floatChannelData![ch][f] = Float(sin(Double(f) * 0.08)) * (ch == 0 ? 0.4 : 0.2)
                } }
                var settings: [String: Any] = [AVSampleRateKey: 44_100, AVNumberOfChannelsKey: channels]
                if ext == "m4a" {
                    settings[AVFormatIDKey] = kAudioFormatAppleLossless
                    settings[AVEncoderBitDepthHintKey] = 16
                } else {
                    settings[AVFormatIDKey] = kAudioFormatLinearPCM
                    settings[AVLinearPCMBitDepthKey] = 16
                    settings[AVLinearPCMIsFloatKey] = false
                    settings[AVLinearPCMIsBigEndianKey] = ext == "aiff"
                }
                do { let file = try AVAudioFile(forWriting: source, settings: settings); try file.write(from: pcm) }
                let expectedFile = try AVAudioFile(forReading: source)
                let expected = AVAudioPCMBuffer(pcmFormat: expectedFile.processingFormat, frameCapacity: 44_100)!
                try expectedFile.read(into: expected)
                var attempts = 0
                let copy = try await MusicAssetPreparation.loadForPlayback(url: source, protectedAsset: false) { candidate in
                    attempts += 1
                    if candidate == source { throw openFailure }
                    let file = try AVAudioFile(forReading: candidate)
                    precondition(file.processingFormat.sampleRate == 44_100 && file.processingFormat.channelCount == channels)
                    let actual = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 44_100)!
                    try file.read(into: actual)
                    precondition(actual.frameLength == expected.frameLength)
                    for ch in 0..<Int(channels) { for f in 0..<Int(actual.frameLength) {
                        precondition(actual.floatChannelData![ch][f] == expected.floatChannelData![ch][f])
                    } }
                }
                precondition(copy != nil && attempts == 2)
                print("PASS: CD 44.1 kHz / 16-bit \(channels)-channel \(ext) read recovery preserves decoded PCM")
            }
        }

        if CommandLine.arguments.count > 1 {
            for path in CommandLine.arguments.dropFirst() {
                let source = URL(fileURLWithPath: path)
                let result = try await MusicAssetPreparation.playableSnapshot(url: source)
                let readable = try AVAudioFile(forReading: result.url)
                precondition(readable.length > 0)
                let decodedCopy = try await MusicAssetPreparation.decodedSnapshot(url: source)
                let expected = try AVAudioFile(forReading: source)
                let actual = try AVAudioFile(forReading: decodedCopy.url)
                precondition(actual.processingFormat.sampleRate == expected.processingFormat.sampleRate)
                precondition(actual.processingFormat.channelCount == expected.processingFormat.channelCount)
                precondition(abs(Double(actual.length - expected.length) / expected.processingFormat.sampleRate) < 0.05)
                print("PASS: playable snapshot and PCM fallback for \(source.lastPathComponent)")
            }
        }

    }
}
