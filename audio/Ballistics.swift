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

/// Keep the needle responsive without doubling the existing 15 Hz spectrum UI work.
enum MeterVisualizationTiming {
    static let refreshRate = 60.0
    static let spectrumStride = 4

    static func makeTimer(target: Any, selector: Selector) -> Timer {
        let timer = Timer(timeInterval: 1 / refreshRate, target: target,
                          selector: selector, userInfo: nil, repeats: true)
        timer.tolerance = 0.001
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

final class BallisticSimulator {
    private(set) var value: Double = 0
    private var lastUpdate: TimeInterval?

    // A 65 ms attack time constant reaches approximately 99% in 300 ms,
    // close to classic VU-meter rise behavior. Match Desktop's 220 ms release.
    private let attackTimeConstant = 0.065
    private let releaseTimeConstant = 0.22

    func reset(to newValue: Double = 0) {
        value = max(0, min(1.0, newValue))
        lastUpdate = nil
    }
    
    @discardableResult
    func update(target: Double, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Double {
        guard now.isFinite else { return value }
        let dt = min(max(lastUpdate.map { now - $0 } ?? (1 / MeterVisualizationTiming.refreshRate),
                         1.0 / 240.0), 0.1)
        lastUpdate = now

        let clampedTarget = max(0, min(1.0, target.isFinite ? target : 0))
        let diff = clampedTarget - value
        let timeConstant = diff >= 0 ? attackTimeConstant : releaseTimeConstant
        let response = 1 - exp(-dt / timeConstant)
        value = max(0, min(1.0, value + diff * response))
        return value
    }
}
