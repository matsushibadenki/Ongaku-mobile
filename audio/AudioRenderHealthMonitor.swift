import AVFoundation
import Foundation
import os.lock

struct AudioRenderHealthSnapshot: Equatable, Sendable {
    let dropoutCount: Int
    let isStalled: Bool
    let maxRenderGapMilliseconds: Double

    static let healthy = AudioRenderHealthSnapshot(
        dropoutCount: 0,
        isStalled: false,
        maxRenderGapMilliseconds: 0
    )
}

struct AudioRenderHealthPollResult: Sendable {
    let snapshot: AudioRenderHealthSnapshot
    let detectedGapMilliseconds: Double?
    let recoveredAfterMilliseconds: Double?
}

/// Detects audible render stalls from the final-output tap heartbeat.
/// Silence is not treated as a dropout because the render callback continues
/// to arrive even when sample values are zero.
final class AudioRenderHealthMonitor: @unchecked Sendable {
    private struct State: Sendable {
        var isMonitoring = false
        var monitoringStartedNanoseconds: UInt64 = 0
        var lastRenderNanoseconds: UInt64 = 0
        var expectedCallbackIntervalNanoseconds: UInt64 = 100_000_000
        var isStalled = false
        var stallStartedNanoseconds: UInt64 = 0
        var dropoutCount = 0
        var maxRenderGapNanoseconds: UInt64 = 0
        var pendingDetectedGapNanoseconds: UInt64?
        var pendingRecoveryNanoseconds: UInt64?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    nonisolated private static let minimumDropoutThresholdNanoseconds: UInt64 = 350_000_000
    nonisolated private static let firstRenderGraceNanoseconds: UInt64 = 1_000_000_000

    nonisolated init() {}

    nonisolated func beginMonitoring() {
        let now = Self.nowNanoseconds()
        lock.withLock { state in
            state.isMonitoring = true
            state.monitoringStartedNanoseconds = now
            state.lastRenderNanoseconds = 0
            state.expectedCallbackIntervalNanoseconds = 100_000_000
            state.isStalled = false
            state.stallStartedNanoseconds = 0
            state.pendingDetectedGapNanoseconds = nil
            state.pendingRecoveryNanoseconds = nil
        }
    }

    nonisolated func endMonitoring() {
        lock.withLock { state in
            state.isMonitoring = false
            state.lastRenderNanoseconds = 0
            state.isStalled = false
            state.stallStartedNanoseconds = 0
            state.pendingDetectedGapNanoseconds = nil
            state.pendingRecoveryNanoseconds = nil
        }
    }

    /// Called from the realtime audio tap. Lock contention is skipped rather
    /// than blocking the render thread.
    nonisolated func recordRender(frameCount: AVAudioFrameCount, sampleRate: Double) {
        guard frameCount > 0, sampleRate > 0 else { return }
        let now = Self.nowNanoseconds()
        let expectedInterval = UInt64(
            (Double(frameCount) / sampleRate * 1_000_000_000).rounded()
        )

        _ = lock.withLockIfAvailable { state in
            guard state.isMonitoring else { return }

            state.expectedCallbackIntervalNanoseconds = max(1, expectedInterval)
            if state.lastRenderNanoseconds > 0 {
                let gap = now &- state.lastRenderNanoseconds
                let threshold = Self.dropoutThreshold(
                    expectedIntervalNanoseconds: state.expectedCallbackIntervalNanoseconds
                )

                if state.isStalled {
                    let recoveryDuration = now &- state.stallStartedNanoseconds
                    state.pendingRecoveryNanoseconds = max(
                        state.pendingRecoveryNanoseconds ?? 0,
                        recoveryDuration
                    )
                    state.maxRenderGapNanoseconds = max(
                        state.maxRenderGapNanoseconds,
                        recoveryDuration
                    )
                    state.isStalled = false
                    state.stallStartedNanoseconds = 0
                } else if gap > threshold {
                    state.dropoutCount += 1
                    state.maxRenderGapNanoseconds = max(state.maxRenderGapNanoseconds, gap)
                    state.pendingDetectedGapNanoseconds = max(
                        state.pendingDetectedGapNanoseconds ?? 0,
                        gap
                    )
                    // The delayed callback itself confirms recovery.
                    state.pendingRecoveryNanoseconds = max(
                        state.pendingRecoveryNanoseconds ?? 0,
                        gap
                    )
                }
            }
            state.lastRenderNanoseconds = now
        }
    }

    nonisolated func poll(expectedToRender: Bool) -> AudioRenderHealthPollResult {
        let now = Self.nowNanoseconds()
        return lock.withLock { state in
            if state.isMonitoring, expectedToRender {
                let hasRendered = state.lastRenderNanoseconds > 0
                let baseline = hasRendered
                    ? state.lastRenderNanoseconds
                    : state.monitoringStartedNanoseconds
                let threshold = hasRendered
                    ? Self.dropoutThreshold(
                        expectedIntervalNanoseconds: state.expectedCallbackIntervalNanoseconds
                    )
                    : Self.firstRenderGraceNanoseconds
                let gap = now &- baseline

                if gap > threshold, !state.isStalled {
                    state.isStalled = true
                    state.stallStartedNanoseconds = baseline
                    state.dropoutCount += 1
                    state.maxRenderGapNanoseconds = max(state.maxRenderGapNanoseconds, gap)
                    state.pendingDetectedGapNanoseconds = max(
                        state.pendingDetectedGapNanoseconds ?? 0,
                        gap
                    )
                } else if state.isStalled {
                    state.maxRenderGapNanoseconds = max(state.maxRenderGapNanoseconds, gap)
                }
            }

            let snapshot = AudioRenderHealthSnapshot(
                dropoutCount: state.dropoutCount,
                isStalled: state.isStalled,
                maxRenderGapMilliseconds: Self.milliseconds(state.maxRenderGapNanoseconds)
            )
            let result = AudioRenderHealthPollResult(
                snapshot: snapshot,
                detectedGapMilliseconds: state.pendingDetectedGapNanoseconds.map(Self.milliseconds),
                recoveredAfterMilliseconds: state.pendingRecoveryNanoseconds.map(Self.milliseconds)
            )
            state.pendingDetectedGapNanoseconds = nil
            state.pendingRecoveryNanoseconds = nil
            return result
        }
    }

    nonisolated private static func dropoutThreshold(
        expectedIntervalNanoseconds: UInt64
    ) -> UInt64 {
        max(minimumDropoutThresholdNanoseconds, expectedIntervalNanoseconds * 4)
    }

    nonisolated private static func nowNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    nonisolated private static func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }
}
