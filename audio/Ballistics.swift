import Foundation

/// Fixed digital alignment for the analog-style VU scale.
/// 0 VU is calibrated to -18 dBFS, leaving 3 dB of visible headroom while
/// preserving 20 dB of readable program dynamics below the reference level.
enum VUMeterScale {
    nonisolated static let referenceDBFS = -18.0
    nonisolated static let minimumVU = -20.0
    nonisolated static let maximumVU = 3.0

    nonisolated static func normalizedValue(rmsDBFS: Double) -> Double {
        guard rmsDBFS.isFinite, rmsDBFS > -100 else { return 0 }
        let vu = rmsDBFS - referenceDBFS
        return max(0, min(1, (vu - minimumVU) / (maximumVU - minimumVU)))
    }
}

final class BallisticSimulator {
    private(set) var value: Double = 0
    private var lastUpdate: TimeInterval = 0

    // A 65 ms attack time constant reaches approximately 99% in 300 ms,
    // close to classic VU-meter rise behavior. Release is intentionally slower.
    private let attackTimeConstant = 0.065
    private let releaseTimeConstant = 0.30

    func reset(to newValue: Double = 0) {
        value = max(0, min(1.0, newValue))
        lastUpdate = 0
    }
    
    @discardableResult
    func update(target: Double, date: Date) -> Double {
        let now = date.timeIntervalSinceReferenceDate
        if lastUpdate == 0 {
            lastUpdate = now
            return value
        }
        let dt = max(0.001, min(now - lastUpdate, 0.05))
        lastUpdate = now
        
        let clampedTarget = max(0, min(1.0, target))
        let diff = clampedTarget - value
        let timeConstant = diff >= 0 ? attackTimeConstant : releaseTimeConstant
        let response = 1 - exp(-dt / timeConstant)
        value = max(0, min(1.0, value + diff * response))
        return value
    }
}
