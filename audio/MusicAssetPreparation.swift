import AVFoundation
import Foundation

/// A validated disk snapshot isolates background preparation from the audible
/// Music asset. Use passthrough or chunked PCM; never access protected samples.
nonisolated enum MusicAssetPreparation {
    final class Snapshot: @unchecked Sendable {
        let url: URL
        private let directory: URL
        init(url: URL, directory: URL) { self.url = url; self.directory = directory }
        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private final class Reader: @unchecked Sendable {
        let reader: AVAssetReader
        init(_ reader: AVAssetReader) { self.reader = reader }
    }

    private final class Export: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    enum Failure: Error, AudioPreparationFailureReasonProviding {
        case protected, unsupported, incomplete, tooLarge, timedOut
        var preparationFailureReason: AudioPreparationFailure.Reason {
            self == .tooLarge ? .capacityExceeded : .preparationFailed
        }
    }


    /// Passthrough containers are not necessarily readable by AVAudioFile
    /// (for example an audio track carried in MOV). Decode through AVFoundation
    /// if export or the resulting file cannot be used by the playback engine.
    /// Never re-encode lossy audio or change the source rate/channel count.
    static func playableSnapshot(
        url: URL,
        timeout: Duration = .seconds(120),
        passthrough: @escaping @Sendable (URL) async throws -> Snapshot = { try await snapshot(url: $0) }
    ) async throws -> Snapshot {
        try await withThrowingTaskGroup(of: Snapshot.self) { group in
            group.addTask { try await preparePlayableSnapshot(url: url, passthrough: passthrough) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw Failure.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private static func preparePlayableSnapshot(
        url: URL, passthrough: @Sendable (URL) async throws -> Snapshot
    ) async throws -> Snapshot {
        do {
            let copy = try await passthrough(url)
            let check = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                let file = try AVAudioFile(forReading: copy.url)
                guard file.length > 0 else { throw Failure.incomplete }
            }
            try await withTaskCancellationHandler { try await check.value } onCancel: { check.cancel() }
            try Task.checkCancellation()
            return copy
        } catch is CancellationError { throw CancellationError() }
        catch Failure.protected { throw Failure.protected }
        catch {
            try Task.checkCancellation()
            return try await decodedSnapshot(url: url)
        }
    }

    /// Bounded PCM chunks go straight to disk; no full-song PCM allocation.
    static func decodedSnapshot(url: URL, maximumBytes: Int64 = 512 * 1024 * 1024) async throws -> Snapshot {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: url)
            guard try await !asset.load(.hasProtectedContent) else { throw Failure.protected }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0,
                  let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure.unsupported }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ])
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw Failure.unsupported }
            reader.add(output)
            let cancellation = Reader(reader)
            return try await withTaskCancellationHandler {
                try writeDecodedSnapshot(reader: reader, output: output, duration: duration, maximumBytes: maximumBytes)
            } onCancel: { cancellation.reader.cancelReading() }
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    private static func writeDecodedSnapshot(
        reader: AVAssetReader, output: AVAssetReaderTrackOutput,
        duration: TimeInterval, maximumBytes: Int64
    ) throws -> Snapshot {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuMusic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = Snapshot(url: directory.appendingPathComponent("decoded.caf"), directory: directory)
        defer { reader.cancelReading() }
        guard reader.startReading() else { throw reader.error ?? Failure.unsupported }
        var file: AVAudioFile?
        var framesWritten: Int64 = 0
        var bytesWritten: Int64 = 0
        while true {
            try Task.checkCancellation()
            let hasSample = try autoreleasepool { () throws -> Bool in
                guard let sample = output.copyNextSampleBuffer() else { return false }
                guard let description = CMSampleBufferGetFormatDescription(sample),
                      let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                      let format = AVAudioFormat(streamDescription: asbd),
                      format.sampleRate > 0, format.channelCount > 0 else { throw Failure.unsupported }
                if file == nil {
                    guard duration * format.sampleRate * Double(format.channelCount) * 4 <= Double(maximumBytes) else {
                        throw Failure.tooLarge
                    }
                    file = try AVAudioFile(forWriting: copy.url, settings: format.settings,
                                           commonFormat: .pcmFormatFloat32, interleaved: format.isInterleaved)
                }
                guard let file, file.processingFormat == format else { throw Failure.unsupported }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                // Reject gaps/edits instead of shifting the song under the live playhead.
                guard timestamp.isFinite,
                      abs(timestamp - Double(framesWritten) / format.sampleRate) < 0.05 else { throw Failure.incomplete }
                let totalFrames = CMSampleBufferGetNumSamples(sample)
                var offset = 0
                while offset < totalFrames {
                    try Task.checkCancellation()
                    let count = min(8192, totalFrames - offset)
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else {
                        throw Failure.incomplete
                    }
                    buffer.frameLength = AVAudioFrameCount(count)
                    guard offset <= Int(Int32.max),
                          CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: Int32(offset), frameCount: Int32(count), into: buffer.mutableAudioBufferList) == noErr else {
                        throw Failure.incomplete
                    }
                    bytesWritten += Int64(count) * Int64(format.channelCount) * 4
                    guard bytesWritten <= maximumBytes else { throw Failure.tooLarge }
                    try file.write(from: buffer)
                    framesWritten += Int64(count)
                    offset += count
                }
                return true
            }
            if !hasSample { break }
        }
        try Task.checkCancellation()
        guard reader.status == .completed else { throw reader.error ?? Failure.incomplete }
        guard let completed = file, framesWritten > 0,
              abs(Double(framesWritten) / completed.processingFormat.sampleRate - duration) < 0.05 else {
            throw Failure.incomplete
        }
        file = nil
        return copy
    }

    static func snapshot(url: URL) async throws -> Snapshot {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: url)
        guard try await !asset.load(.hasProtectedContent) else { throw Failure.protected }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw Failure.unsupported
        }
        let candidates: [(AVFileType, String)] = [(.m4a, "m4a"), (.caf, "caf"), (.mov, "mov")]
        guard let format = candidates.first(where: { session.supportedFileTypes.contains($0.0) }) else {
            throw Failure.unsupported
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("OngakuMusic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let snapshot = Snapshot(url: directory.appendingPathComponent("source.\(format.1)"), directory: directory)
        session.outputURL = snapshot.url
        session.outputFileType = format.0
        session.fileLengthLimit = 512 * 1024 * 1024
        let export = Export(session)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await withCheckedContinuation { continuation in
                export.session.exportAsynchronously { continuation.resume() }
                if Task.isCancelled { export.session.cancelExport() }
            }
            try Task.checkCancellation()
            guard export.session.status == .completed else {
                throw export.session.error ?? Failure.incomplete
            }
        } onCancel: { export.session.cancelExport() }
        // A size-limited export may finish early. Never replace the full song
        // with a truncated snapshot or one that changes its timeline.
        let originalDuration = try await asset.load(.duration).seconds
        let copiedDuration = try await AVURLAsset(url: snapshot.url).load(.duration).seconds
        guard originalDuration.isFinite, originalDuration > 0,
              copiedDuration.isFinite, abs(originalDuration - copiedDuration) < 0.05 else { throw Failure.incomplete }
        return snapshot
    }
}
