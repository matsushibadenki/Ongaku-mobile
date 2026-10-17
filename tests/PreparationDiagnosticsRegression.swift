import AVFoundation
import Foundation

@main struct PreparationDiagnosticsRegression {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: message, code: 1) }
    }
    static func failure(_ operation: () throws -> Void) throws -> AudioPreparationFailure {
        do { try operation() }
        catch let failure as AudioPreparationFailure { return failure }
        throw NSError(domain: "Expected a staged preparation failure", code: 1)
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let valid = root.appendingPathComponent("valid.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096)!
        pcm.frameLength = 4096
        for c in 0..<2 { pcm.floatChannelData![c].initialize(repeating: 0.125, count: 4096) }
        do { let file = try AVAudioFile(forWriting: valid, settings: format.settings); try file.write(from: pcm) }
        try ShippingPreparationPreflight.validateOfflinePreparation(url: valid, upsamplingMode: .precisionSincLinearEco)
        print("PASS: readable metadata passes the real offline preflight")

        let corrupt = root.appendingPathComponent("corrupt.caf")
        try Data("not audio".utf8).write(to: corrupt)
        for url in [root.appendingPathComponent("missing.caf"), corrupt] {
            let f = try failure { try ShippingPreparationPreflight.validateOfflinePreparation(url: url, upsamplingMode: .precisionSincLinearEco) }
            try require(f.stage == .offlineOpen && f.reason == .preparationFailed, "Unreadable source was mislabeled as capacity exceeded")
            let nativeError: NSError
            do { _ = try AVAudioFile(forReading: url); fatalError("Fixture opened") }
            catch { nativeError = error as NSError }
            let underlying = f.underlying as NSError
            try require(underlying.domain == nativeError.domain && underlying.code == nativeError.code, "Original decoder error was lost")
            try require(f.localizedDescription == f.underlying.localizedDescription, "Localized UI description changed")
        }
        print("PASS: missing/corrupt sources retain offline_open, preparation_failed and original domain/code")

        simulatedAvailableMemory = 1 // Force the real live-allocation budget without allocating a large buffer.
        let capacity = try failure { try ShippingPreparationPreflight.validateOfflinePreparation(url: valid, upsamplingMode: .precisionSincLinearEco) }
        simulatedAvailableMemory = 0
        try require(capacity.stage == .offlineBudget && capacity.reason == .capacityExceeded, "Allocation guard lost its capacity reason")
        let size = try failure {
            try AudioPreparationFailure.at(.offlineBudget) {
                try ShippingPreparationPreflight.validateOfflineBufferFootprint(frameCount: UInt32.max, format: format)
            }
        }
        try require(size.reason == .capacityExceeded, "Buffer size limit lost its capacity reason")
        let frames = try failure {
            try AudioPreparationFailure.at(.offlineBudget) {
                _ = try ShippingPreparationPreflight.checkedAudioFrameCount(Double(UInt32.max) + 1,
                    format: format, failure: .sourceBufferFailed)
            }
        }
        let invalid = try failure {
            try AudioPreparationFailure.at(.offlineBudget) {
                _ = try ShippingPreparationPreflight.checkedAudioFrameCount(-1.0,
                    format: format, failure: .sourceBufferFailed)
            }
        }
        try require(frames.reason == .capacityExceeded && invalid.reason == .preparationFailed,
                    "Oversized frames and invalid metadata must remain distinct")
        print("PASS: live memory, buffer size and frame-count limits differ from invalid metadata")

        for error in [MusicAssetPreparation.Failure.tooLarge, RemoteAudioCacheError.fileTooLarge(100)] as [any Error] {
            let f = try failure { try AudioPreparationFailure.at(.assetSnapshot) { throw error } }
            try require(f.reason == .capacityExceeded, "Snapshot/cache size limit lost capacity reason")
        }
        for error in [MusicAssetPreparation.Failure.timedOut, RemoteAudioCacheError.copyFailed] as [any Error] {
            let f = try failure { try AudioPreparationFailure.at(.assetSnapshot) { throw error } }
            try require(f.reason == .preparationFailed, "Snapshot/cache failure mislabeled as capacity")
        }
        print("PASS: snapshot/cache size limits are distinct from timeout/copy failures")

        let mode = try failure { try ShippingPreparationPreflight.validateOfflinePreparation(url: valid, upsamplingMode: .avAudioConverter) }
        try require(mode.stage == .offlinePreflight && mode.reason == .unsupportedMode, "Unsupported mode was mislabeled")
        print("PASS: non-Precision mode has its own unsupported_mode reason")

        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try ShippingPreparationPreflight.validateOfflinePreparation(url: valid, upsamplingMode: .precisionSincLinearEco)
        }
        do { try await cancelled.value; throw NSError(domain: "Cancelled preflight succeeded", code: 1) }
        catch is CancellationError {}
        do { try AudioPreparationFailure.at(.offlineConversion) { throw CancellationError() } }
        catch is CancellationError {}
        print("PASS: preflight and nested-stage cancellation preserve CancellationError")

        let original = NSError(domain: "Decoder\n\"test\"", code: -123, userInfo: [NSLocalizedDescriptionKey:"Original message", "URL":"secret://file"])
        for stage in [AudioPreparationFailure.Stage.streamingSession, .streamingGraph, .streamingStart, .offlineConversion, .offlineSpatial, .offlineValidation, .qualityHandoff, .assetSnapshot] {
            let f = try failure {
                try AudioPreparationFailure.at(.cachePreparation) {
                    try AudioPreparationFailure.at(stage) { throw original }
                }
            }
            try require(f.stage == stage && f.reason == .preparationFailed, "Outer stage replaced original failure")
            let line = AudioPreparationFailure.diagnostic(f, fallbackStage: .offlinePreflight)
            try require(line.contains("stage=\(stage.rawValue)") && line.contains("errorCode=-123") && !line.contains("\n") && !line.contains("secret://"), "Diagnostic fields are ambiguous or expose userInfo")
        }
        print("PASS: inner stages survive outer catches; single-line logs retain domain/code without arbitrary userInfo")

        let failureSource = root.appendingPathComponent("no-stream.caf")
        do { _ = try await StreamingAudioFilePreparation.open(url: failureSource); fatalError("Missing stream opened") }
        catch let f as AudioPreparationFailure {
            try require(f.stage == .streamingOpen && f.reason == .preparationFailed, "Streaming open mislabeled as offline conversion")
        }
        print("PASS: actual streaming worker failure is streaming_open, not Precision Sinc")
        print("PASS: preparation diagnostic regressions complete")
    }
}
