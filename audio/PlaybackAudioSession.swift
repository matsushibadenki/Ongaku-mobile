import AVFoundation
import Foundation

/// Serialize potentially blocking audio-session IPC away from MainActor.
/// The queue is immutable; all AVAudioSession mutations happen on this queue.
nonisolated final class PlaybackAudioSession: Sendable {
    static let shared = PlaybackAudioSession()
    private let queue = DispatchQueue(label: "audio.session.control", qos: .userInitiated)

    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.withLock { cancelled = true } }
        func check() throws {
            if lock.withLock({ cancelled }) { throw CancellationError() }
        }
    }

    func activate(preferredSampleRate: Double? = nil) async throws {
        try Task.checkCancellation()
        let cancellation = CancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        // A cancelled request may have been waiting behind slow IPC.
                        // Do not activate it just because its queue slot has arrived.
                        try cancellation.check()
                        dispatchPrecondition(condition: .notOnQueue(.main))
                        let session = AVAudioSession.sharedInstance()
                        if session.category != .playback || session.mode != .default || !session.categoryOptions.isEmpty {
                            try session.setCategory(.playback, mode: .default, options: [])
                        }
                        if let rate = preferredSampleRate {
                            // Compare preferences, not hardware rate: a 48 kHz device
                            // need not be reconfigured repeatedly for a 96 kHz graph.
                            if abs(session.preferredSampleRate - rate) > 0.1 {
                                try session.setPreferredSampleRate(rate)
                            }
                            if abs(session.preferredIOBufferDuration - 0.01) > 0.0001 {
                                try session.setPreferredIOBufferDuration(0.01)
                            }
                        }
                        try cancellation.check()
                        try session.setActive(true)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        // setActive itself cannot be cancelled. Never let its completion restart
        // playback on behalf of a task cancelled while the system call ran.
        try Task.checkCancellation()
    }

    func releaseForSystemPlayback() async throws {
        // Wait for older queued activations before handing audio to Music.
        // No notifyOthers option: the selected Music queue decides what plays.
        try Task.checkCancellation()
        let cancellation = CancellationFlag()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                queue.async {
                    do {
                        try cancellation.check()
                    } catch {
                        continuation.resume(throwing: error)
                        return
                    }
                    do {
                        try AVAudioSession.sharedInstance().setActive(false)
                    } catch {
                        PlaybackDebugLogger.warning("audio.session.system_handoff_failed error=\(error.localizedDescription)")
                    }
                    continuation.resume()
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
    }

    func deactivate() {
        // Enqueue immediately, not via a new Task, to preserve request ordering
        // with an activation already in flight when the user presses stop.
        queue.async {
            do {
                try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            } catch {
                PlaybackDebugLogger.warning("audio.session.deactivation_failed error=\(error.localizedDescription)")
            }
        }
    }
}
