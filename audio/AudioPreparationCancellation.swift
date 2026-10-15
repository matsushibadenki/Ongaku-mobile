import Foundation

/// A serial worker can discard superseded jobs before allocating PCM and check
/// for cancellation inside long DSP loops without accessing main-actor state.
nonisolated final class AudioPreparationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() { lock.withLock { cancelled = true } }
    func check() throws {
        if lock.withLock({ cancelled }) { throw CancellationError() }
    }
}
