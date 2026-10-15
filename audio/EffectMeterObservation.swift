import Foundation
import os
import os.lock

/// Timestamps describe the rendered PCM window, never its delayed delivery.
nonisolated struct EffectMeterObservation: Sendable {
    let peakDBFS: Float
    let rmsDBFS: Float
    let renderedAt: TimeInterval
    let duration: TimeInterval

    static let empty = Self(peakDBFS: -120, rmsDBFS: -120, renderedAt: -.infinity, duration: 0)
    static let maximumAge: TimeInterval = 0.250
    static let alignmentTolerance: TimeInterval = 0.0001

    func isUsable(now: TimeInterval, validSince: TimeInterval) -> Bool {
        peakDBFS.isFinite && rmsDBFS.isFinite && renderedAt.isFinite
            && duration.isFinite && duration > 0 && duration <= Self.maximumAge
            && now.isFinite && validSince.isFinite && renderedAt >= validSince
            && renderedAt + duration <= now + 0.020
            && now - renderedAt <= Self.maximumAge
    }

    func matches(_ other: Self, now: TimeInterval, validSince: TimeInterval) -> Bool {
        isUsable(now: now, validSince: validSince)
            && other.isUsable(now: now, validSince: validSince)
            && abs(renderedAt - other.renderedAt) <= Self.alignmentTolerance
            && abs(duration - other.duration) <= Self.alignmentTolerance
    }
}

nonisolated protocol MeterLevelStore: Sendable {
    var count: Int { get }
    func snapshot() -> [EffectMeterObservation]
    func snapshotIfAvailable() -> [EffectMeterObservation]?
    func tryUpdate(index: Int, levels: EffectMeterObservation)
    func clear()
}

nonisolated final class LegacyMeterLevelStore: MeterLevelStore, @unchecked Sendable {
    let count: Int
    private var levels: [EffectMeterObservation]
    private var lock = os_unfair_lock_s()

    init(count: Int) {
        self.count = count
        self.levels = Array(repeating: .empty, count: count)
    }

    func snapshot() -> [EffectMeterObservation] {
        os_unfair_lock_lock(&lock)
        let snapshot = levels
        os_unfair_lock_unlock(&lock)
        return snapshot
    }

    func snapshotIfAvailable() -> [EffectMeterObservation]? {
        guard os_unfair_lock_trylock(&lock) else { return nil }
        let snapshot = levels
        os_unfair_lock_unlock(&lock)
        return snapshot
    }

    func tryUpdate(index: Int, levels: EffectMeterObservation) {
        guard os_unfair_lock_trylock(&lock) else { return }
        if index >= 0, index < self.levels.count {
            if levels.renderedAt >= self.levels[index].renderedAt { self.levels[index] = levels }
        }
        os_unfair_lock_unlock(&lock)
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        for index in levels.indices {
            levels[index] = .empty
        }
        os_unfair_lock_unlock(&lock)
    }
}

@available(iOS 16.0, *)
nonisolated final class ModernMeterLevelStore: MeterLevelStore, @unchecked Sendable {
    let count: Int
    private let lock: OSAllocatedUnfairLock<[EffectMeterObservation]>

    init(count: Int) {
        self.count = count
        self.lock = OSAllocatedUnfairLock(initialState: Array(repeating: .empty, count: count))
    }

    func snapshot() -> [EffectMeterObservation] {
        lock.withLock { $0 }
    }

    func snapshotIfAvailable() -> [EffectMeterObservation]? {
        lock.withLockIfAvailable { $0 }
    }

    func tryUpdate(index: Int, levels: EffectMeterObservation) {
        _ = lock.withLockIfAvailable { storedLevels in
            if index >= 0, index < storedLevels.count {
                if levels.renderedAt >= storedLevels[index].renderedAt { storedLevels[index] = levels }
            }
        }
    }

    func clear() {
        lock.withLock { storedLevels in
            for index in storedLevels.indices {
                storedLevels[index] = .empty
            }
        }
    }
}

