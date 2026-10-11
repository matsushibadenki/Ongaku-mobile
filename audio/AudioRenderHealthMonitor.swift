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
    let tapDeliveryGapMilliseconds: Double?
    let renderCallbackCount: UInt64
}

/// Observes render-cycle scheduling, independently of meter-tap delivery.
/// A render gap is diagnostic evidence, not a measurement of audible silence.
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
        var lastTapNanoseconds: UInt64 = 0
        var pendingTapDeliveryGapNanoseconds: UInt64?
        var renderCallbackCount: UInt64 = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    nonisolated private static let minimumDropoutThresholdNanoseconds: UInt64 = 350_000_000
    nonisolated private static let firstRenderGraceNanoseconds: UInt64 = 1_000_000_000

    nonisolated init() {}

    nonisolated func beginMonitoring(nowNanoseconds: UInt64? = nil) {
        let now = nowNanoseconds ?? Self.nowNanoseconds()
        lock.withLock { state in
            state.isMonitoring = true
            state.monitoringStartedNanoseconds = now
            state.lastRenderNanoseconds = 0
            state.expectedCallbackIntervalNanoseconds = 100_000_000
            state.isStalled = false
            state.stallStartedNanoseconds = 0
            state.pendingDetectedGapNanoseconds = nil
            state.pendingRecoveryNanoseconds = nil
            state.lastTapNanoseconds = 0
            state.pendingTapDeliveryGapNanoseconds = nil
            state.renderCallbackCount = 0
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
            state.lastTapNanoseconds = 0
            state.pendingTapDeliveryGapNanoseconds = nil
        }
    }

    /// Called from the Audio Unit's pre-render observer. Lock contention is skipped rather
    /// than blocking the render thread.
    nonisolated func recordRender(frameCount: AVAudioFrameCount, sampleRate: Double,
                                  nowNanoseconds: UInt64? = nil) {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return }
        let now = nowNanoseconds ?? Self.nowNanoseconds()
        let expectedInterval = UInt64(
            (Double(frameCount) / sampleRate * 1_000_000_000).rounded()
        )

        _ = lock.withLockIfAvailable { state in
            guard state.isMonitoring else { return }
            state.renderCallbackCount &+= 1

            state.expectedCallbackIntervalNanoseconds = max(1, expectedInterval)
            if state.isStalled {
                // This also handles recovery when no first callback arrived
                // during startup. Previously it remained stalled forever.
                let recoveryDuration = now &- state.stallStartedNanoseconds
                state.pendingRecoveryNanoseconds = max(state.pendingRecoveryNanoseconds ?? 0, recoveryDuration)
                state.maxRenderGapNanoseconds = max(state.maxRenderGapNanoseconds, recoveryDuration)
                state.isStalled = false
                state.stallStartedNanoseconds = 0
            } else if state.lastRenderNanoseconds > 0 {
                let gap = now &- state.lastRenderNanoseconds
                let threshold = Self.dropoutThreshold(
                    expectedIntervalNanoseconds: state.expectedCallbackIntervalNanoseconds
                )

                if gap > threshold {
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

    /// Meter delivery can be delayed while render cycles continue normally.
    /// Record it separately; it must never increment the render-gap count.
    nonisolated func recordTapDelivery(frameCount: AVAudioFrameCount, sampleRate: Double,
                                       nowNanoseconds: UInt64? = nil) {
        guard frameCount > 0, sampleRate.isFinite, sampleRate > 0 else { return }
        let now = nowNanoseconds ?? Self.nowNanoseconds()
        let interval = UInt64((Double(frameCount) / sampleRate * 1_000_000_000).rounded())
        _ = lock.withLockIfAvailable { state in
            guard state.isMonitoring else { return }
            if state.lastTapNanoseconds > 0 {
                let gap = now &- state.lastTapNanoseconds
                if gap > Self.dropoutThreshold(expectedIntervalNanoseconds: max(1, interval)) {
                    state.pendingTapDeliveryGapNanoseconds = max(
                        state.pendingTapDeliveryGapNanoseconds ?? 0, gap
                    )
                }
            }
            state.lastTapNanoseconds = now
        }
    }

    nonisolated func poll(expectedToRender: Bool, nowNanoseconds: UInt64? = nil) -> AudioRenderHealthPollResult {
        let now = nowNanoseconds ?? Self.nowNanoseconds()
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
                recoveredAfterMilliseconds: state.pendingRecoveryNanoseconds.map(Self.milliseconds),
                tapDeliveryGapMilliseconds: state.pendingTapDeliveryGapNanoseconds.map(Self.milliseconds),
                renderCallbackCount: state.renderCallbackCount
            )
            state.pendingDetectedGapNanoseconds = nil
            state.pendingRecoveryNanoseconds = nil
            state.pendingTapDeliveryGapNanoseconds = nil
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
