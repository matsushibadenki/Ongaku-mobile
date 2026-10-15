import AVFoundation
import Foundation

/// Actual shipping meter stores, audit refresh, invalidation and gain law.
/// Only time, transport and tap arrival order are controlled here.
@main struct MeterDeliveryRegression {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        if !value() { fatalError(message) }
    }

    static func main() {
        for modern in [false, true] {
            DispatchQueue.main.reset()
            let host = ShippingDSPTransition(player: AVAudioPlayerNode(),
                eq: AVAudioUnitEQ(numberOfBands: 4), output: AVAudioMixerNode(),
                effects: AudioEffectModuleRegistry.makePipeline())
            host.useObservedMeters = true
            host.useRealGainPath = true
            host.acceptStaleForNegativeControl = CommandLine.arguments.contains("--stale-fixture")
            let count = host.effectPipeline.count + 2
            let store: any MeterLevelStore = modern
                ? ModernMeterLevelStore(count: count) : LegacyMeterLevelStore(count: count)
            host.meterLevels = store
            var settings = AudioEffectModuleRegistry.makeDefaultSettings()
            for i in settings.indices { settings[i].isEnabled = i < 2 }
            host.apply(effectSettings: settings)

            func deliver(_ time: Double, stage: Int? = nil, duration: Double = 0.02) {
                for i in 0..<count where stage == nil || stage == i {
                    store.tryUpdate(index: i, levels: EffectMeterObservation(
                        peakDBFS: -40 + Float(i * 3), rmsDBFS: -50 + Float(i * 3),
                        renderedAt: time, duration: duration))
                }
            }
            DispatchQueue.main.advance(to: 1)
            deliver(0.94)
            require(!host.refreshEffectLevelAudits().isEmpty, "Fresh coherent measurements rejected")
            host.lastGainStagingDate = Date(timeIntervalSince1970: 0.99)
            host.applyGainStaging(effectSettings: settings)
            let boost = host.smoothedMeasuredEffectBoostDB
            require(boost > 0, "Valid observations did not influence gain")
            let trim = host.plannedOutputTrimDB
            DispatchQueue.main.advance(to: 1.1)
            host.applyGainStaging(effectSettings: settings)
            require(host.smoothedMeasuredEffectBoostDB == boost && host.plannedOutputTrimDB == trim,
                    "Duplicate observation advanced smoothing")

            DispatchQueue.main.advance(to: 1.3)
            require(host.refreshEffectLevelAudits().isEmpty, "Expired measurement reused")
            host.applyGainStaging(effectSettings: settings)
            let estimatedTrim = host.plannedOutputTrimDB
            require(estimatedTrim.isFinite, "Invalid estimate fallback")
            // 887.5 ms delivery delay, matching the prior tap-delay report.
            deliver(1.3 - 0.8875)
            require(host.refreshEffectLevelAudits().isEmpty, "Delayed measurement reused")
            host.applyGainStaging(effectSettings: settings)
            require(host.plannedOutputTrimDB == estimatedTrim, "Stale audit changed gain")

            deliver(1.28)
            require(!host.refreshEffectLevelAudits().isEmpty, "Fresh replacement rejected")
            host.invalidateEffectLevelAudits() // settings, seek or source change
            deliver(1.29) // arrives later, but contains old PCM
            require(host.refreshEffectLevelAudits().isEmpty, "Pre-change PCM survived invalidation")
            DispatchQueue.main.advance(to: 1.4)
            deliver(1.36)
            require(!host.refreshEffectLevelAudits().isEmpty, "Post-change PCM rejected")

            // Adjacent stages can arrive out of order and describe different windows.
            deliver(1.38, stage: 1)
            let incomplete = host.refreshEffectLevelAudits()
            require(!incomplete.contains { $0.kind == host.effectPipeline[0].kind },
                    "Unaligned input/output compared")
            require(host.measuredEffectBoostFromAudits(effectSettings: settings) == nil,
                    "Incomplete enabled chain used for gain")
            deliver(1.38)
            require(!host.refreshEffectLevelAudits().isEmpty, "Aligned chain did not recover")
            deliver(1.36, stage: 1)
            require(store.snapshot()[1].renderedAt == 1.38, "Out-of-order delivery replaced newer PCM")

            host.pendingHandoff = true
            require(host.refreshEffectLevelAudits().isEmpty, "Mixed handoff PCM used for gain")
            host.pendingHandoff = nil
            host.invalidateEffectLevelAudits()
            require(host.refreshEffectLevelAudits().isEmpty, "Pre-handoff PCM accepted after commit")
            DispatchQueue.main.advance(to: 1.5)
            deliver(1.46)
            require(!host.refreshEffectLevelAudits().isEmpty, "Post-handoff PCM rejected")

            let unavailable = UnavailableMeterStore(count: count)
            host.meterLevels = unavailable
            require(host.refreshEffectLevelAudits().isEmpty, "Contended store reused cached audit")
            // A retired tap retains its own store after graph replacement.
            host.meterLevels = LegacyMeterLevelStore(count: count)
            deliver(1.48)
            require(host.refreshEffectLevelAudits().isEmpty, "Old store contaminated replacement")
            store.clear()
            require(store.snapshot().allSatisfy { !$0.renderedAt.isFinite }, "Clear retained timestamps")

            host.meterLevels = store
            host.invalidateEffectLevelAudits()
            host.lastGainStagingDate = Date(timeIntervalSince1970: 1.99)
            var previousBoost: Float = 0
            for step in 0...25 {
                let now = 2 + Double(step) * 0.02
                DispatchQueue.main.advance(to: now)
                deliver(now - 0.04)
                host.applyGainStaging(effectSettings: settings)
                let current = host.smoothedMeasuredEffectBoostDB
                require(current >= previousBoost && current <= 4.80001,
                        "Fresh observation convergence overshot or reversed")
                previousBoost = current
            }
            require(abs(previousBoost - 4.8) < 0.001, "Fresh observations did not converge")
            print("PASS: \(modern ? "modern" : "legacy") store: fresh/delayed/stale/reordered PCM, settings/source invalidation, handoff and contention")
            print("PASS: duplicate reads preserve gain; 26 fresh observations converge to \(previousBoost) dB")
        }

        let good = EffectMeterObservation(peakDBFS: -12, rmsDBFS: -20, renderedAt: 1, duration: 0.02)
        for bad in [
            EffectMeterObservation(peakDBFS: .nan, rmsDBFS: -20, renderedAt: 1, duration: 0.02),
            EffectMeterObservation(peakDBFS: -12, rmsDBFS: .infinity, renderedAt: 1, duration: 0.02),
            EffectMeterObservation(peakDBFS: -12, rmsDBFS: -20, renderedAt: .infinity, duration: 0.02),
            EffectMeterObservation(peakDBFS: -12, rmsDBFS: -20, renderedAt: 1, duration: 0),
            EffectMeterObservation(peakDBFS: -12, rmsDBFS: -20, renderedAt: 1, duration: 0.04),
            EffectMeterObservation(peakDBFS: -12, rmsDBFS: -20, renderedAt: 2, duration: 0.02)
        ] {
            require(!good.matches(bad, now: 1.03, validSince: 0), "Invalid or different PCM window accepted")
        }
        print("PASS: nonfinite/future/missing timestamps and mismatched buffer windows rejected")
    }
}

nonisolated final class UnavailableMeterStore: MeterLevelStore, @unchecked Sendable {
    let count: Int
    init(count: Int) { self.count = count }
    func snapshot() -> [EffectMeterObservation] { Array(repeating: .empty, count: count) }
    func snapshotIfAvailable() -> [EffectMeterObservation]? { nil }
    func tryUpdate(index: Int, levels: EffectMeterObservation) {}
    func clear() {}
}
