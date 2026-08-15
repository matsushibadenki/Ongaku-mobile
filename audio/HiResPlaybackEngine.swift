//
//  HiResPlaybackEngine.swift
//  audio
//
//  EN: High-Resolution Audio Playback Engine with Asymmetrical Apodizing Sinc Upsampling.
//  JA: ハイレゾ音声再生エンジン — 高精度EQ 15バンド + Boseシミュレーション + アポダイジング・アップサンプリング
//  2026/04/04.
//

@preconcurrency import AVFoundation
import Accelerate
import AudioToolbox
import Darwin
import Foundation
import os
import os.lock

nonisolated private func availableAudioProcessMemoryBytes() -> UInt64 {
#if os(iOS)
    return UInt64(os_proc_available_memory())
#else
    return 0
#endif
}

nonisolated private func currentAudioProcessFootprintBytes() -> UInt64 {
#if os(iOS)
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(
                mach_task_self_,
                task_flavor_t(TASK_VM_INFO),
                rebound,
                &count
            )
        }
    }
    return result == KERN_SUCCESS ? UInt64(info.phys_footprint) : 0
#else
    return 0
#endif
}

nonisolated func amplitudeToDBFS(_ amplitude: Float) -> Float {
    guard amplitude > 0 else { return -120 }
    return max(-120, 20 * log10(amplitude))
}

private struct BiquadFilter {
    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    nonisolated init(b0: Float, b1: Float, b2: Float, a0: Float, a1: Float, a2: Float) {
        self.b0 = b0 / a0
        self.b1 = b1 / a0
        self.b2 = b2 / a0
        self.a1 = a1 / a0
        self.a2 = a2 / a0
    }

    nonisolated mutating func process(_ input: Float) -> Float {
        let output = (b0 * input) + (b1 * x1) + (b2 * x2) - (a1 * y1) - (a2 * y2)
        x2 = x1
        x1 = input
        y2 = y1
        y1 = output
        return output
    }

    nonisolated static func peaking(sampleRate: Double, frequency: Double, q: Double, gainDB: Double) -> BiquadFilter {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2.0 * q)
        let a = pow(10.0, gainDB / 40.0)
        let cosOmega = cos(omega)

        let b0 = 1.0 + alpha * a
        let b1 = -2.0 * cosOmega
        let b2 = 1.0 - alpha * a
        let a0 = 1.0 + alpha / a
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha / a

        return BiquadFilter(
            b0: Float(b0),
            b1: Float(b1),
            b2: Float(b2),
            a0: Float(a0),
            a1: Float(a1),
            a2: Float(a2)
        )
    }

    nonisolated static func allPass(sampleRate: Double, frequency: Double, q: Double) -> BiquadFilter {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let alpha = sin(omega) / (2.0 * q)
        let cosOmega = cos(omega)
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosOmega
        let a2 = 1.0 - alpha
        let b0 = a2
        let b1 = a1
        let b2 = a0

        return BiquadFilter(
            b0: Float(b0),
            b1: Float(b1),
            b2: Float(b2),
            a0: Float(a0),
            a1: Float(a1),
            a2: Float(a2)
        )
    }

    nonisolated static func highShelf(sampleRate: Double, frequency: Double, slope: Double, gainDB: Double) -> BiquadFilter {
        let omega = 2.0 * Double.pi * frequency / sampleRate
        let a = pow(10.0, gainDB / 40.0)
        let cosOmega = cos(omega)
        let sinOmega = sin(omega)
        let beta = sqrt(a) / slope

        let b0 = a * ((a + 1.0) + (a - 1.0) * cosOmega + 2.0 * beta * sinOmega)
        let b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cosOmega)
        let b2 = a * ((a + 1.0) + (a - 1.0) * cosOmega - 2.0 * beta * sinOmega)
        let a0 = (a + 1.0) - (a - 1.0) * cosOmega + 2.0 * beta * sinOmega
        let a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cosOmega)
        let a2 = (a + 1.0) - (a - 1.0) * cosOmega - 2.0 * beta * sinOmega

        return BiquadFilter(
            b0: Float(b0),
            b1: Float(b1),
            b2: Float(b2),
            a0: Float(a0),
            a1: Float(a1),
            a2: Float(a2)
        )
    }
}

private protocol MeterLevelStore: Sendable {
    var count: Int { get }
    func snapshot() -> [(peakDBFS: Float, rmsDBFS: Float)]
    func snapshotIfAvailable() -> [(peakDBFS: Float, rmsDBFS: Float)]?
    func tryUpdate(index: Int, levels: (peakDBFS: Float, rmsDBFS: Float))
    func clear()
}

private final class LegacyMeterLevelStore: MeterLevelStore, @unchecked Sendable {
    let count: Int
    private var levels: [(peakDBFS: Float, rmsDBFS: Float)]
    private var lock = os_unfair_lock_s()

    init(count: Int) {
        self.count = count
        self.levels = Array(repeating: (-120, -120), count: count)
    }

    func snapshot() -> [(peakDBFS: Float, rmsDBFS: Float)] {
        os_unfair_lock_lock(&lock)
        let snapshot = levels
        os_unfair_lock_unlock(&lock)
        return snapshot
    }

    func snapshotIfAvailable() -> [(peakDBFS: Float, rmsDBFS: Float)]? {
        guard os_unfair_lock_trylock(&lock) else { return nil }
        let snapshot = levels
        os_unfair_lock_unlock(&lock)
        return snapshot
    }

    func tryUpdate(index: Int, levels: (peakDBFS: Float, rmsDBFS: Float)) {
        guard os_unfair_lock_trylock(&lock) else { return }
        if index >= 0, index < self.levels.count {
            self.levels[index] = levels
        }
        os_unfair_lock_unlock(&lock)
    }

    func clear() {
        os_unfair_lock_lock(&lock)
        for index in levels.indices {
            levels[index] = (-120, -120)
        }
        os_unfair_lock_unlock(&lock)
    }
}

@available(iOS 16.0, *)
private final class ModernMeterLevelStore: MeterLevelStore, @unchecked Sendable {
    let count: Int
    private let lock: OSAllocatedUnfairLock<[(peakDBFS: Float, rmsDBFS: Float)]>

    init(count: Int) {
        self.count = count
        self.lock = OSAllocatedUnfairLock(initialState: Array(repeating: (-120, -120), count: count))
    }

    func snapshot() -> [(peakDBFS: Float, rmsDBFS: Float)] {
        lock.withLock { $0 }
    }

    func snapshotIfAvailable() -> [(peakDBFS: Float, rmsDBFS: Float)]? {
        lock.withLockIfAvailable { $0 }
    }

    func tryUpdate(index: Int, levels: (peakDBFS: Float, rmsDBFS: Float)) {
        _ = lock.withLockIfAvailable { storedLevels in
            if index >= 0, index < storedLevels.count {
                storedLevels[index] = levels
            }
        }
    }

    func clear() {
        lock.withLock { storedLevels in
            for index in storedLevels.indices {
                storedLevels[index] = (-120, -120)
            }
        }
    }
}

/// A non-blocking gate shared with audio-tap callbacks. Visual analysis is
/// useful only while the app is visible; keeping FFT, true-peak estimation,
/// and every effect meter active in the background wastes the audio render
/// budget and can eventually make iOS terminate the process.
nonisolated private final class RealtimeAnalysisGate: @unchecked Sendable {
    private var isEnabled = true
    private var lock = os_unfair_lock_s()

    func enabledIfAvailable() -> Bool {
        guard os_unfair_lock_trylock(&lock) else { return false }
        let result = isEnabled
        os_unfair_lock_unlock(&lock)
        return result
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        os_unfair_lock_lock(&lock)
        let changed = isEnabled != enabled
        isEnabled = enabled
        os_unfair_lock_unlock(&lock)
        return changed
    }
}

struct SignalLevelDiagnostics: Equatable {
    let sourcePeakDBFS: Float
    let sourceRMSDBFS: Float
    let sourceIntegratedLoudnessLUFS: Float
    let recommendedInputTrimDB: Float
    let inputHeadroomDB: Float
    let outputTrimDB: Float
    let fxHeadroomDB: Float

    var summary: String {
        L10n.tr(
            "effects.signal.summary",
            sourcePeakDBFS,
            sourceRMSDBFS,
            sourceIntegratedLoudnessLUFS,
            recommendedInputTrimDB,
            inputHeadroomDB,
            outputTrimDB,
            fxHeadroomDB
        )
    }
}

struct AutomaticDSPStatus: Equatable, Sendable {
    let lowShelfGainDB: Float
    let lowMidGainDB: Float
    let presenceGainDB: Float
    let highShelfGainDB: Float
    let strength: Float
    let cacheHit: Bool
    let cacheHits: Int
    let cacheMisses: Int
}

nonisolated struct PreparedAudioCacheStatistics: Equatable, Sendable {
    let byteCount: UInt64
    let entryCount: Int
    let maximumByteCount: UInt64

    static let empty = PreparedAudioCacheStatistics(
        byteCount: 0,
        entryCount: 0,
        maximumByteCount: 0
    )
}

nonisolated enum AudioMemorySafetyMode: Sendable, Equatable {
    case normal
    case reduced
    case constrained

    static var deviceDefault: AudioMemorySafetyMode {
        let physicalMemory = ProcessInfo.processInfo.physicalMemory
        let availableMemory = availableAudioProcessMemoryBytes()
        if availableMemory > 0 {
            if availableMemory <= 512 * 1_024 * 1_024 { return .constrained }
            if availableMemory <= 1_024 * 1_024 * 1_024 { return .reduced }
        }
        if physicalMemory <= 3 * 1_024 * 1_024 * 1_024 { return .constrained }
        if physicalMemory <= 4 * 1_024 * 1_024 * 1_024 { return .reduced }
        return .normal
    }

    var disablesHeavyDSP: Bool { self != .normal }

    /// Selects the only two supported runtime upsampling paths from the
    /// device's current memory safety state. The other UpsamplingMode cases
    /// remain available for the existing implementations and future work,
    /// but are intentionally not user-selectable.
    var automaticUpsamplingMode: UpsamplingMode {
        switch self {
        case .normal: return .precisionSincApodizingEco
        case .reduced, .constrained: return .avAudioConverter
        }
    }

    // Kept as a compatibility boundary for existing callers. The requested
    // value is ignored so persisted legacy preferences cannot override the
    // automatic memory-based decision.
    func safeUpsamplingMode(_ requested: UpsamplingMode) -> UpsamplingMode {
        automaticUpsamplingMode
    }

    func safeEffectSettings(_ settings: [RealtimeAudioEffectSetting]) -> [RealtimeAudioEffectSetting] {
        let disabledKinds: Set<RealtimeAudioEffectKind>
        switch self {
        case .normal: disabledKinds = []
        case .reduced: disabledKinds = [.simulation, .space, .warm, .bbe]
        case .constrained: disabledKinds = [.simulation, .space, .warm, .bbe, .body, .gloss]
        }
        return settings.map { setting in
            guard disabledKinds.contains(setting.kind) else { return setting }
            var reduced = setting
            reduced.isEnabled = false
            return reduced
        }
    }

    func safeSpatialSettings(_ settings: HeadphoneSpatialSettings) -> HeadphoneSpatialSettings {
        guard self != .normal else { return settings }
        var reduced = settings
        reduced.isEnabled = false
        return reduced
    }
}

/// Separates the user-visible automatic quality target from the mechanism
/// used to make the first audible samples available.
nonisolated enum PlaybackLoadStrategy: Sendable, Equatable {
    case immediateStreaming
    case preparedAutomaticQuality
    case preparedAVAudioConverter
}

struct EffectLevelAudit: Equatable {
    let kind: RealtimeAudioEffectKind
    let isEnabled: Bool
    let inputPeakDBFS: Float
    let inputRMSDBFS: Float
    let outputPeakDBFS: Float
    let outputRMSDBFS: Float
    
    var peakDeltaDB: Float { outputPeakDBFS - inputPeakDBFS }
    var rmsDeltaDB: Float { outputRMSDBFS - inputRMSDBFS }
}

struct HiResPlaybackFormat: Equatable {
    let sampleRate: Double
    let bitDepth: UInt32
    let channels: AVAudioChannelCount
    let sourceSampleRate: Double
    let sourceBitDepth: UInt32

    var isHiRes: Bool {
        sampleRate >= 88_200 || bitDepth >= 24
    }

    var isUpconverted: Bool {
        sampleRate > sourceSampleRate
    }

    var description: String {
        let rateText: String
        if sampleRate >= 1000 {
            rateText = String(format: "%.1f kHz", sampleRate / 1000)
        } else {
            rateText = String(format: "%.0f Hz", sampleRate)
        }
        return "\(rateText) / \(bitDepth)bit"
    }
}

private enum LoudnessCompensationRouteProfile: Sendable {
    case speaker
    case headphone
    case bluetooth
    case airPlay
}

private enum HiResEngineError: LocalizedError, Sendable {
    case sourceBufferFailed
    case upconvertBufferFailed
    case upconvertFailed
    case offlineBufferTooLarge
    
    @MainActor
    var errorDescription: String? {
        switch self {
        case .sourceBufferFailed: return L10n.tr("error.source_buffer_failed")
        case .upconvertBufferFailed: return L10n.tr("error.upconvert_buffer_failed")
        case .upconvertFailed: return L10n.tr("error.upconvert_failed")
        case .offlineBufferTooLarge: return L10n.tr("error.offline_buffer_too_large")
        }
    }
}

@MainActor
final class HiResPlaybackEngine {
    nonisolated private struct PreparedPlaybackData {
        let url: URL
        let audioFile: AVAudioFile
        let baseBuffer: AVAudioPCMBuffer
        let playbackBuffer: AVAudioPCMBuffer
        let targetFormat: AVAudioFormat
        let formatDescription: HiResPlaybackFormat
        let upsamplingMode: UpsamplingMode
        let diagnostics: SignalLevelDiagnostics
        let automaticDSPProfile: AutomaticDSPProfile
        let analysisCacheHit: Bool
        let duration: TimeInterval
    }

    nonisolated private struct PreparedAudioDiskCacheMetadata: Codable, Sendable {
        let version: Int
        let sourceIdentity: String
        let sourceFileSize: UInt64
        let sourceModificationTime: Int64
        let upsamplingModeRaw: String
        let spatialProcessingApplied: Bool
        let playbackSharesBase: Bool
        let targetSampleRate: Double
        let targetChannelCount: UInt32
        let sourceSampleRate: Double
        let sourceBitDepth: UInt32
        let outputBitDepth: UInt32
        let sourcePeakDBFS: Float
        let sourceRMSDBFS: Float
        let sourceIntegratedLoudnessLUFS: Float
        let recommendedInputTrimDB: Float
        let inputHeadroomDB: Float
        let outputTrimDB: Float
        let fxHeadroomDB: Float
        let lowShelfGainDB: Float
        let lowMidGainDB: Float
        let presenceGainDB: Float
        let highShelfGainDB: Float
    }

    nonisolated private struct PreparedAudioDiskCachePaths: Sendable {
        let metadata: URL
        let baseAudio: URL
        let playbackAudio: URL
    }

    fileprivate struct AutomaticDSPProfile: Equatable, Sendable {
        let lowShelfGainDB: Float
        let lowMidGainDB: Float
        let presenceGainDB: Float
        let highShelfGainDB: Float

        nonisolated static let neutral = AutomaticDSPProfile(
            lowShelfGainDB: 0,
            lowMidGainDB: 0,
            presenceGainDB: 0,
            highShelfGainDB: 0
        )

        var shouldBypass: Bool {
            max(abs(lowShelfGainDB), abs(lowMidGainDB), abs(presenceGainDB), abs(highShelfGainDB)) < 0.05
        }
    }

    var onPlaybackEnded: (() -> Void)?

    private let engine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private let upgradePlayerNode = AVAudioPlayerNode()
    private let sourceMixer = AVAudioMixerNode()
    private let declickMixer = AVAudioMixerNode()
    private let headphoneSpatialProcessingQueue = DispatchQueue(label: "audio.hires.headphoneSpatial", qos: .userInitiated)
    private let inputGainEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let loudnessCompensationEQ = AVAudioUnitEQ(numberOfBands: 4)
    private let automaticDSPEQ = AVAudioUnitEQ(numberOfBands: 4)

    private let effectPipeline = AudioEffectModuleRegistry.makePipeline()
    
    private let outputSafetyEQ = AVAudioUnitEQ(numberOfBands: 1)
    private let outputLimiter: AVAudioUnit?

    private(set) var currentAudioFile: AVAudioFile?
    private(set) var currentAudioURL: URL?
    private(set) var currentFormat: HiResPlaybackFormat?
    private(set) var signalDiagnostics: SignalLevelDiagnostics?
    private(set) var effectLevelAudits: [EffectLevelAudit] = []
    private(set) var duration: TimeInterval = 0
    private(set) var estimatedPipelineLatencyFrames: AVAudioFramePosition = 0
    private var baseConvertedBuffer: AVAudioPCMBuffer?
    private var convertedBuffer: AVAudioPCMBuffer?
    private var convertedFormat: AVAudioFormat?
    private var isFastFilePlayback = false
    private var configuredProcessingFormat: AVAudioFormat?
    private var isUpgradePlayerNodeActive = false

    private var activePlayerNode: AVAudioPlayerNode {
        isUpgradePlayerNodeActive ? upgradePlayerNode : playerNode
    }
    private var playbackOffset: TimeInterval = 0
    private var lastKnownPlaybackTime: TimeInterval = 0
    private var playbackStartedAt: Date?
    private var playbackGeneration: UInt64 = 0
    private var preparationGeneration: UInt64 = 0
    
    // 96 kHz is the highest stable format for the AVAudioEngine effect graph.
    // The source can still be 192 kHz; it is converted once into this processing rate.
    nonisolated private static let preferredSampleRate: Double = 96_000
    nonisolated private static let maxStableEffectSampleRate: Double = 96_000
    nonisolated private static let floatPipelineTargetRMSDBFS: Float = -18.0
    nonisolated private static let loudnessNormalizationTargetLUFS: Float = -16.0
    nonisolated private static let floatPipelinePeakCeilingDBFS: Float = -6.0
    nonisolated private static let finalOutputCeilingDBFS: Float = -1.0
    nonisolated private static let intersamplePeakReserveDB: Float = 1.0
    nonisolated private static let truePeakLimiterLookaheadOversampleFactor = 4
    nonisolated private static let maxInputBoostDB: Float = 6.0
    nonisolated private static let maxInputCutDB: Float = -12.0
    nonisolated private static let maxOfflinePlaybackBufferBytes: UInt64 = 768 * 1_024 * 1_024
    nonisolated private static let minimumProcessMemoryReserveBytes: UInt64 = 384 * 1_024 * 1_024
    nonisolated private static let maximumProcessMemoryReserveBytes: UInt64 = 768 * 1_024 * 1_024
    nonisolated static let proactiveMemoryPressureThresholdBytes: UInt64 = 512 * 1_024 * 1_024
    // Deliberately higher than the pressure threshold. This hysteresis avoids
    // repeatedly rebuilding and discarding a Precision Sinc buffer near the
    // memory boundary.
    nonisolated static let memoryRecoveryThresholdBytes: UInt64 = 1_280 * 1_024 * 1_024
    nonisolated private static let preparedAudioDiskCacheVersion = 2
    nonisolated private static let maxPreparedAudioDiskCacheBytes: UInt64 = 1_536 * 1_024 * 1_024
    nonisolated private static let preparedAudioDiskCacheLock = NSLock()
    nonisolated private static let preparedAudioDiskCacheMigrationLock = NSLock()
    nonisolated(unsafe) private static var didMigratePreparedAudioDiskCache = false
    nonisolated private static let preparedAudioDiskCacheTaskLock = NSLock()
    nonisolated(unsafe) private static var preparedAudioDiskCacheWriteTask: Task<Void, Never>?
    nonisolated(unsafe) private static var preparedAudioDiskCacheWriteGeneration: UInt64 = 0
    nonisolated(unsafe) private static var sincKernelCache: [SincKernelCacheKey: [Float]] = [:]
    nonisolated private static let sincKernelCacheLock = NSLock()
    nonisolated private static let analysisCacheLock = NSLock()
    nonisolated(unsafe) private static var analysisCache: [AnalysisCacheKey: AnalysisCacheValue] = [:]
    nonisolated(unsafe) private static var analysisCacheHits: Int = 0
    nonisolated(unsafe) private static var analysisCacheMisses: Int = 0

    private var tappedNodes: [AVAudioNode] = []
    private var meterLevels: MeterLevelStore
    private var smoothedMeasuredEffectBoostDB: Float = 0
    private var plannedOutputTrimDB: Float = 0
    private var lastAnyEffectEnabled: Bool = false
    private var declickToken: UInt64 = 0
    private var headphoneSpatialSettings = HeadphoneSpatialSettings.default
    private var memorySafetyMode = AudioMemorySafetyMode.deviceDefault
    private var currentUpsamplingMode: UpsamplingMode = .avAudioConverter
    private var headphoneSpatialUpdateToken: UInt64 = 0
    private var lastGainStagingDate = Date()
    private var lastAppliedEffectSettings: [RealtimeAudioEffectKind: RealtimeAudioEffectSetting] = [:]
    private var automaticDSPProfile = AutomaticDSPProfile.neutral
    private var automaticDSPStrength: Float = 1.0
    private var automaticDSPVoicing: AutomaticDSPVoicing = .natural
    private var observedSystemOutputVolume: Float = AVAudioSession.sharedInstance().outputVolume
    private var loudnessCompensationRouteProfile: LoudnessCompensationRouteProfile = .speaker
    private var lastAutomaticDSPCacheHit = false
    private var preloadedPlaybackCache: [PreloadedPlaybackKey: PreparedPlaybackData] = [:]
    private var preloadTasks: [PreloadedPlaybackKey: Task<Void, Never>] = [:]
    private var qualityUpgradeWorker: Task<PreparedPlaybackData, Error>?
    private var qualityUpgradeWorkerGeneration: UInt64 = 0
    
    nonisolated private let spectrumAnalyzer = SpectrumAnalyzer(n: 4096, bandCount: 144)
    nonisolated private let renderHealthMonitor = AudioRenderHealthMonitor()
    nonisolated private let realtimeAnalysisGate = RealtimeAnalysisGate()

    nonisolated var currentSpectrum: [Float] {
        spectrumAnalyzer.getSpectrum()
    }

    var isPlaying: Bool {
        activePlayerNode.isPlaying
    }

    var isEngineRunning: Bool {
        engine.isRunning
    }

    var hasTrack: Bool {
        convertedBuffer != nil || currentAudioFile != nil
    }

    var activeUpsamplingMode: UpsamplingMode {
        currentUpsamplingMode
    }

    nonisolated static var availableProcessMemoryBytes: UInt64 {
        availableAudioProcessMemoryBytes()
    }

    nonisolated static var processMemoryDiagnostic: String {
        let divisor = UInt64(1_024 * 1_024)
        return "footprintMB=\(currentAudioProcessFootprintBytes() / divisor) availableMB=\(availableAudioProcessMemoryBytes() / divisor)"
    }

    var automaticDSPStatus: AutomaticDSPStatus {
        let scaled = scaledAutomaticDSPProfile()
        let cacheStats = Self.analysisCacheStatsSnapshot()
        return AutomaticDSPStatus(
            lowShelfGainDB: scaled.lowShelfGainDB,
            lowMidGainDB: scaled.lowMidGainDB,
            presenceGainDB: scaled.presenceGainDB,
            highShelfGainDB: scaled.highShelfGainDB,
            strength: automaticDSPStrength,
            cacheHit: lastAutomaticDSPCacheHit,
            cacheHits: cacheStats.hits,
            cacheMisses: cacheStats.misses
        )
    }

    var finalOutputLevels: (peakDBFS: Float, rmsDBFS: Float, spectrum: [Float]) {
        ensureEffectLevelMetersInstalled()
        let snapshot = meterLevels.snapshot()
        let levels = snapshot.last ?? (-120, -120)
        return (levels.peakDBFS, levels.rmsDBFS, currentSpectrum)
    }

    /// Polls final-output render continuity and emits one diagnostic event per
    /// detected dropout and recovery. This does not modify playback behavior.
    func pollRenderHealth() -> AudioRenderHealthSnapshot {
        let result = renderHealthMonitor.poll(
            expectedToRender: isPlaying && engine.isRunning
        )
        let route = AVAudioSession.sharedInstance().currentRoute.outputs
            .map { $0.portType.rawValue }
            .joined(separator: ",")
        let enabledEffects = effectPipeline
            .filter(\.isEnabled)
            .map { $0.kind.rawValue }
            .joined(separator: ",")

        if let gap = result.detectedGapMilliseconds {
            let gapText = String(format: "%.1f", gap)
            let routeText = route.isEmpty ? "unknown" : route
            let effectsText = enabledEffects.isEmpty ? "none" : enabledEffects
            PlaybackDebugLogger.warning(
                "audio.dropout.detected gapMs=\(gapText) count=\(result.snapshot.dropoutCount) route=\(routeText) effects=\(effectsText)"
            )
        }
        if let recovery = result.recoveredAfterMilliseconds {
            let recoveryText = String(format: "%.1f", recovery)
            PlaybackDebugLogger.event(
                "audio.dropout.recovered durationMs=\(recoveryText) count=\(result.snapshot.dropoutCount)"
            )
        }
        return result.snapshot
    }

    func setSystemOutputVolume(_ value: Float) {
        let clamped = min(max(value, 0.0), 1.0)
        guard abs(clamped - observedSystemOutputVolume) >= 0.005 else { return }
        observedSystemOutputVolume = clamped
        applyLoudnessCompensation(for: clamped)
    }

    /// Suspends visualization-only work without touching the audio graph.
    /// Render-heartbeat monitoring remains active so background dropouts can
    /// still be diagnosed without paying for FFT and per-stage metering.
    func setRealtimeAnalysisEnabled(_ enabled: Bool) {
        guard realtimeAnalysisGate.setEnabled(enabled) else { return }
        if !enabled {
            meterLevels.clear()
            spectrumAnalyzer.reset()
        }
        PlaybackDebugLogger.event(
            "audio.analysis.\(enabled ? "enabled" : "suspended") \(Self.processMemoryDiagnostic)"
        )
    }

    /// Keeps callers that bypass the view model from re-enabling expensive DSP.
    func setMemorySafetyMode(_ mode: AudioMemorySafetyMode) {
        memorySafetyMode = mode
        if mode.disablesHeavyDSP {
            releasePreloadedResources()
            releaseBaseBufferForMemoryPressure()
        }
    }

    func refreshLoudnessCompensationRoute() {
        let nextProfile = Self.currentLoudnessCompensationRouteProfile()
        guard nextProfile != loudnessCompensationRouteProfile else { return }
        loudnessCompensationRouteProfile = nextProfile
        applyLoudnessCompensation(for: observedSystemOutputVolume)
    }

    init() {
        // Automatic-DSP output + every effect output + true main output.
        let meterCount = effectPipeline.count + 2
        if #available(iOS 16.0, *) {
            meterLevels = ModernMeterLevelStore(count: meterCount)
        } else {
            meterLevels = LegacyMeterLevelStore(count: meterCount)
        }
        outputLimiter = Self.makePeakLimiter()
        configureAudioEngine()
        loudnessCompensationRouteProfile = Self.currentLoudnessCompensationRouteProfile()
        applyLoudnessCompensation(for: observedSystemOutputVolume)
    }

    deinit {
        onPlaybackEnded = nil
    }

    // MARK: - Public API

    func load(
        url: URL,
        effectSettings: [RealtimeAudioEffectSetting],
        headphoneSpatialSettings: HeadphoneSpatialSettings? = nil,
        upsamplingMode: UpsamplingMode? = nil,
        skipDSPAnalysis: Bool = false,
        strategy: PlaybackLoadStrategy = .preparedAutomaticQuality
    ) async throws {
        stop()
        let generation = preparationGeneration
        let resolvedSpatialSettings = memorySafetyMode.safeSpatialSettings(headphoneSpatialSettings ?? .default)
        let resolvedUpsamplingMode: UpsamplingMode
        switch strategy {
        case .immediateStreaming, .preparedAVAudioConverter:
            resolvedUpsamplingMode = .avAudioConverter
        case .preparedAutomaticQuality:
            resolvedUpsamplingMode = memorySafetyMode.safeUpsamplingMode(
                upsamplingMode ?? .avAudioConverter
            )
        }
        let safeEffectSettings = memorySafetyMode.safeEffectSettings(effectSettings)

        if strategy == .immediateStreaming {
            try loadFastFile(
                url: url,
                effectSettings: safeEffectSettings,
                headphoneSpatialSettings: resolvedSpatialSettings
            )
            return
        }
        
        self.headphoneSpatialSettings = resolvedSpatialSettings
        currentUpsamplingMode = resolvedUpsamplingMode
        let preloadKey = Self.makePreloadedPlaybackKey(
            url: url,
            upsamplingMode: resolvedUpsamplingMode,
            spatialSettings: resolvedSpatialSettings
        )
        playbackOffset = 0

        if let prepared = await awaitPreloadedPlaybackData(for: preloadKey) {
            try Task.checkCancellation()
            guard preparationGeneration == generation else { throw CancellationError() }
            guard Self.preparedPlaybackData(prepared, matches: url) else {
                throw HiResEngineError.upconvertFailed
            }
            try applyPreparedPlaybackData(prepared, effectSettings: safeEffectSettings)
        } else {
            let prepared = try await Self.preparePlaybackDataInWorker(
                url: url,
                headphoneSpatialSettings: resolvedSpatialSettings,
                upsamplingMode: resolvedUpsamplingMode,
                skipDSPAnalysis: skipDSPAnalysis,
                priority: .userInitiated
            )
            try Task.checkCancellation()
            guard preparationGeneration == generation else { throw CancellationError() }
            guard Self.preparedPlaybackData(prepared, matches: url) else {
                throw HiResEngineError.upconvertFailed
            }
            try applyPreparedPlaybackData(prepared, effectSettings: safeEffectSettings)
        }
    }

    /// Starts the source file directly. This avoids decoding the entire song
    /// before the user hears anything; the offline high-quality buffer is
    /// prepared separately by the background upgrade task.
    private func loadFastFile(
        url: URL,
        effectSettings: [RealtimeAudioEffectSetting],
        headphoneSpatialSettings: HeadphoneSpatialSettings
    ) throws {
        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        guard sourceFormat.sampleRate > 0, sourceFormat.channelCount > 0 else {
            throw HiResEngineError.sourceBufferFailed
        }

        let processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.resolvedProcessingSampleRate(for: sourceFormat.sampleRate),
            channels: max(AVAudioChannelCount(2), sourceFormat.channelCount),
            interleaved: false
        )!

        currentAudioFile = audioFile
        currentAudioURL = url
        let encodedBitDepth = audioFile.fileFormat.streamDescription.pointee.mBitsPerChannel
        currentFormat = HiResPlaybackFormat(
            // The player badge describes the active processing graph. Keep the
            // original file format in sourceSampleRate/sourceBitDepth instead.
            sampleRate: processingFormat.sampleRate,
            bitDepth: max(encodedBitDepth, 24),
            channels: processingFormat.channelCount,
            sourceSampleRate: sourceFormat.sampleRate,
            sourceBitDepth: encodedBitDepth == 0 ? 32 : encodedBitDepth
        )
        duration = Double(audioFile.length) / sourceFormat.sampleRate
        isFastFilePlayback = true
        self.headphoneSpatialSettings = headphoneSpatialSettings
        signalDiagnostics = nil
        automaticDSPProfile = .neutral
        currentUpsamplingMode = .avAudioConverter

        try configureAudioSession(preferredSampleRate: processingFormat.sampleRate)
        configureProcessingFormat(processingFormat)
        assert(abs((currentFormat?.sampleRate ?? 0) - processingFormat.sampleRate) < 0.1)
        apply(effectSettings: effectSettings)
        try ensureEngineRunning()
        scheduleBuffer(from: 0, autoplay: false)
    }

    func play() throws {
        ensureEffectLevelMetersInstalled()
        try ensureEngineRunning()
        scheduleBuffer(from: playbackOffset, autoplay: true)
    }

    func pause() {
        playbackOffset = currentTime()
        playbackStartedAt = nil
        playbackGeneration &+= 1
        renderHealthMonitor.endMonitoring()
        activePlayerNode.pause()
        engine.pause()
    }

    func stop() {
        preparationGeneration &+= 1
        playbackGeneration &+= 1
        headphoneSpatialUpdateToken &+= 1
        renderHealthMonitor.endMonitoring()
        playerNode.stop()
        upgradePlayerNode.stop()
        spectrumAnalyzer.reset()
        playerNode.volume = 1.0
        upgradePlayerNode.volume = 0.0
        sourceMixer.outputVolume = 1.0
        inputGainEQ.globalGain = 0
        isUpgradePlayerNodeActive = false
        currentAudioFile = nil
        currentAudioURL = nil
        baseConvertedBuffer = nil
        convertedBuffer = nil
        convertedFormat = nil
        isFastFilePlayback = false
        currentFormat = nil
        signalDiagnostics = nil
        automaticDSPProfile = .neutral
        lastAutomaticDSPCacheHit = false
        currentUpsamplingMode = .avAudioConverter
        applyAutomaticDSPProfile(.neutral)
        duration = 0
        estimatedPipelineLatencyFrames = 0
        playbackOffset = 0
        lastKnownPlaybackTime = 0
        playbackStartedAt = nil
        clearEffectLevelMeters()
        effectLevelAudits = []
        smoothedMeasuredEffectBoostDB = 0
        plannedOutputTrimDB = 0
        applyOutputSafetyGain()
        lastAnyEffectEnabled = false
        lastAppliedEffectSettings.removeAll(keepingCapacity: true)
        declickToken &+= 1
    }

    func releasePreloadedResources() {
        cancelPreloading()
        Self.cancelPreparedAudioDiskCacheWrite()
        preloadedPlaybackCache.removeAll(keepingCapacity: false)
        Self.clearAnalysisCache()
        Self.clearSincKernelCache()
    }

    /// Cancels work that is not required by the currently audible track.
    /// The active file/buffer remains valid.
    func cancelBackgroundPreparation() {
        cancelPreloading()
        qualityUpgradeWorker?.cancel()
        qualityUpgradeWorker = nil
        qualityUpgradeWorkerGeneration &+= 1
        Self.cancelPreparedAudioDiskCacheWrite()
        preloadedPlaybackCache.removeAll(keepingCapacity: false)
    }

    /// Stops only background preparation. The currently playing buffer is left
    /// untouched so this is safe to call immediately before a quality upgrade.
    func cancelPreloading() {
        for task in preloadTasks.values {
            task.cancel()
        }
        preloadTasks.removeAll(keepingCapacity: false)
    }

    func releaseBaseBufferForMemoryPressure() {
        // The playback copy is required for the current track; the base copy is
        // only needed to rebuild spatial processing and can be discarded safely.
        baseConvertedBuffer = nil
        Self.clearAnalysisCache()
        Self.clearSincKernelCache()
    }

    nonisolated static func preparedAudioCacheStatistics() async -> PreparedAudioCacheStatistics {
        await Task.detached(priority: .utility) {
            Self.readPreparedAudioCacheStatistics()
        }.value
    }

    nonisolated static func clearPreparedAudioDiskCache() async {
        Self.cancelPreparedAudioDiskCacheWrite()
        await Task.detached(priority: .utility) {
            Self.removePreparedAudioDiskCache()
        }.value
    }

    func updateHeadphoneSpatialSettings(
        _ settings: HeadphoneSpatialSettings,
        effectSettings: [RealtimeAudioEffectSetting],
        completion: @escaping (Error?) -> Void
    ) {
        let safeSettings = memorySafetyMode.safeSpatialSettings(settings)
        let safeEffectSettings = memorySafetyMode.safeEffectSettings(effectSettings)
        guard let baseConvertedBuffer, let convertedFormat else {
            headphoneSpatialSettings = safeSettings
            completion(nil)
            return
        }

        headphoneSpatialUpdateToken &+= 1
        let token = headphoneSpatialUpdateToken
        let baseBuffer = baseConvertedBuffer
        let cachedURL = currentAudioURL
        let cachedUpsamplingMode = currentUpsamplingMode
        let needsSpatialProcessingCopy = safeSettings.isEnabled
            && Self.shouldApplyHeadphoneVirtualization
            && convertedFormat.channelCount >= 2
        guard !needsSpatialProcessingCopy || Self.canAllocatePlaybackCopy(of: baseBuffer) else {
            completion(HiResEngineError.offlineBufferTooLarge)
            return
        }

        headphoneSpatialProcessingQueue.async { [weak self] in
            guard let self else { return }
            
            do {
                let rebuiltBuffer: AVAudioPCMBuffer
                if needsSpatialProcessingCopy {
                    rebuiltBuffer = try Self.clonePlaybackBuffer(from: baseBuffer)
                    Self.applyHeadphoneVirtualizationIfNeeded(to: rebuiltBuffer, settings: safeSettings)
                } else {
                    // Disabling virtualization can return to the immutable base
                    // allocation directly; a second full-song copy is needless.
                    rebuiltBuffer = baseBuffer
                }
                let cacheKey = Self.makeAnalysisCacheKey(
                    url: cachedURL,
                    targetSampleRate: convertedFormat.sampleRate,
                    upsamplingMode: cachedUpsamplingMode,
                    spatialSettings: safeSettings
                )
                let diagnostics: SignalLevelDiagnostics
                let automaticDSPProfile: AutomaticDSPProfile
                let cacheHit: Bool
                if let cached = Self.cachedAnalysis(for: cacheKey) {
                    diagnostics = cached.diagnostics
                    automaticDSPProfile = cached.automaticDSPProfile
                    cacheHit = true
                } else {
                    diagnostics = Self.analyzeSignalLevels(in: rebuiltBuffer)
                    automaticDSPProfile = Self.analyzeAutomaticDSP(in: rebuiltBuffer, diagnostics: diagnostics)
                    Self.storeCachedAnalysis(.init(diagnostics: diagnostics, automaticDSPProfile: automaticDSPProfile), for: cacheKey)
                    cacheHit = false
                }

                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.headphoneSpatialUpdateToken == token else {
                        completion(nil)
                        return
                    }

                    self.headphoneSpatialSettings = safeSettings
                    self.convertedBuffer = rebuiltBuffer
                    self.signalDiagnostics = diagnostics
                    self.automaticDSPProfile = automaticDSPProfile
                    self.lastAutomaticDSPCacheHit = cacheHit
                    self.applyAutomaticDSPProfile(automaticDSPProfile)
                    self.duration = Double(rebuiltBuffer.frameLength) / convertedFormat.sampleRate

                    do {
                        let latestResumeTime = self.currentTime()
                        let shouldResume = self.isPlaying
                        self.apply(effectSettings: safeEffectSettings)
                        try self.ensureEngineRunning()
                        self.scheduleBuffer(from: min(latestResumeTime, self.duration), autoplay: shouldResume)
                        completion(nil)
                    } catch {
                        completion(error)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    completion(error)
                }
            }
        }
    }

    func reloadCurrentTrack(
        url: URL,
        effectSettings: [RealtimeAudioEffectSetting],
        headphoneSpatialSettings: HeadphoneSpatialSettings,
        upsamplingMode: UpsamplingMode,
        resumeTime: TimeInterval,
        shouldResume: Bool
    ) async throws {
        preparationGeneration &+= 1
        let generation = preparationGeneration
        await fadeOutOutput(duration: 0.100)
        try? await Task.sleep(nanoseconds: 100 * 1_000_000)
        
        let preloadKey = Self.makePreloadedPlaybackKey(
            url: url,
            upsamplingMode: upsamplingMode,
            spatialSettings: headphoneSpatialSettings
        )
        let prepared: PreparedPlaybackData
        if let cachedPrepared = await awaitPreloadedPlaybackData(for: preloadKey) {
            prepared = cachedPrepared
        } else {
            prepared = try await Self.preparePlaybackDataInWorker(
                url: url,
                headphoneSpatialSettings: headphoneSpatialSettings,
                upsamplingMode: upsamplingMode,
                priority: .userInitiated
            )
        }

        try Task.checkCancellation()
        guard preparationGeneration == generation else { throw CancellationError() }
        guard Self.preparedPlaybackData(prepared, matches: url) else {
            throw HiResEngineError.upconvertFailed
        }

        try await MainActor.run {
            try self.applyPreparedPlaybackData(prepared, effectSettings: effectSettings)
            if resumeTime > 0 {
                try self.seek(to: resumeTime)
            }
            if shouldResume {
                try self.play()
            }
        }
        
        try? await Task.sleep(nanoseconds: 50 * 1_000_000)
        await fadeInOutput(duration: 0.200)
    }

    func seamlessUpgrade(
        url: URL,
        effectSettings: [RealtimeAudioEffectSetting],
        headphoneSpatialSettings: HeadphoneSpatialSettings,
        upsamplingMode: UpsamplingMode,
        shouldResume: Bool,
        onHandoffReady: (() -> Void)? = nil
    ) async throws {
        preparationGeneration &+= 1
        let generation = preparationGeneration
        // Background prepare
        let preloadKey = Self.makePreloadedPlaybackKey(
            url: url,
            upsamplingMode: upsamplingMode,
            spatialSettings: headphoneSpatialSettings
        )
        let prepared: PreparedPlaybackData
        if let cachedPrepared = await awaitPreloadedPlaybackData(for: preloadKey) {
            prepared = cachedPrepared
        } else {
            qualityUpgradeWorker?.cancel()
            qualityUpgradeWorkerGeneration &+= 1
            let workerGeneration = qualityUpgradeWorkerGeneration
            let workerStartedAt = CFAbsoluteTimeGetCurrent()
            let worker = Task.detached(priority: .background) {
                defer {
                    let elapsed = CFAbsoluteTimeGetCurrent() - workerStartedAt
                    PlaybackDebugLogger.event(
                        "audio.quality_worker.ended generation=\(workerGeneration) cancelled=\(Task.isCancelled) elapsed=\(String(format: "%.2f", elapsed)) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) \(Self.processMemoryDiagnostic)"
                    )
                }
                return try Self.preparePlaybackData(
                    url: url,
                    headphoneSpatialSettings: headphoneSpatialSettings,
                    upsamplingMode: upsamplingMode
                )
            }
            qualityUpgradeWorker = worker
            defer {
                if qualityUpgradeWorkerGeneration == workerGeneration {
                    qualityUpgradeWorker = nil
                }
            }
            prepared = try await withTaskCancellationHandler {
                try await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
        
        try Task.checkCancellation()
        guard preparationGeneration == generation else { throw CancellationError() }
        guard Self.preparedPlaybackData(prepared, matches: url) else {
            throw HiResEngineError.upconvertFailed
        }

        // Preparation succeeded. Only now is it valid to tell the UI that the
        // audible handoff is about to begin. If preparation throws above, the
        // current normal stream remains untouched.
        onHandoffReady?()

        // Sample the position while the normal file is still playing. Do not
        // fade to silence here: the old implementation intentionally muted
        // the output during engine reconfiguration, which sounded like a stop
        // before the high-quality buffer resumed.
        let exactResumeTime = currentTime()
        let evaluationTime = Date()
        // Respect a pause performed while the background conversion was in
        // progress. A completed quality upgrade must never restart playback
        // against the user's latest transport intent.
        let shouldResumeAtHandoff = shouldResume && isPlaying
        
        do {
            try Task.checkCancellation()

            try await MainActor.run {
                try self.crossfadeToPreparedPlaybackData(
                    prepared,
                    effectSettings: effectSettings,
                    resumeTime: exactResumeTime,
                    evaluationTime: evaluationTime,
                    shouldResume: shouldResumeAtHandoff
                )
            }
        } catch {
            throw error
        }
    }

    func preloadTrack(
        url: URL,
        headphoneSpatialSettings: HeadphoneSpatialSettings,
        upsamplingMode: UpsamplingMode
    ) {
        let key = Self.makePreloadedPlaybackKey(
            url: url,
            upsamplingMode: upsamplingMode,
            spatialSettings: headphoneSpatialSettings
        )
        if preloadedPlaybackCache[key] != nil {
            cancelPreloading()
            preloadedPlaybackCache = preloadedPlaybackCache.filter { $0.key == key }
            return
        }

        // Only the immediate next track is useful. Keeping preparations for
        // stale queue positions can retain several complete 96 kHz PCM songs
        // and is especially dangerous while the current track is also cached.
        cancelPreloading()
        preloadedPlaybackCache.removeAll(keepingCapacity: true)

        let task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let prepared = try Self.preparePlaybackData(
                    url: url,
                    headphoneSpatialSettings: headphoneSpatialSettings,
                    upsamplingMode: upsamplingMode
                )
                await MainActor.run {
                    if self.preloadTasks[key] == nil { return }
                    self.preloadedPlaybackCache.removeAll(keepingCapacity: true)
                    self.preloadedPlaybackCache[key] = prepared
                    self.preloadTasks.removeValue(forKey: key)
                }
            } catch {
                _ = await MainActor.run {
                    self.preloadTasks.removeValue(forKey: key)
                }
            }
        }

        preloadTasks[key] = task
    }

    func setAutomaticDSPStrength(_ value: Float, effectSettings: [RealtimeAudioEffectSetting]) {
        let clamped = min(max(value, 0.0), 1.5)
        guard abs(clamped - automaticDSPStrength) >= 0.001 else { return }
        automaticDSPStrength = clamped
        applyAutomaticDSPProfile(automaticDSPProfile)
        applyGainStaging(effectSettings: effectSettings)
    }

    func setAutomaticDSPVoicing(_ voicing: AutomaticDSPVoicing) {
        automaticDSPVoicing = voicing
        applyAutomaticDSPProfile(automaticDSPProfile)
        if hasTrack {
            applyGainStaging(effectSettings: Array(lastAppliedEffectSettings.values))
        }
    }

    func seek(to time: TimeInterval) throws {
        let clamped = min(max(0, time), duration)
        let shouldResume = isPlaying
        playbackOffset = clamped
        lastKnownPlaybackTime = clamped
        try ensureEngineRunning()
        scheduleBuffer(from: clamped, autoplay: shouldResume)
    }

    func skip(by timeDelta: TimeInterval) throws {
        try seek(to: currentTime() + timeDelta)
    }

    func currentTime() -> TimeInterval {
        guard currentAudioFile != nil else { return 0 }
        let node = activePlayerNode
        guard node.isPlaying,
              let lastRenderTime = node.lastRenderTime,
              let playerTime = node.playerTime(forNodeTime: lastRenderTime) else {
            return min(duration, max(playbackOffset, lastKnownPlaybackTime))
        }
        let elapsed = Double(playerTime.sampleTime) / playerTime.sampleRate
        let resolvedTime = min(duration, playbackOffset + elapsed)
        lastKnownPlaybackTime = resolvedTime
        return resolvedTime
    }

    func refreshEffectLevelAudits() -> [EffectLevelAudit] {
        let snapshot: [(peakDBFS: Float, rmsDBFS: Float)]
        if let availableSnapshot = meterLevels.snapshotIfAvailable() {
            snapshot = availableSnapshot
        } else if !effectLevelAudits.isEmpty {
            return effectLevelAudits
        } else {
            snapshot = Array(repeating: (-120, -120), count: meterLevels.count)
        }
        
        var audits: [EffectLevelAudit] = []
        var previousIndex = 0
        for (index, effect) in effectPipeline.enumerated() {
            let currentIndex = index + 1
            let input = snapshot[previousIndex]
            let output = snapshot[currentIndex]
            audits.append(
                EffectLevelAudit(
                    kind: effect.kind,
                    isEnabled: effect.isEnabled,
                    inputPeakDBFS: input.peakDBFS,
                    inputRMSDBFS: input.rmsDBFS,
                    outputPeakDBFS: output.peakDBFS,
                    outputRMSDBFS: output.rmsDBFS
                )
            )
            previousIndex = currentIndex
        }
        effectLevelAudits = audits
        return audits
    }

    func maskTransitionNoiseIfNeeded(aggressive: Bool) {
        let silentHoldDuration: TimeInterval = aggressive ? 0.080 : 0.015
        
        Task {
            await fadeOutOutput(duration: aggressive ? 0.010 : 0.005)
            try? await Task.sleep(nanoseconds: UInt64(silentHoldDuration * 1_000_000_000))
            await fadeInOutput(duration: aggressive ? 0.080 : 0.040)
        }
    }

    func fadeOutOutput(duration: TimeInterval) async {
        declickToken &+= 1
        let token = declickToken
        await withCheckedContinuation { continuation in
            rampOutputVolume(to: 0.0, duration: duration, token: token) {
                continuation.resume()
            }
        }
    }

    func fadeInOutput(duration: TimeInterval) async {
        declickToken &+= 1
        let token = declickToken
        await withCheckedContinuation { continuation in
            rampOutputVolume(to: 1.0, duration: duration, token: token) {
                continuation.resume()
            }
        }
    }

    // MARK: - Effect Application

    func apply(effectSettings: [RealtimeAudioEffectSetting]) {
        let safeEffectSettings = memorySafetyMode.safeEffectSettings(effectSettings)
        let anyEnabledNow = safeEffectSettings.contains(where: { $0.isEnabled })
        let shouldDeclick = activePlayerNode.isPlaying && !lastAnyEffectEnabled && anyEnabledNow
        lastAnyEffectEnabled = anyEnabledNow

        if shouldDeclick {
            applyWithDeclick(effectSettings: safeEffectSettings)
            return
        }

        applyImmediate(effectSettings: safeEffectSettings)
    }

    private func applyImmediate(effectSettings: [RealtimeAudioEffectSetting]) {
        var anyChanged = false
        var seenKinds: Set<RealtimeAudioEffectKind> = []

        for setting in effectSettings {
            seenKinds.insert(setting.kind)
            if lastAppliedEffectSettings[setting.kind] == setting {
                continue
            }
            if let effect = effectPipeline.first(where: { $0.kind == setting.kind }) {
                effect.apply(setting: setting)
                anyChanged = true
            }
            lastAppliedEffectSettings[setting.kind] = setting
        }

        if !lastAppliedEffectSettings.isEmpty {
            let staleKinds = Set(lastAppliedEffectSettings.keys).subtracting(seenKinds)
            if !staleKinds.isEmpty {
                for staleKind in staleKinds {
                    if let effect = effectPipeline.first(where: { $0.kind == staleKind }) {
                        effect.apply(setting: RealtimeAudioEffectSetting(kind: staleKind, isEnabled: false))
                        anyChanged = true
                    }
                    lastAppliedEffectSettings.removeValue(forKey: staleKind)
                }
            }
        }

        if !anyChanged {
            return
        }
        
        applyGainStaging(effectSettings: effectSettings)
    }

    private func applyWithDeclick(effectSettings: [RealtimeAudioEffectSetting]) {
        declickToken &+= 1
        let token = declickToken
        let originalOutput = declickMixer.outputVolume
        rampOutputVolume(to: 0.0, duration: 0.020, token: token) { [weak self] in
            guard let self, self.declickToken == token else { return }

            self.applyImmediate(effectSettings: effectSettings)

            self.declickMixer.outputVolume = 0.0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.090) { [weak self] in
                guard let self, self.declickToken == token else { return }
                self.rampOutputVolume(to: max(0.0001, originalOutput), duration: 0.120, token: token, completion: nil)
            }
        }
    }

    private func rampOutputVolume(to target: Float, duration: TimeInterval, token: UInt64, completion: (() -> Void)?) {
        let startDeclick = declickMixer.outputVolume
        let startMain = engine.mainMixerNode.outputVolume
        
        let minLinear: Float = 0.0001
        let startDBDeclick = 20.0 * log10(max(minLinear, startDeclick))
        let startDBMain = 20.0 * log10(max(minLinear, startMain))
        let targetDB = 20.0 * log10(max(minLinear, target))
        
        let steps = max(8, Int(duration / 0.005))
        let stepDuration = duration / TimeInterval(steps)

        for step in 1...steps {
            let t = Float(step) / Float(steps)
            let valDBDeclick = startDBDeclick + (targetDB - startDBDeclick) * t
            let valDBMain = startDBMain + (targetDB - startDBMain) * t
            
            let valDeclick = target == 0 && step == steps ? 0 : pow(10.0, valDBDeclick / 20.0)
            let valMain = target == 0 && step == steps ? 0 : pow(10.0, valDBMain / 20.0)
            
            DispatchQueue.main.asyncAfter(deadline: .now() + stepDuration * TimeInterval(step)) { [weak self] in
                guard let self, self.declickToken == token else { return }
                self.declickMixer.outputVolume = valDeclick
                self.engine.mainMixerNode.outputVolume = valMain
                if step == steps { completion?() }
            }
        }
    }

    // MARK: - Private: Audio Session

    private func configureAudioSession(preferredSampleRate: Double) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [])
        try session.setPreferredSampleRate(preferredSampleRate)
        try session.setPreferredIOBufferDuration(0.01)
        try session.setActive(true)
    }

    nonisolated static func resolvedProcessingSampleRate(for sourceSampleRate: Double) -> Double {
        let upsampled = max(sourceSampleRate, preferredSampleRate)
        return min(upsampled, maxStableEffectSampleRate)
    }

    /// Performs the cheap metadata-only part of the offline allocation check.
    /// This lets callers skip an impossible Precision Sinc build while the
    /// normal file stream continues playing.
    nonisolated static func canPrepareOffline(url: URL, upsamplingMode: UpsamplingMode) -> Bool {
        guard upsamplingMode.isPrecisionSinc,
              let audioFile = try? AVAudioFile(forReading: url) else {
            return false
        }

        let sourceFormat = audioFile.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: resolvedProcessingSampleRate(for: sourceFormat.sampleRate),
            channels: max(AVAudioChannelCount(2), sourceFormat.channelCount),
            interleaved: false
        )!

        do {
            let sourceLength = try checkedAudioFrameCount(
                audioFile.length,
                format: sourceFormat,
                failure: .sourceBufferFailed
            )
            try validateOfflineProcessingFootprint(
                sourceFrameCount: sourceLength,
                sourceFormat: sourceFormat,
                targetFormat: targetFormat,
                upsamplingMode: upsamplingMode
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - Private: Engine Configuration

    private func configureAudioEngine() {
        engine.attach(playerNode)
        engine.attach(upgradePlayerNode)
        engine.attach(sourceMixer)
        engine.attach(declickMixer)
        engine.attach(inputGainEQ)
        engine.attach(loudnessCompensationEQ)
        engine.attach(automaticDSPEQ)
        
        for effect in effectPipeline {
            effect.attach(to: engine)
        }
        engine.attach(outputSafetyEQ)
        if let outputLimiter {
            engine.attach(outputLimiter)
        }
        declickMixer.outputVolume = 1.0
        inputGainEQ.globalGain = 0
        inputGainEQ.bands[0].bypass = true
        configureLoudnessCompensation()
        configureAutomaticDSP()

        outputSafetyEQ.globalGain = 0
        outputSafetyEQ.bands[0].filterType = .parametric
        outputSafetyEQ.bands[0].frequency = 1000
        outputSafetyEQ.bands[0].bandwidth = 1
        outputSafetyEQ.bands[0].gain = 0
        outputSafetyEQ.bands[0].bypass = true
        configureOutputLimiter()

        connectPipeline(format: nil)
    }

    private func connectPipeline(format: AVAudioFormat?) {
        engine.disconnectNodeOutput(playerNode)
        engine.disconnectNodeOutput(upgradePlayerNode)
        engine.disconnectNodeOutput(sourceMixer)
        engine.disconnectNodeOutput(inputGainEQ)
        engine.disconnectNodeOutput(loudnessCompensationEQ)
        engine.disconnectNodeOutput(automaticDSPEQ)
        for effect in effectPipeline {
            for node in effect.nodes {
                engine.disconnectNodeOutput(node)
            }
        }
        engine.disconnectNodeOutput(outputSafetyEQ)
        if let outputLimiter {
            engine.disconnectNodeOutput(outputLimiter)
        }
        engine.disconnectNodeOutput(declickMixer)
        
        for effect in effectPipeline {
            effect.connectInternalNodes(engine: engine, format: format)
        }
        
        engine.connect(playerNode, to: sourceMixer, fromBus: 0, toBus: 0, format: format)
        engine.connect(upgradePlayerNode, to: sourceMixer, fromBus: 0, toBus: 1, format: format)
        engine.connect(sourceMixer, to: inputGainEQ, format: format)
        engine.connect(inputGainEQ, to: loudnessCompensationEQ, format: format)
        engine.connect(loudnessCompensationEQ, to: automaticDSPEQ, format: format)
        var previousNode: AVAudioNode = automaticDSPEQ
        let fullPipeline = effectPipeline

        for effect in fullPipeline {
            engine.connect(previousNode, to: effect.inputNode, format: format)
            previousNode = effect.outputNode
        }

        engine.connect(previousNode, to: outputSafetyEQ, format: format)
        if let outputLimiter {
            engine.connect(outputSafetyEQ, to: outputLimiter, format: format)
            engine.connect(outputLimiter, to: declickMixer, format: format)
        } else {
            engine.connect(outputSafetyEQ, to: declickMixer, format: format)
        }
        engine.connect(declickMixer, to: engine.mainMixerNode, format: format)
        playerNode.volume = isUpgradePlayerNodeActive ? 0.0 : 1.0
        upgradePlayerNode.volume = isUpgradePlayerNodeActive ? 1.0 : 0.0
    }

    private func configureAutomaticDSP() {
        automaticDSPEQ.globalGain = 0

        automaticDSPEQ.bands[0].filterType = .lowShelf
        automaticDSPEQ.bands[0].frequency = 95
        automaticDSPEQ.bands[0].bandwidth = 0.85
        automaticDSPEQ.bands[0].gain = 0
        automaticDSPEQ.bands[0].bypass = false

        automaticDSPEQ.bands[1].filterType = .parametric
        automaticDSPEQ.bands[1].frequency = 280
        automaticDSPEQ.bands[1].bandwidth = 1.15
        automaticDSPEQ.bands[1].gain = 0
        automaticDSPEQ.bands[1].bypass = false

        automaticDSPEQ.bands[2].filterType = .parametric
        automaticDSPEQ.bands[2].frequency = 3_100
        automaticDSPEQ.bands[2].bandwidth = 1.05
        automaticDSPEQ.bands[2].gain = 0
        automaticDSPEQ.bands[2].bypass = false

        automaticDSPEQ.bands[3].filterType = .highShelf
        automaticDSPEQ.bands[3].frequency = 9_500
        automaticDSPEQ.bands[3].bandwidth = 0.72
        automaticDSPEQ.bands[3].gain = 0
        automaticDSPEQ.bands[3].bypass = false

        applyAutomaticDSPProfile(.neutral)
    }

    private func configureLoudnessCompensation() {
        loudnessCompensationEQ.globalGain = 0

        loudnessCompensationEQ.bands[0].filterType = .lowShelf
        loudnessCompensationEQ.bands[0].frequency = 105
        loudnessCompensationEQ.bands[0].bandwidth = 0.88
        loudnessCompensationEQ.bands[0].gain = 0
        loudnessCompensationEQ.bands[0].bypass = false

        loudnessCompensationEQ.bands[1].filterType = .parametric
        loudnessCompensationEQ.bands[1].frequency = 245
        loudnessCompensationEQ.bands[1].bandwidth = 1.10
        loudnessCompensationEQ.bands[1].gain = 0
        loudnessCompensationEQ.bands[1].bypass = false

        loudnessCompensationEQ.bands[2].filterType = .parametric
        loudnessCompensationEQ.bands[2].frequency = 2_850
        loudnessCompensationEQ.bands[2].bandwidth = 0.95
        loudnessCompensationEQ.bands[2].gain = 0
        loudnessCompensationEQ.bands[2].bypass = false

        loudnessCompensationEQ.bands[3].filterType = .highShelf
        loudnessCompensationEQ.bands[3].frequency = 7_800
        loudnessCompensationEQ.bands[3].bandwidth = 0.80
        loudnessCompensationEQ.bands[3].gain = 0
        loudnessCompensationEQ.bands[3].bypass = false
    }

    private func applyLoudnessCompensation(for outputVolume: Float) {
        let amount = loudnessCompensationAmount(for: outputVolume)
        let warmth = amount * amount
        let routeProfile = loudnessCompensationRouteProfile

        loudnessCompensationEQ.bypass = amount < 0.02
        switch routeProfile {
        case .speaker:
            loudnessCompensationEQ.globalGain = -0.40 * amount
            loudnessCompensationEQ.bands[0].gain = 8.0 * amount
            loudnessCompensationEQ.bands[1].gain = 2.4 * warmth
            loudnessCompensationEQ.bands[2].gain = -1.4 * amount
            loudnessCompensationEQ.bands[3].gain = 4.2 * amount
        case .headphone:
            loudnessCompensationEQ.globalGain = -0.20 * amount
            loudnessCompensationEQ.bands[0].gain = 5.3 * amount
            loudnessCompensationEQ.bands[1].gain = 1.25 * warmth
            loudnessCompensationEQ.bands[2].gain = -0.65 * amount
            loudnessCompensationEQ.bands[3].gain = 6.4 * amount
        case .bluetooth:
            loudnessCompensationEQ.globalGain = -0.26 * amount
            loudnessCompensationEQ.bands[0].gain = 4.7 * amount
            loudnessCompensationEQ.bands[1].gain = 1.0 * warmth
            loudnessCompensationEQ.bands[2].gain = -0.45 * amount
            loudnessCompensationEQ.bands[3].gain = 4.8 * amount
        case .airPlay:
            loudnessCompensationEQ.globalGain = -0.16 * amount
            loudnessCompensationEQ.bands[0].gain = 3.2 * amount
            loudnessCompensationEQ.bands[1].gain = 0.75 * warmth
            loudnessCompensationEQ.bands[2].gain = -0.30 * amount
            loudnessCompensationEQ.bands[3].gain = 3.4 * amount
        }
        if hasTrack {
            applyGainStaging(effectSettings: Array(lastAppliedEffectSettings.values))
        }
    }

    private func loudnessCompensationAmount(for outputVolume: Float) -> Float {
        // Start the contour earlier and rise more decisively through the
        // common quiet-listening range while retaining a smooth transition.
        let normalized = (0.80 - outputVolume) / 0.68
        let clamped = min(max(normalized, 0.0), 1.0)
        return clamped * clamped * (3.0 - 2.0 * clamped)
    }

    nonisolated private static func currentLoudnessCompensationRouteProfile() -> LoudnessCompensationRouteProfile {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        if outputs.contains(where: { $0.portType == .airPlay }) {
            return .airPlay
        }
        if outputs.contains(where: {
            switch $0.portType {
            case .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                return true
            default:
                return false
            }
        }) {
            return .bluetooth
        }
        if outputs.contains(where: { $0.portType == .headphones }) {
            return .headphone
        }
        return .speaker
    }

    private func applyAutomaticDSPProfile(_ profile: AutomaticDSPProfile) {
        let scaled = scaledAutomaticDSPProfile(profile)
        automaticDSPEQ.bypass = scaled.shouldBypass
        automaticDSPEQ.bands[0].gain = scaled.lowShelfGainDB
        automaticDSPEQ.bands[1].gain = scaled.lowMidGainDB
        automaticDSPEQ.bands[2].gain = scaled.presenceGainDB
        automaticDSPEQ.bands[3].gain = scaled.highShelfGainDB
    }

    private func scaledAutomaticDSPProfile(_ profile: AutomaticDSPProfile? = nil) -> AutomaticDSPProfile {
        let base = profile ?? automaticDSPProfile
        let voicingScale: Float
        switch automaticDSPVoicing {
        case .natural:
            voicingScale = 1.0
        case .reference:
            voicingScale = 0.55
        case .immersive:
            voicingScale = 1.25
        case .safe:
            voicingScale = 0.35
        }
        return AutomaticDSPProfile(
            lowShelfGainDB: base.lowShelfGainDB * automaticDSPStrength * voicingScale,
            lowMidGainDB: base.lowMidGainDB * automaticDSPStrength * voicingScale,
            presenceGainDB: base.presenceGainDB * automaticDSPStrength * voicingScale,
            highShelfGainDB: base.highShelfGainDB * automaticDSPStrength * voicingScale
        )
    }

    private static func makePeakLimiter() -> AVAudioUnit? {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_PeakLimiter,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard AudioComponentFindNext(nil, &desc) != nil else { return nil }
        return AVAudioUnitEffect(audioComponentDescription: desc)
    }

    private func configureOutputLimiter() {
        guard let outputLimiter else { return }
        outputLimiter.auAudioUnit.parameterTree?.allParameters.forEach { parameter in
            let key = "\(parameter.identifier) \(parameter.displayName)".lowercased()
            if key.contains("threshold") {
                // Keep the final safety ceiling below 0 dBFS so intersample peaks
                // have a small reserve before the output route.
                parameter.value = -1.0
            } else if key.contains("attack") {
                parameter.value = 0.0005
            } else if key.contains("decay") || key.contains("release") {
                parameter.value = 0.080
            } else if key.contains("pre") && key.contains("gain") {
                parameter.value = 0
            }
        }
    }

    private func ensureEngineRunning() throws {
        if !engine.isRunning {
            try engine.start()
        }
    }

    private func configureProcessingFormat(_ format: AVAudioFormat) {
        if let configuredProcessingFormat,
           abs(configuredProcessingFormat.sampleRate - format.sampleRate) < 0.1,
           configuredProcessingFormat.channelCount == format.channelCount,
           configuredProcessingFormat.commonFormat == format.commonFormat,
           configuredProcessingFormat.isInterleaved == format.isInterleaved {
            // stop() removes all taps while retaining the configured format.
            // Reinstall them when the next track uses the same format;
            // otherwise both level meters and spectrum remain at rest.
            ensureEffectLevelMetersInstalled()
            return
        }
        if engine.isRunning {
            engine.stop()
        }
        connectPipeline(format: format)
        installEffectLevelMeters()
        configuredProcessingFormat = format
    }

    private func applyGainStaging(effectSettings: [RealtimeAudioEffectSetting]) {
        let sourceRMS = signalDiagnostics?.sourceRMSDBFS ?? Self.floatPipelineTargetRMSDBFS
        let sourceLoudness = signalDiagnostics?.sourceIntegratedLoudnessLUFS ?? sourceRMS
        let sourcePeak = signalDiagnostics?.sourcePeakDBFS ?? -12.0

        _ = refreshEffectLevelAudits()
        let measuredBoost = measuredEffectBoostFromAudits(effectSettings: effectSettings)
        let estimatedEffectBoost = Float(
            effectPipeline.reduce(0.0) { partial, effect in
                partial + max(0, effect.estimatedGainBoostDB)
            }
        )
        let scaledAutomaticDSP = scaledAutomaticDSPProfile()
        let automaticDSPBoost = max(
            0,
            scaledAutomaticDSP.lowShelfGainDB,
            scaledAutomaticDSP.lowMidGainDB,
            scaledAutomaticDSP.presenceGainDB,
            scaledAutomaticDSP.highShelfGainDB
        )
        let loudnessBoost = estimatedLoudnessCompensationBoostDB()
        // Estimates are available immediately, while tap measurements arrive
        // later. Use whichever is larger so startup and parameter changes do
        // not briefly run without the required headroom.
        let effectBoost = max(measuredBoost ?? 0, estimatedEffectBoost)
            + automaticDSPBoost
            + loudnessBoost

        let rmsBasedTrim = Self.floatPipelineTargetRMSDBFS - sourceRMS
        let loudnessBasedTrim = Self.loudnessNormalizationTargetLUFS - sourceLoudness
        let preFXPeakLimit = Self.floatPipelinePeakCeilingDBFS - Self.intersamplePeakReserveDB
        let peakSafeTrim = preFXPeakLimit - sourcePeak
        let normalizationTrim = min(loudnessBasedTrim, rmsBasedTrim + 3.0)
        let inputTrimDB = min(Self.maxInputBoostDB, max(Self.maxInputCutDB, min(normalizationTrim, peakSafeTrim)))

        let preFXPeak = sourcePeak + inputTrimDB
        let inputHeadroomDB = max(0.0, Self.floatPipelinePeakCeilingDBFS - preFXPeak)
        let estimatedPostFXPeak = preFXPeak + effectBoost + Self.intersamplePeakReserveDB
        let fxHeadroomDB = max(0.0, Self.finalOutputCeilingDBFS - estimatedPostFXPeak)
        let outputTrimDB = min(0.0, Self.finalOutputCeilingDBFS - estimatedPostFXPeak)
        
        // Both normal and high-quality players converge before this dedicated
        // dB gain stage. Unlike mixer volume, it supports both cuts and boosts
        // without being overwritten by crossfade gains.
        inputGainEQ.globalGain = inputTrimDB
        plannedOutputTrimDB = outputTrimDB
        applyOutputSafetyGain()

        if let diagnostics = signalDiagnostics {
            signalDiagnostics = SignalLevelDiagnostics(
                sourcePeakDBFS: diagnostics.sourcePeakDBFS,
                sourceRMSDBFS: diagnostics.sourceRMSDBFS,
                sourceIntegratedLoudnessLUFS: diagnostics.sourceIntegratedLoudnessLUFS,
                recommendedInputTrimDB: inputTrimDB,
                inputHeadroomDB: inputHeadroomDB,
                outputTrimDB: outputTrimDB,
                fxHeadroomDB: fxHeadroomDB
            )
        }
        
        _ = refreshEffectLevelAudits()
    }

    private func applyOutputSafetyGain() {
        outputSafetyEQ.globalGain = plannedOutputTrimDB
    }

    private func estimatedLoudnessCompensationBoostDB() -> Float {
        guard !loudnessCompensationEQ.bypass else { return 0 }
        let largestBandBoost = loudnessCompensationEQ.bands.reduce(Float(0)) { partial, band in
            guard !band.bypass else { return partial }
            return max(partial, band.gain)
        }
        return max(0, largestBandBoost + loudnessCompensationEQ.globalGain)
    }

    private func installEffectLevelMeters() {
        clearEffectLevelMeters()
        
        // Index 0 is the signal entering the modular effect chain. The final
        // index is the actual main-mixer output after trim and limiting.
        var targets: [(index: Int, node: AVAudioNode)] = [(0, automaticDSPEQ)]
        for (index, effect) in effectPipeline.enumerated() {
            targets.append((index + 1, effect.outputNode))
        }
        targets.append((effectPipeline.count + 1, engine.mainMixerNode))
        
        let meterCount = targets.count
        if #available(iOS 16.0, *) {
            meterLevels = ModernMeterLevelStore(count: meterCount)
        } else {
            meterLevels = LegacyMeterLevelStore(count: meterCount)
        }
        
        var installedNodeIDs: Set<ObjectIdentifier> = []
        for target in targets {
            let nodeID = ObjectIdentifier(target.node)
            guard !installedNodeIDs.contains(nodeID) else { continue }
            installedNodeIDs.insert(nodeID)
            
            target.node.installTap(
                onBus: 0,
                bufferSize: spectrumAnalyzer.analysisFrameCount,
                format: nil
            ) { [weak self] buffer, _ in
                guard let self else { return }
                let isFinal = target.index == meterCount - 1
                if isFinal {
                    self.renderHealthMonitor.recordRender(
                        frameCount: buffer.frameLength,
                        sampleRate: buffer.format.sampleRate
                    )
                }
                guard self.realtimeAnalysisGate.enabledIfAvailable() else { return }
                let levels = self.computeLevels(from: buffer, isFinalOutput: isFinal)
                self.meterLevels.tryUpdate(index: target.index, levels: levels)
            }
            tappedNodes.append(target.node)
        }
    }

    /// Repairs visualization taps if a lifecycle path removed them while a
    /// playable track is still configured. This is intentionally idempotent
    /// and is called both before playback and before meter snapshots.
    private func ensureEffectLevelMetersInstalled() {
        guard hasTrack, tappedNodes.isEmpty else { return }
        installEffectLevelMeters()
    }

    private func clearEffectLevelMeters() {
        for node in tappedNodes {
            node.removeTap(onBus: 0)
        }
        tappedNodes.removeAll()
        meterLevels.clear()
    }

    private func measuredEffectBoostFromAudits(effectSettings: [RealtimeAudioEffectSetting]) -> Float? {
        let enabledKinds = Set(effectSettings.filter(\.isEnabled).map(\.kind))
        guard !enabledKinds.isEmpty else {
            smoothedMeasuredEffectBoostDB = 0
            return 0
        }

        let enabledAudits = effectLevelAudits.filter { enabledKinds.contains($0.kind) }
        guard !enabledAudits.isEmpty else { return nil }

        let validAudits = enabledAudits.filter {
            $0.inputPeakDBFS > -100
                && $0.inputRMSDBFS > -100
                && $0.outputPeakDBFS > -100
                && $0.outputRMSDBFS > -100
        }
        guard !validAudits.isEmpty else { return nil }

        let peakLift = validAudits.reduce(Float(0)) { partial, audit in
            partial + max(0, audit.peakDeltaDB)
        }
        let rmsLift = validAudits.reduce(Float(0)) { partial, audit in
            partial + max(0, audit.rmsDeltaDB)
        }

        let measuredBoost = min(12, max(0, max(peakLift * 0.55, rmsLift * 0.8)))
        
        let now = Date()
        let elapsed = Float(max(0.0001, now.timeIntervalSince(lastGainStagingDate)))
        lastGainStagingDate = now
        
        let tau: Float = 0.050 // 50ms time constant
        let alpha = 1.0 - exp(-elapsed / tau)
        smoothedMeasuredEffectBoostDB = smoothedMeasuredEffectBoostDB * (1.0 - alpha) + measuredBoost * alpha
        
        return smoothedMeasuredEffectBoostDB
    }

    nonisolated private func computeLevels(from buffer: AVAudioPCMBuffer, isFinalOutput: Bool = false) -> (peakDBFS: Float, rmsDBFS: Float) {
        guard let channelData = buffer.floatChannelData else {
            return (-120, -120)
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else {
            return (-120, -120)
        }

        if isFinalOutput {
            updateSpectrum(buffer: buffer)
        }

        var peak: Float = 0
        var squareSum: Float = 0
        var sampleCount: Int = 0

        for channel in 0..<channelCount {
            let samples = UnsafeBufferPointer(start: channelData[channel], count: frameLength)
            var channelPeak: Float = 0
            vDSP_maxmgv(samples.baseAddress!, 1, &channelPeak, vDSP_Length(frameLength))
            peak = max(peak, channelPeak)
            
            var channelSquareSum: Float = 0
            vDSP_svesq(samples.baseAddress!, 1, &channelSquareSum, vDSP_Length(frameLength))
            squareSum += channelSquareSum
            sampleCount += frameLength
        }

        if isFinalOutput {
            let truePeak = Self.estimateTruePeakAmplitude(
                channelData: channelData,
                channelCount: channelCount,
                frameLength: frameLength
            )
            peak = max(peak, truePeak)
        }

        let rms = sampleCount > 0 ? sqrt(squareSum / Float(sampleCount)) : 0
        return (amplitudeToDBFS(peak), amplitudeToDBFS(rms))
    }

    nonisolated private static func estimateTruePeakAmplitude(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameLength: Int
    ) -> Float {
        guard channelCount > 0, frameLength > 0 else { return 0 }

        var truePeak: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            if frameLength == 1 {
                truePeak = max(truePeak, abs(samples[0]))
                continue
            }

            for index in 0..<(frameLength - 1) {
                let y0 = index > 0 ? samples[index - 1] : samples[index]
                let y1 = samples[index]
                let y2 = samples[index + 1]
                let y3 = (index + 2) < frameLength ? samples[index + 2] : y2

                for step in 0..<truePeakLimiterLookaheadOversampleFactor {
                    let fraction = Float(step) / Float(truePeakLimiterLookaheadOversampleFactor)
                    let interpolated = catmullRom(y0: y0, y1: y1, y2: y2, y3: y3, t: fraction)
                    truePeak = max(truePeak, abs(interpolated))
                }
            }

            truePeak = max(truePeak, abs(samples[frameLength - 1]))
        }

        return truePeak
    }

    nonisolated private static func catmullRom(
        y0: Float,
        y1: Float,
        y2: Float,
        y3: Float,
        t: Float
    ) -> Float {
        let t2 = t * t
        let t3 = t2 * t
        return 0.5 * (
            (2.0 * y1) +
            (-y0 + y2) * t +
            (2.0 * y0 - 5.0 * y1 + 4.0 * y2 - y3) * t2 +
            (-y0 + 3.0 * y1 - 3.0 * y2 + y3) * t3
        )
    }

    nonisolated private func updateSpectrum(buffer: AVAudioPCMBuffer) {
        // Every render buffer feeds the long low-frequency window. The
        // analyzer internally decimates the shorter FFT to control CPU load.
        spectrumAnalyzer.update(buffer: buffer)
    }

    nonisolated static func analyzeSignalLevels(in buffer: AVAudioPCMBuffer) -> SignalLevelDiagnostics {
        guard let channelData = buffer.floatChannelData else {
            return emptySignalDiagnostics()
        }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else {
            return emptySignalDiagnostics()
        }

        var peak: Float = 0
        var squareSum: Float = 0
        var sampleCount: Int = 0

        for channel in 0..<channelCount {
            let samples = UnsafeBufferPointer(start: channelData[channel], count: frameLength)
            for (index, sample) in samples.enumerated() {
                if index & 0x3FFF == 0, Task.isCancelled {
                    return emptySignalDiagnostics()
                }
                let magnitude = abs(sample)
                peak = max(peak, magnitude)
                squareSum += sample * sample
            }
            sampleCount += frameLength
        }

        let rms = sampleCount > 0 ? sqrt(squareSum / Float(sampleCount)) : 0
        let peakDBFS = amplitudeToDBFS(peak)
        let integratedLoudness = Self.estimateIntegratedLoudnessLUFS(
            channelData: channelData,
            channelCount: channelCount,
            frameLength: frameLength,
            sampleRate: buffer.format.sampleRate
        )
        return SignalLevelDiagnostics(
            sourcePeakDBFS: peakDBFS,
            sourceRMSDBFS: amplitudeToDBFS(rms),
            sourceIntegratedLoudnessLUFS: integratedLoudness,
            recommendedInputTrimDB: 0,
            inputHeadroomDB: max(0, Self.floatPipelinePeakCeilingDBFS - peakDBFS),
            outputTrimDB: 0,
            fxHeadroomDB: 3
        )
    }

    nonisolated private static func emptySignalDiagnostics() -> SignalLevelDiagnostics {
        SignalLevelDiagnostics(
            sourcePeakDBFS: -120,
            sourceRMSDBFS: -120,
            sourceIntegratedLoudnessLUFS: -120,
            recommendedInputTrimDB: 0,
            inputHeadroomDB: 0,
            outputTrimDB: 0,
            fxHeadroomDB: 3
        )
    }

    nonisolated private static func analyzeAutomaticDSP(
        in buffer: AVAudioPCMBuffer,
        diagnostics: SignalLevelDiagnostics
    ) -> AutomaticDSPProfile {
        guard let channelData = buffer.floatChannelData else { return .neutral }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let sampleRate = buffer.format.sampleRate
        guard channelCount > 0, frameLength > 0, sampleRate > 0 else { return .neutral }

        let lowAlpha = Float(min(0.12, (2.0 * Double.pi * 160.0) / sampleRate))
        let midAlpha = Float(min(0.22, (2.0 * Double.pi * 2_400.0) / sampleRate))
        let highAlpha = Float(min(0.35, (2.0 * Double.pi * 4_200.0) / sampleRate))
        var lowLP: Float = 0
        var midLP: Float = 0
        var highLP: Float = 0
        var totalSquare: Float = 0
        var lowSquare: Float = 0
        var midSquare: Float = 0
        var highSquare: Float = 0

        for frame in 0..<frameLength {
            if frame & 0x3FFF == 0, Task.isCancelled {
                return .neutral
            }
            var mono: Float = 0
            for channel in 0..<channelCount {
                mono += channelData[channel][frame]
            }
            mono /= Float(channelCount)

            lowLP += lowAlpha * (mono - lowLP)
            midLP += midAlpha * (mono - midLP)
            highLP += highAlpha * (mono - highLP)
            let mid = midLP - lowLP
            let high = mono - highLP

            totalSquare += mono * mono
            lowSquare += lowLP * lowLP
            midSquare += mid * mid
            highSquare += high * high
        }

        guard totalSquare > 0 else { return .neutral }

        let invCount = 1.0 / Float(frameLength)
        let totalRMS = sqrt(totalSquare * invCount)
        let lowRMS = sqrt(lowSquare * invCount)
        let midRMS = sqrt(midSquare * invCount)
        let highRMS = sqrt(highSquare * invCount)
        let lowBalanceDB = amplitudeToDBFS(lowRMS / max(totalRMS, 0.000_001))
        let midBalanceDB = amplitudeToDBFS(midRMS / max(totalRMS, 0.000_001))
        let highBalanceDB = amplitudeToDBFS(highRMS / max(totalRMS, 0.000_001))
        let crestDB = diagnostics.sourcePeakDBFS - diagnostics.sourceRMSDBFS
        let loudness = diagnostics.sourceIntegratedLoudnessLUFS

        var lowShelf: Float = 0
        var lowMid: Float = 0
        var presence: Float = 0
        var highShelf: Float = 0

        if lowBalanceDB < -15.5 {
            lowShelf = min(1.8, (-15.5 - lowBalanceDB) * 0.26)
            lowMid = 0.25
        } else if lowBalanceDB > -8.5 {
            lowShelf = max(-2.0, (-8.5 - lowBalanceDB) * 0.22)
            lowMid = max(-1.2, (-8.5 - lowBalanceDB) * 0.12)
        }

        if highBalanceDB < -24.0 {
            highShelf = min(1.8, (-24.0 - highBalanceDB) * 0.22)
            presence = min(0.8, highShelf * 0.45)
        } else if highBalanceDB > -16.0 {
            highShelf = max(-1.8, (-16.0 - highBalanceDB) * 0.20)
            presence = max(-0.9, highShelf * 0.45)
        }

        // Perceptual masking: when the low band dominates the low-mid area,
        // make room before adding presence. This avoids the brittle "boost highs"
        // solution and keeps vocal intelligibility at a lower total gain.
        let lowMidMasking = clamp((lowBalanceDB - midBalanceDB - 3.5) / 12.0, 0, 1)
        lowMid -= lowMidMasking * 0.85
        presence += lowMidMasking * 0.28

        // Avoid exaggerating an already bright, spectrally dense master.
        let brightDensity = clamp((highBalanceDB + 15.5) / 8.0, 0, 1)
        if crestDB < 8.0 {
            highShelf -= brightDensity * 0.38
            presence -= brightDensity * 0.16
        }

        if loudness > -11.0 || crestDB < 7.0 {
            let restraint: Float = 0.55
            lowShelf = min(lowShelf, max(-2.0, lowShelf * restraint))
            highShelf = min(highShelf, max(-1.8, highShelf * restraint))
            presence = min(presence, max(-0.9, presence * restraint - 0.25))
        } else if loudness < -22.0 && crestDB > 12.0 {
            lowShelf += 0.22
            presence += 0.25
            highShelf += 0.22
        }

        return AutomaticDSPProfile(
            lowShelfGainDB: clamp(lowShelf, -2.0, 1.8),
            lowMidGainDB: clamp(lowMid, -1.2, 0.6),
            presenceGainDB: clamp(presence, -0.9, 1.0),
            highShelfGainDB: clamp(highShelf, -1.8, 1.8)
        )
    }

    nonisolated private static func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(max(value, lower), upper)
    }

    nonisolated private static func makeAnalysisCacheKey(
        url: URL?,
        targetSampleRate: Double,
        upsamplingMode: UpsamplingMode,
        spatialSettings: HeadphoneSpatialSettings
    ) -> AnalysisCacheKey {
        let sourceIdentity = url.map(sourceIdentityForCache) ?? "unknown"
        let fileSignature = fileSignatureForCache(url: url)
        return AnalysisCacheKey(
            sourceIdentity: sourceIdentity,
            fileSize: fileSignature.fileSize,
            modificationTime: fileSignature.modificationTime,
            targetSampleRateRounded: Int(targetSampleRate.rounded()),
            upsamplingModeRaw: upsamplingMode.rawValue,
            hrtfPresetRaw: spatialSettings.preset.rawValue,
            spatialMilli: Int((spatialSettings.spatial * 1000).rounded()),
            crossfeedMilli: Int((spatialSettings.crossfeed * 1000).rounded())
        )
    }

    nonisolated private static func makePreloadedPlaybackKey(
        url: URL,
        upsamplingMode: UpsamplingMode,
        spatialSettings: HeadphoneSpatialSettings
    ) -> PreloadedPlaybackKey {
        let signature = fileSignatureForCache(url: url)
        return PreloadedPlaybackKey(
            sourceIdentity: sourceIdentityForCache(url),
            fileSize: signature.fileSize,
            modificationTime: signature.modificationTime,
            upsamplingModeRaw: upsamplingMode.rawValue,
            hrtfPresetRaw: spatialSettings.preset.rawValue,
            spatialMilli: Int((spatialSettings.spatial * 1000).rounded()),
            crossfeedMilli: Int((spatialSettings.crossfeed * 1000).rounded())
        )
    }

    /// Reuses an in-flight preload instead of starting the same full-track
    /// conversion twice. Cancellation of a caller does not cancel the shared
    /// preload; a later request can still consume its result.
    private func awaitPreloadedPlaybackData(
        for key: PreloadedPlaybackKey
    ) async -> PreparedPlaybackData? {
        if let prepared = preloadedPlaybackCache.removeValue(forKey: key) {
            return prepared
        }
        if let task = preloadTasks[key] {
            await task.value
        }
        return preloadedPlaybackCache.removeValue(forKey: key)
    }

    nonisolated private static func fileSignatureForCache(url: URL?) -> (fileSize: UInt64, modificationTime: Int64) {
        guard let url else { return (0, 0) }
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return (fileSize, Int64((modificationDate * 1000).rounded()))
    }

    /// File paths are sufficient for imported local files, but MediaPlayer
    /// asset URLs distinguish songs in their scheme/query (for example the
    /// persistent `id` in `ipod-library://...`). Using only `url.path` makes
    /// every such item look like the same `/item/item.mp3` cache source.
    nonisolated private static func sourceIdentityForCache(_ url: URL) -> String {
        if url.isFileURL {
            return url.standardizedFileURL.resolvingSymlinksInPath().path
        }
        return url.absoluteString
    }

    nonisolated private static func preparedPlaybackData(
        _ prepared: PreparedPlaybackData,
        matches expectedURL: URL
    ) -> Bool {
        sourceIdentityForCache(prepared.url) == sourceIdentityForCache(expectedURL)
    }

    nonisolated private static func cachedAnalysis(for key: AnalysisCacheKey) -> AnalysisCacheValue? {
        analysisCacheLock.lock()
        defer { analysisCacheLock.unlock() }
        if let value = analysisCache[key] {
            analysisCacheHits += 1
            return value
        }
        analysisCacheMisses += 1
        return nil
    }

    nonisolated private static func storeCachedAnalysis(_ value: AnalysisCacheValue, for key: AnalysisCacheKey) {
        analysisCacheLock.lock()
        defer { analysisCacheLock.unlock() }
        if analysisCache.count >= 256 {
            analysisCache.removeAll(keepingCapacity: true)
        }
        analysisCache[key] = value
    }

    nonisolated private static func analysisCacheStatsSnapshot() -> (hits: Int, misses: Int) {
        analysisCacheLock.lock()
        defer { analysisCacheLock.unlock() }
        return (analysisCacheHits, analysisCacheMisses)
    }

    nonisolated private static func clearAnalysisCache() {
        analysisCacheLock.lock()
        analysisCache.removeAll(keepingCapacity: false)
        analysisCacheHits = 0
        analysisCacheMisses = 0
        analysisCacheLock.unlock()
    }

    nonisolated private static func estimateIntegratedLoudnessLUFS(
        channelData: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameLength: Int,
        sampleRate: Double
    ) -> Float {
        guard channelCount > 0, frameLength > 0, sampleRate > 0 else { return -120 }

        let blockSize = max(1, min(frameLength, Int(sampleRate * 0.400)))
        let hopSize = max(1, Int(sampleRate * 0.100))
        var blockMeanSquares: [Float] = []
        var start = 0

        while start < frameLength {
            let end = min(frameLength, start + blockSize)
            let frames = end - start
            guard frames > 0 else { break }

            var squareSum: Float = 0
            for channel in 0..<channelCount {
                let samples = channelData[channel].advanced(by: start)
                var channelSquareSum: Float = 0
                vDSP_svesq(samples, 1, &channelSquareSum, vDSP_Length(frames))
                squareSum += channelSquareSum
            }

            let meanSquare = squareSum / Float(frames * channelCount)
            if meanSquare > 0 {
                blockMeanSquares.append(meanSquare)
            }

            if end == frameLength { break }
            start += hopSize
        }

        guard !blockMeanSquares.isEmpty else { return -120 }

        let absoluteGateLUFS: Float = -70
        let absoluteGated = blockMeanSquares.filter { loudnessLUFS(meanSquare: $0) > absoluteGateLUFS }
        let firstPassBlocks = absoluteGated.isEmpty ? blockMeanSquares : absoluteGated
        let firstPassMeanSquare = firstPassBlocks.reduce(Float(0), +) / Float(firstPassBlocks.count)
        let relativeGateLUFS = max(absoluteGateLUFS, loudnessLUFS(meanSquare: firstPassMeanSquare) - 10.0)

        let gatedBlocks = firstPassBlocks.filter { loudnessLUFS(meanSquare: $0) > relativeGateLUFS }
        let finalBlocks = gatedBlocks.isEmpty ? firstPassBlocks : gatedBlocks
        let integratedMeanSquare = finalBlocks.reduce(Float(0), +) / Float(finalBlocks.count)
        return loudnessLUFS(meanSquare: integratedMeanSquare)
    }

    nonisolated private static func loudnessLUFS(meanSquare: Float) -> Float {
        guard meanSquare > 0 else { return -120 }
        return max(-120, -0.691 + 10.0 * log10(meanSquare))
    }

    private func clamped(_ value: Double?, defaultValue: Double) -> Float {
        Float(min(max(value ?? defaultValue, 0), 1))
    }

    nonisolated static func applyHeadphoneVirtualizationIfNeeded(to buffer: AVAudioPCMBuffer, settings: HeadphoneSpatialSettings) {
        guard settings.isEnabled,
              shouldApplyHeadphoneVirtualization,
              buffer.format.channelCount >= 2,
              let channelData = buffer.floatChannelData else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return }

        let sampleRate = buffer.format.sampleRate
        let preset = headphoneHRTFProfile(for: settings.preset)
        let impulseResponseTaps = hrtfImpulseResponseTaps(for: settings.preset, sampleRate: sampleRate)
        let maximumIRDelay = impulseResponseTaps.map(\.delaySamples).max() ?? 1
        var irCenterBuffer = Array(repeating: Float(0), count: maximumIRDelay + 1)
        var irSideBuffer = Array(repeating: Float(0), count: maximumIRDelay + 1)
        var irIndex = 0
        var temporalEnvelope: Float = 0
        let temporalAttackAlpha = Float(1.0 - exp(-1.0 / max(1.0, sampleRate * 0.0015)))
        let temporalReleaseAlpha = Float(1.0 - exp(-1.0 / max(1.0, sampleRate * 0.045)))
        
        let crossfeedDelaySamples = max(8, Int(sampleRate * preset.crossfeedDelaySeconds))
        let cfBufferLength = crossfeedDelaySamples + 1
        var delayedLeftCF = Array(repeating: Float(0), count: cfBufferLength)
        var delayedRightCF = Array(repeating: Float(0), count: cfBufferLength)
        var cfDelayIndex = 0

        let er1Delay = max(24, Int(sampleRate * preset.earlyReflection1Seconds))
        let er2Delay = max(48, Int(sampleRate * preset.earlyReflection2Seconds))
        let erBufferLength = er2Delay + 1
        var erBuffer = Array(repeating: Float(0), count: erBufferLength)
        var erIndex = 0

        let spatialAmount = Float(min(max(settings.spatial, 0.0), 1.0))
        let crossfeedControl = Float(min(max(settings.crossfeed, 0.0), 1.0))
        
        let crossfeedAmount = Float(preset.crossfeedBase + (crossfeedControl * preset.crossfeedRange))
        let spatialIntensity = pow(spatialAmount, 0.80)
        
        let directGain: Float = 1.0 - (crossfeedAmount * preset.directDucking)
        let sideGain: Float = preset.sideBase - (spatialIntensity * preset.sideReduction)
        
        var leftCrossfeedLP: Float = 0
        var rightCrossfeedLP: Float = 0
        let cfFreq = preset.crossfeedLowpassBaseHz + Double(crossfeedControl) * preset.crossfeedLowpassRangeHz
        let cfOmega = 2.0 * Double.pi * cfFreq
        let cfAlphaRaw = cfOmega / sampleRate
        let crossfeedAlpha = Float(min(preset.crossfeedAlphaLimit, cfAlphaRaw))
        
        let erMix1 = Float(preset.earlyReflection1Mix + (spatialIntensity * preset.earlyReflection1Range))
        let erMix2 = Float(preset.earlyReflection2Mix + (spatialIntensity * preset.earlyReflection2Range))
        let lowMonoOmega = 2.0 * Double.pi * preset.lowMonoCutoffHz
        let lowMonoAlpha = Float(min(0.18, lowMonoOmega / sampleRate))
        var lowSideLP: Float = 0

        var centerPresence = BiquadFilter.peaking(
            sampleRate: sampleRate,
            frequency: preset.centerPresenceHz,
            q: preset.centerPresenceQ,
            gainDB: preset.centerPresenceGainDB + Double(spatialIntensity) * preset.centerPresenceRangeDB
        )
        var centerWarmth = BiquadFilter.peaking(
            sampleRate: sampleRate,
            frequency: preset.centerWarmthHz,
            q: preset.centerWarmthQ,
            gainDB: preset.centerWarmthGainDB + Double(spatialIntensity) * preset.centerWarmthRangeDB
        )
        
        var sideSoftener = BiquadFilter.highShelf(
            sampleRate: sampleRate,
            frequency: preset.sideShelfHz,
            slope: preset.sideShelfSlope,
            gainDB: -(preset.sideShelfCutDB + Double(spatialIntensity) * preset.sideShelfSpatialRangeDB + Double(crossfeedControl) * preset.sideShelfCrossfeedRangeDB)
        )
        var sidePhaseAligner = BiquadFilter.allPass(
            sampleRate: sampleRate,
            frequency: preset.sideShelfHz * 0.82,
            q: 0.72
        )

        let left = channelData[0]
        let right = channelData[1]

        for frame in 0..<frameCount {
            let inputLeft = left[frame]
            let inputRight = right[frame]

            leftCrossfeedLP += crossfeedAlpha * (inputLeft - leftCrossfeedLP)
            rightCrossfeedLP += crossfeedAlpha * (inputRight - rightCrossfeedLP)

            delayedLeftCF[cfDelayIndex] = leftCrossfeedLP
            delayedRightCF[cfDelayIndex] = rightCrossfeedLP
            let cfReadIndex = (cfDelayIndex + 1) % cfBufferLength
            let crossfedLeft = delayedRightCF[cfReadIndex]
            let crossfedRight = delayedLeftCF[cfReadIndex]
            cfDelayIndex = cfReadIndex

            let preLeft = (inputLeft * directGain) + (crossfedLeft * crossfeedAmount)
            let preRight = (inputRight * directGain) + (crossfedRight * crossfeedAmount)

            let center = (preLeft + preRight) * 0.5
            var side = (preLeft - preRight) * 0.5

            // Preserve fast attacks by briefly reducing only the spatial tail.
            // Sustained material and decays receive the full IR blend.
            let detector = max(abs(center), abs(side))
            let envelopeAlpha = detector > temporalEnvelope ? temporalAttackAlpha : temporalReleaseAlpha
            let transientExcess = max(0, detector - temporalEnvelope)
            let transientRatio = min(1.0, transientExcess / max(0.08, detector))
            let temporalIRBlend = 1.0 - transientRatio * 0.35
            temporalEnvelope += envelopeAlpha * (detector - temporalEnvelope)

            // Compact, preset-specific HRTF IR. The direct path remains untouched;
            // only the delayed room/ear reflections are added here.
            irCenterBuffer[irIndex] = center
            irSideBuffer[irIndex] = side
            var irCenterReflection: Float = 0
            var irSideReflection: Float = 0
            for tap in impulseResponseTaps {
                let readIndex = (irIndex + irCenterBuffer.count - tap.delaySamples) % irCenterBuffer.count
                irCenterReflection += irCenterBuffer[readIndex] * tap.centerGain
                irSideReflection += irSideBuffer[readIndex] * tap.sideGain
            }
            let irBlend = spatialIntensity * temporalIRBlend
            let irCenter = center + irCenterReflection * irBlend
            side += irSideReflection * irBlend * 0.35

            erBuffer[erIndex] = irCenter
            let tap1Index = (erIndex + (erBufferLength - er1Delay)) % erBufferLength
            let tap2Index = (erIndex + (erBufferLength - er2Delay)) % erBufferLength
            let reflection = (erBuffer[tap1Index] * erMix1) + (erBuffer[tap2Index] * erMix2)
            
            let shapedCenter = centerWarmth.process(centerPresence.process(irCenter + reflection))
            
            lowSideLP += lowMonoAlpha * (side - lowSideLP)
            side -= lowSideLP * preset.lowMonoAmount
            side = sidePhaseAligner.process(sideSoftener.process(side)) * sideGain

            erIndex = (erIndex + 1) % erBufferLength
            irIndex = (irIndex + 1) % irCenterBuffer.count
            left[frame] = shapedCenter + side
            right[frame] = shapedCenter - side
        }
    }

    private struct HRTFImpulseResponseTap {
        let delaySamples: Int
        let centerGain: Float
        let sideGain: Float
    }

    // Compact synthetic room/ear IRs keep the real-time path bounded. These taps
    // are intentionally short and can later be replaced by measured IR assets.
    nonisolated private static func hrtfImpulseResponseTaps(
        for preset: HeadphoneHRTFPreset,
        sampleRate: Double
    ) -> [HRTFImpulseResponseTap] {
        let asset = ImpulseResponseCatalog.loadMeasuredAsset(named: "HRTF-\(preset.rawValue)")
            ?? ImpulseResponseCatalog.asset(for: preset)
        return asset.taps.map { tap in
            HRTFImpulseResponseTap(
                delaySamples: max(1, Int((tap.delaySeconds * sampleRate).rounded())),
                centerGain: tap.centerGain,
                sideGain: tap.sideGain
            )
        }
    }

    private struct HeadphoneHRTFProfile {
        let crossfeedDelaySeconds: Double
        let crossfeedBase: Float
        let crossfeedRange: Float
        let directDucking: Float
        let sideBase: Float
        let sideReduction: Float
        let crossfeedLowpassBaseHz: Double
        let crossfeedLowpassRangeHz: Double
        let crossfeedAlphaLimit: Double
        let earlyReflection1Seconds: Double
        let earlyReflection2Seconds: Double
        let earlyReflection1Mix: Float
        let earlyReflection1Range: Float
        let earlyReflection2Mix: Float
        let earlyReflection2Range: Float
        let centerPresenceHz: Double
        let centerPresenceQ: Double
        let centerPresenceGainDB: Double
        let centerPresenceRangeDB: Double
        let centerWarmthHz: Double
        let centerWarmthQ: Double
        let centerWarmthGainDB: Double
        let centerWarmthRangeDB: Double
        let sideShelfHz: Double
        let sideShelfSlope: Double
        let sideShelfCutDB: Double
        let sideShelfSpatialRangeDB: Double
        let sideShelfCrossfeedRangeDB: Double
        let lowMonoCutoffHz: Double
        let lowMonoAmount: Float
    }

    nonisolated private static func headphoneHRTFProfile(for preset: HeadphoneHRTFPreset) -> HeadphoneHRTFProfile {
        switch preset {
        case .natural:
            return HeadphoneHRTFProfile(
                crossfeedDelaySeconds: 0.00032,
                crossfeedBase: 0.24,
                crossfeedRange: 0.30,
                directDucking: 0.20,
                sideBase: 0.96,
                sideReduction: 0.48,
                crossfeedLowpassBaseHz: 430,
                crossfeedLowpassRangeHz: 560,
                crossfeedAlphaLimit: 0.22,
                earlyReflection1Seconds: 0.0028,
                earlyReflection2Seconds: 0.0056,
                earlyReflection1Mix: 0.014,
                earlyReflection1Range: 0.030,
                earlyReflection2Mix: 0.006,
                earlyReflection2Range: 0.016,
                centerPresenceHz: 3_050,
                centerPresenceQ: 0.62,
                centerPresenceGainDB: 3.2,
                centerPresenceRangeDB: 5.8,
                centerWarmthHz: 720,
                centerWarmthQ: 0.78,
                centerWarmthGainDB: 1.5,
                centerWarmthRangeDB: 2.0,
                sideShelfHz: 3_900,
                sideShelfSlope: 0.70,
                sideShelfCutDB: 3.2,
                sideShelfSpatialRangeDB: 4.8,
                sideShelfCrossfeedRangeDB: 3.0,
                lowMonoCutoffHz: 135,
                lowMonoAmount: 0.82
            )
        case .frontal:
            return HeadphoneHRTFProfile(
                crossfeedDelaySeconds: 0.00039,
                crossfeedBase: 0.30,
                crossfeedRange: 0.34,
                directDucking: 0.24,
                sideBase: 0.90,
                sideReduction: 0.54,
                crossfeedLowpassBaseHz: 360,
                crossfeedLowpassRangeHz: 500,
                crossfeedAlphaLimit: 0.20,
                earlyReflection1Seconds: 0.0034,
                earlyReflection2Seconds: 0.0068,
                earlyReflection1Mix: 0.018,
                earlyReflection1Range: 0.035,
                earlyReflection2Mix: 0.008,
                earlyReflection2Range: 0.020,
                centerPresenceHz: 2_650,
                centerPresenceQ: 0.58,
                centerPresenceGainDB: 4.4,
                centerPresenceRangeDB: 6.4,
                centerWarmthHz: 650,
                centerWarmthQ: 0.72,
                centerWarmthGainDB: 1.8,
                centerWarmthRangeDB: 2.4,
                sideShelfHz: 3_600,
                sideShelfSlope: 0.66,
                sideShelfCutDB: 4.2,
                sideShelfSpatialRangeDB: 5.4,
                sideShelfCrossfeedRangeDB: 3.4,
                lowMonoCutoffHz: 155,
                lowMonoAmount: 0.90
            )
        case .wide:
            return HeadphoneHRTFProfile(
                crossfeedDelaySeconds: 0.00026,
                crossfeedBase: 0.16,
                crossfeedRange: 0.22,
                directDucking: 0.14,
                sideBase: 1.02,
                sideReduction: 0.34,
                crossfeedLowpassBaseHz: 520,
                crossfeedLowpassRangeHz: 700,
                crossfeedAlphaLimit: 0.24,
                earlyReflection1Seconds: 0.0022,
                earlyReflection2Seconds: 0.0048,
                earlyReflection1Mix: 0.011,
                earlyReflection1Range: 0.024,
                earlyReflection2Mix: 0.004,
                earlyReflection2Range: 0.012,
                centerPresenceHz: 3_350,
                centerPresenceQ: 0.66,
                centerPresenceGainDB: 2.5,
                centerPresenceRangeDB: 4.4,
                centerWarmthHz: 780,
                centerWarmthQ: 0.82,
                centerWarmthGainDB: 1.2,
                centerWarmthRangeDB: 1.5,
                sideShelfHz: 4_500,
                sideShelfSlope: 0.78,
                sideShelfCutDB: 2.4,
                sideShelfSpatialRangeDB: 3.4,
                sideShelfCrossfeedRangeDB: 2.0,
                lowMonoCutoffHz: 115,
                lowMonoAmount: 0.68
            )
        case .studio:
            return HeadphoneHRTFProfile(
                crossfeedDelaySeconds: 0.00031,
                crossfeedBase: 0.20,
                crossfeedRange: 0.26,
                directDucking: 0.18,
                sideBase: 0.98,
                sideReduction: 0.42,
                crossfeedLowpassBaseHz: 480,
                crossfeedLowpassRangeHz: 620,
                crossfeedAlphaLimit: 0.22,
                earlyReflection1Seconds: 0.0025,
                earlyReflection2Seconds: 0.0052,
                earlyReflection1Mix: 0.009,
                earlyReflection1Range: 0.020,
                earlyReflection2Mix: 0.003,
                earlyReflection2Range: 0.010,
                centerPresenceHz: 3_150,
                centerPresenceQ: 0.70,
                centerPresenceGainDB: 2.8,
                centerPresenceRangeDB: 4.0,
                centerWarmthHz: 700,
                centerWarmthQ: 0.86,
                centerWarmthGainDB: 0.9,
                centerWarmthRangeDB: 1.4,
                sideShelfHz: 4_100,
                sideShelfSlope: 0.72,
                sideShelfCutDB: 2.8,
                sideShelfSpatialRangeDB: 3.8,
                sideShelfCrossfeedRangeDB: 2.3,
                lowMonoCutoffHz: 125,
                lowMonoAmount: 0.78
            )
        }
    }

    nonisolated private static var shouldApplyHeadphoneVirtualization: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        return outputs.contains { output in
            switch output.portType {
            case .headphones, .bluetoothA2DP, .bluetoothLE, .bluetoothHFP:
                return true
            default:
                return false
            }
        }
    }

    // MARK: - Private: Buffer Scheduling

    /// Creates a view onto a range of an existing PCM buffer. The scheduled
    /// buffer retains the source allocation, but does not duplicate the rest of
    /// the song when playback starts or seeks from a non-zero position.
    private static func playbackSlice(
        from sourceBuffer: AVAudioPCMBuffer,
        startingFrame: AVAudioFramePosition,
        frameCount: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        guard startingFrame >= 0,
              frameCount > 0,
              UInt64(startingFrame) + UInt64(frameCount) <= UInt64(sourceBuffer.frameLength) else {
            return nil
        }
        if startingFrame == 0, frameCount == sourceBuffer.frameLength {
            return sourceBuffer
        }

        let format = sourceBuffer.format
        let bytesPerFrame = UInt64(format.streamDescription.pointee.mBytesPerFrame)
        guard bytesPerFrame > 0 else { return nil }
        let offsetResult = UInt64(startingFrame).multipliedReportingOverflow(by: bytesPerFrame)
        let lengthResult = UInt64(frameCount).multipliedReportingOverflow(by: bytesPerFrame)
        guard !offsetResult.overflow,
              !lengthResult.overflow,
              lengthResult.partialValue <= UInt64(UInt32.max) else {
            return nil
        }

        let sourceList = UnsafeMutableAudioBufferListPointer(sourceBuffer.mutableAudioBufferList)
        let sliceList = AudioBufferList.allocate(maximumBuffers: sourceList.count)
        sliceList.count = sourceList.count
        for index in sourceList.indices {
            let source = sourceList[index]
            guard let sourceData = source.mData,
                  offsetResult.partialValue + lengthResult.partialValue <= UInt64(source.mDataByteSize) else {
                sliceList.unsafeMutablePointer.deallocate()
                return nil
            }
            sliceList[index] = AudioBuffer(
                mNumberChannels: source.mNumberChannels,
                mDataByteSize: UInt32(lengthResult.partialValue),
                mData: sourceData.advanced(by: Int(offsetResult.partialValue))
            )
        }

        let retainedSource = sourceBuffer
        let allocatedList = sliceList.unsafeMutablePointer
        guard let slice = AVAudioPCMBuffer(
            pcmFormat: format,
            bufferListNoCopy: sliceList.unsafePointer,
            deallocator: { _ in
                _ = retainedSource
                allocatedList.deallocate()
            }
        ) else {
            allocatedList.deallocate()
            return nil
        }
        slice.frameLength = frameCount
        return slice
    }

    private func scheduleBuffer(from time: TimeInterval, autoplay: Bool) {
        guard let sourceBuffer = convertedBuffer, let playbackFormat = convertedFormat else {
            scheduleFastFile(from: time, autoplay: autoplay)
            return
        }

        playbackGeneration &+= 1
        let generation = playbackGeneration
        let node = activePlayerNode
        node.stop()
        node.reset()
        node.volume = 1.0
        playbackStartedAt = nil

        let sampleRate = playbackFormat.sampleRate
        let startFrame = AVAudioFramePosition(max(0, min(time * sampleRate, Double(sourceBuffer.frameLength))))
        let remainingFrames = max(AVAudioFramePosition(0), AVAudioFramePosition(sourceBuffer.frameLength) - startFrame)

        guard remainingFrames > 0 else {
            playbackOffset = duration
            onPlaybackEnded?()
            return
        }

        guard let playbackBuffer = Self.playbackSlice(
            from: sourceBuffer,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remainingFrames)
        ) else { return }

        playbackOffset = Double(startFrame) / sampleRate
        node.scheduleBuffer(
            playbackBuffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack,
            completionHandler: { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self, self.playbackGeneration == generation else { return }
                    self.playbackStartedAt = nil
                    self.playbackOffset = self.duration
                    self.onPlaybackEnded?()
                }
            }
        )

        if autoplay {
            renderHealthMonitor.beginMonitoring()
            node.play()
            playbackStartedAt = Date()
        }
    }

    private func scheduleFastFile(from time: TimeInterval, autoplay: Bool) {
        guard isFastFilePlayback, let audioFile = currentAudioFile else { return }

        playbackGeneration &+= 1
        let generation = playbackGeneration
        let node = activePlayerNode
        node.stop()
        node.reset()
        node.volume = 1.0
        playbackStartedAt = nil

        let clampedTime = min(max(0, time), duration)
        let startFrame = AVAudioFramePosition(clampedTime * audioFile.processingFormat.sampleRate)
        guard startFrame < audioFile.length else {
            playbackOffset = duration
            onPlaybackEnded?()
            return
        }

        // scheduleSegment remains file-backed at every seek position. The old
        // path decoded the entire remainder of the song into RAM after a pause
        // or seek, which could add hundreds of megabytes while audio was live.
        let remainingFrames = audioFile.length - startFrame
        guard remainingFrames > 0,
              remainingFrames <= AVAudioFramePosition(UInt32.max) else { return }
        playbackOffset = clampedTime
        node.scheduleSegment(
            audioFile,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remainingFrames),
            at: nil,
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.playbackStartedAt = nil
                self.playbackOffset = self.duration
                self.onPlaybackEnded?()
            }
        }

        if autoplay {
            renderHealthMonitor.beginMonitoring()
            node.play()
            playbackStartedAt = Date()
        }
    }

    // MARK: - Private: Buffer Conversion

    nonisolated private static func preparedAudioDiskCacheDirectory() -> URL? {
        preparedAudioDiskCacheRootDirectory()?
            .appendingPathComponent("v\(preparedAudioDiskCacheVersion)", isDirectory: true)
    }

    nonisolated private static func preparedAudioDiskCacheRootDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("OngakuPreparedAudio", isDirectory: true)
    }

    nonisolated private static func migratePreparedAudioDiskCacheIfNeeded() {
        preparedAudioDiskCacheMigrationLock.lock()
        defer { preparedAudioDiskCacheMigrationLock.unlock() }
        guard !didMigratePreparedAudioDiskCache else { return }
        didMigratePreparedAudioDiskCache = true

        guard let root = preparedAudioDiskCacheRootDirectory(),
              let entries = try? FileManager.default.contentsOfDirectory(
                  at: root,
                  includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles]
              ) else { return }
        let currentDirectoryName = "v\(preparedAudioDiskCacheVersion)"
        for entry in entries where entry.lastPathComponent.hasPrefix("v")
            && entry.lastPathComponent != currentDirectoryName {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    nonisolated private static func preparedAudioDiskCachePaths(
        url: URL,
        sourceFileSize: UInt64,
        sourceModificationTime: Int64,
        targetSampleRate: Double,
        upsamplingMode: UpsamplingMode,
        spatialSettings: HeadphoneSpatialSettings,
        spatialProcessingApplied: Bool
    ) -> PreparedAudioDiskCachePaths? {
        guard let directory = preparedAudioDiskCacheDirectory() else { return nil }
        let key = [
            sourceIdentityForCache(url),
            String(sourceFileSize),
            String(sourceModificationTime),
            String(Int(targetSampleRate.rounded())),
            upsamplingMode.rawValue,
            spatialSettings.preset.rawValue,
            String(Int((spatialSettings.spatial * 1_000).rounded())),
            String(Int((spatialSettings.crossfeed * 1_000).rounded())),
            spatialProcessingApplied ? "spatial" : "plain"
        ].joined(separator: "|")
        let identifier = String(Self.fnv1a64(key), radix: 16)
        return PreparedAudioDiskCachePaths(
            metadata: directory.appendingPathComponent("\(identifier).plist"),
            baseAudio: directory.appendingPathComponent("\(identifier).base.caf"),
            playbackAudio: directory.appendingPathComponent("\(identifier).playback.caf")
        )
    }

    nonisolated private static func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }

    nonisolated private static func readPCMBuffer(from url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        let frameCount = try checkedAudioFrameCount(
            file.length,
            format: file.processingFormat,
            failure: .sourceBufferFailed
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: frameCount
        ) else {
            throw HiResEngineError.sourceBufferFailed
        }
        try file.read(into: buffer, frameCount: frameCount)
        return buffer
    }

    nonisolated private static func writePCMBuffer(
        _ buffer: AVAudioPCMBuffer,
        to url: URL
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if manager.fileExists(atPath: url.path) {
            try manager.removeItem(at: url)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: buffer.format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let sourceChannels = buffer.floatChannelData else {
            throw HiResEngineError.upconvertFailed
        }
        let chunkCapacity = AVAudioFrameCount(65_536)
        guard let chunk = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: chunkCapacity
        ), let chunkChannels = chunk.floatChannelData else {
            throw HiResEngineError.upconvertBufferFailed
        }

        var offset = AVAudioFrameCount(0)
        while offset < buffer.frameLength {
            try Task.checkCancellation()
            let count = min(chunkCapacity, buffer.frameLength - offset)
            chunk.frameLength = count
            for channel in 0..<Int(buffer.format.channelCount) {
                chunkChannels[channel].update(
                    from: sourceChannels[channel].advanced(by: Int(offset)),
                    count: Int(count)
                )
            }
            try file.write(from: chunk)
            offset += count
        }
    }

    nonisolated private static func loadPreparedPlaybackDataFromDisk(
        sourceURL: URL,
        sourceAudioFile: AVAudioFile,
        sourceFileSize: UInt64,
        sourceModificationTime: Int64,
        expectedTargetFormat: AVAudioFormat,
        expectedUpsamplingMode: UpsamplingMode,
        spatialSettings: HeadphoneSpatialSettings,
        spatialProcessingApplied: Bool
    ) -> PreparedPlaybackData? {
        preparedAudioDiskCacheLock.lock()
        defer { preparedAudioDiskCacheLock.unlock() }
        guard let paths = preparedAudioDiskCachePaths(
            url: sourceURL,
            sourceFileSize: sourceFileSize,
            sourceModificationTime: sourceModificationTime,
            targetSampleRate: expectedTargetFormat.sampleRate,
            upsamplingMode: expectedUpsamplingMode,
            spatialSettings: spatialSettings,
            spatialProcessingApplied: spatialProcessingApplied
        ) else { return nil }

        do {
            let metadataData = try Data(contentsOf: paths.metadata)
            let metadata = try PropertyListDecoder().decode(
                PreparedAudioDiskCacheMetadata.self,
                from: metadataData
            )
            guard metadata.version == preparedAudioDiskCacheVersion,
                  metadata.sourceIdentity == sourceIdentityForCache(sourceURL),
                  metadata.sourceFileSize == sourceFileSize,
                  metadata.sourceModificationTime == sourceModificationTime,
                  metadata.upsamplingModeRaw == expectedUpsamplingMode.rawValue,
                  metadata.spatialProcessingApplied == spatialProcessingApplied,
                  abs(metadata.targetSampleRate - expectedTargetFormat.sampleRate) < 0.1,
                  metadata.targetChannelCount == expectedTargetFormat.channelCount else {
                throw HiResEngineError.upconvertFailed
            }

            try Task.checkCancellation()
            let baseBuffer = try readPCMBuffer(from: paths.baseAudio)
            let playbackBuffer = metadata.playbackSharesBase
                ? baseBuffer
                : try readPCMBuffer(from: paths.playbackAudio)
            guard baseBuffer.frameLength > 0,
                  playbackBuffer.frameLength > 0,
                  abs(playbackBuffer.format.sampleRate - expectedTargetFormat.sampleRate) < 0.1,
                  playbackBuffer.format.channelCount == expectedTargetFormat.channelCount else {
                throw HiResEngineError.upconvertFailed
            }

            let diagnostics = SignalLevelDiagnostics(
                sourcePeakDBFS: metadata.sourcePeakDBFS,
                sourceRMSDBFS: metadata.sourceRMSDBFS,
                sourceIntegratedLoudnessLUFS: metadata.sourceIntegratedLoudnessLUFS,
                recommendedInputTrimDB: metadata.recommendedInputTrimDB,
                inputHeadroomDB: metadata.inputHeadroomDB,
                outputTrimDB: metadata.outputTrimDB,
                fxHeadroomDB: metadata.fxHeadroomDB
            )
            let profile = AutomaticDSPProfile(
                lowShelfGainDB: metadata.lowShelfGainDB,
                lowMidGainDB: metadata.lowMidGainDB,
                presenceGainDB: metadata.presenceGainDB,
                highShelfGainDB: metadata.highShelfGainDB
            )
            let formatDescription = HiResPlaybackFormat(
                sampleRate: metadata.targetSampleRate,
                bitDepth: metadata.outputBitDepth,
                channels: metadata.targetChannelCount,
                sourceSampleRate: metadata.sourceSampleRate,
                sourceBitDepth: metadata.sourceBitDepth
            )
            let now = Date()
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: paths.metadata.path)
            try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: paths.baseAudio.path)
            if !metadata.playbackSharesBase {
                try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: paths.playbackAudio.path)
            }
            return PreparedPlaybackData(
                url: sourceURL,
                audioFile: sourceAudioFile,
                baseBuffer: baseBuffer,
                playbackBuffer: playbackBuffer,
                targetFormat: expectedTargetFormat,
                formatDescription: formatDescription,
                upsamplingMode: expectedUpsamplingMode,
                diagnostics: diagnostics,
                automaticDSPProfile: profile,
                analysisCacheHit: true,
                duration: Double(playbackBuffer.frameLength) / expectedTargetFormat.sampleRate
            )
        } catch is CancellationError {
            return nil
        } catch {
            removePreparedAudioDiskCacheEntry(paths)
            return nil
        }
    }

    nonisolated private static func storePreparedPlaybackDataOnDisk(
        _ prepared: PreparedPlaybackData,
        sourceFileSize: UInt64,
        sourceModificationTime: Int64,
        spatialSettings: HeadphoneSpatialSettings,
        spatialProcessingApplied: Bool
    ) {
        preparedAudioDiskCacheLock.lock()
        defer { preparedAudioDiskCacheLock.unlock() }
        guard let paths = preparedAudioDiskCachePaths(
            url: prepared.url,
            sourceFileSize: sourceFileSize,
            sourceModificationTime: sourceModificationTime,
            targetSampleRate: prepared.targetFormat.sampleRate,
            upsamplingMode: prepared.upsamplingMode,
            spatialSettings: spatialSettings,
            spatialProcessingApplied: spatialProcessingApplied
        ) else { return }

        do {
            try Task.checkCancellation()
            let sharesBase = prepared.baseBuffer === prepared.playbackBuffer
            try writePCMBuffer(prepared.baseBuffer, to: paths.baseAudio)
            if !sharesBase {
                try Task.checkCancellation()
                try writePCMBuffer(prepared.playbackBuffer, to: paths.playbackAudio)
            }
            let metadata = PreparedAudioDiskCacheMetadata(
                version: preparedAudioDiskCacheVersion,
                sourceIdentity: sourceIdentityForCache(prepared.url),
                sourceFileSize: sourceFileSize,
                sourceModificationTime: sourceModificationTime,
                upsamplingModeRaw: prepared.upsamplingMode.rawValue,
                spatialProcessingApplied: spatialProcessingApplied,
                playbackSharesBase: sharesBase,
                targetSampleRate: prepared.targetFormat.sampleRate,
                targetChannelCount: prepared.targetFormat.channelCount,
                sourceSampleRate: prepared.formatDescription.sourceSampleRate,
                sourceBitDepth: prepared.formatDescription.sourceBitDepth,
                outputBitDepth: prepared.formatDescription.bitDepth,
                sourcePeakDBFS: prepared.diagnostics.sourcePeakDBFS,
                sourceRMSDBFS: prepared.diagnostics.sourceRMSDBFS,
                sourceIntegratedLoudnessLUFS: prepared.diagnostics.sourceIntegratedLoudnessLUFS,
                recommendedInputTrimDB: prepared.diagnostics.recommendedInputTrimDB,
                inputHeadroomDB: prepared.diagnostics.inputHeadroomDB,
                outputTrimDB: prepared.diagnostics.outputTrimDB,
                fxHeadroomDB: prepared.diagnostics.fxHeadroomDB,
                lowShelfGainDB: prepared.automaticDSPProfile.lowShelfGainDB,
                lowMidGainDB: prepared.automaticDSPProfile.lowMidGainDB,
                presenceGainDB: prepared.automaticDSPProfile.presenceGainDB,
                highShelfGainDB: prepared.automaticDSPProfile.highShelfGainDB
            )
            let metadataData = try PropertyListEncoder().encode(metadata)
            try metadataData.write(to: paths.metadata, options: .atomic)
            trimPreparedAudioDiskCacheIfNeeded(in: paths.metadata.deletingLastPathComponent())
        } catch {
            removePreparedAudioDiskCacheEntry(paths)
        }
    }

    nonisolated private static func schedulePreparedPlaybackDataDiskStore(
        _ prepared: PreparedPlaybackData,
        sourceFileSize: UInt64,
        sourceModificationTime: Int64,
        spatialSettings: HeadphoneSpatialSettings,
        spatialProcessingApplied: Bool
    ) {
        preparedAudioDiskCacheTaskLock.lock()
        preparedAudioDiskCacheWriteTask?.cancel()
        preparedAudioDiskCacheWriteGeneration &+= 1
        let generation = preparedAudioDiskCacheWriteGeneration
        let task = Task.detached(priority: .background) {
            Self.storePreparedPlaybackDataOnDisk(
                prepared,
                sourceFileSize: sourceFileSize,
                sourceModificationTime: sourceModificationTime,
                spatialSettings: spatialSettings,
                spatialProcessingApplied: spatialProcessingApplied
            )
            Self.finishPreparedAudioDiskCacheWrite(generation: generation)
        }
        preparedAudioDiskCacheWriteTask = task
        preparedAudioDiskCacheTaskLock.unlock()
    }

    nonisolated private static func cancelPreparedAudioDiskCacheWrite() {
        preparedAudioDiskCacheTaskLock.lock()
        preparedAudioDiskCacheWriteGeneration &+= 1
        preparedAudioDiskCacheWriteTask?.cancel()
        preparedAudioDiskCacheWriteTask = nil
        preparedAudioDiskCacheTaskLock.unlock()
    }

    nonisolated private static func finishPreparedAudioDiskCacheWrite(generation: UInt64) {
        preparedAudioDiskCacheTaskLock.lock()
        if preparedAudioDiskCacheWriteGeneration == generation {
            preparedAudioDiskCacheWriteTask = nil
        }
        preparedAudioDiskCacheTaskLock.unlock()
    }

    nonisolated private static func removePreparedAudioDiskCacheEntry(
        _ paths: PreparedAudioDiskCachePaths
    ) {
        let manager = FileManager.default
        for url in [paths.metadata, paths.baseAudio, paths.playbackAudio] {
            try? manager.removeItem(at: url)
        }
    }

    nonisolated private static func trimPreparedAudioDiskCacheIfNeeded(in directory: URL) {
        let manager = FileManager.default
        guard let urls = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var grouped: [String: (urls: [URL], bytes: UInt64, date: Date)] = [:]
        for url in urls {
            let identifier = url.lastPathComponent.split(separator: ".").first.map(String.init) ?? ""
            guard !identifier.isEmpty,
                  let values = try? url.resourceValues(
                      forKeys: [.fileSizeKey, .contentModificationDateKey]
                  ) else { continue }
            var entry = grouped[identifier] ?? ([], 0, .distantPast)
            entry.urls.append(url)
            entry.bytes += UInt64(values.fileSize ?? 0)
            entry.date = max(entry.date, values.contentModificationDate ?? .distantPast)
            grouped[identifier] = entry
        }
        let entries = Array(grouped.values)
        var totalBytes = entries.reduce(UInt64(0)) { $0 + $1.bytes }
        guard totalBytes > maxPreparedAudioDiskCacheBytes else { return }
        for entry in entries.sorted(by: { $0.date < $1.date })
            where totalBytes > maxPreparedAudioDiskCacheBytes {
            for url in entry.urls {
                try? manager.removeItem(at: url)
            }
            totalBytes = totalBytes > entry.bytes ? totalBytes - entry.bytes : 0
        }
    }

    nonisolated private static func readPreparedAudioCacheStatistics() -> PreparedAudioCacheStatistics {
        migratePreparedAudioDiskCacheIfNeeded()
        preparedAudioDiskCacheLock.lock()
        defer { preparedAudioDiskCacheLock.unlock() }
        guard let directory = preparedAudioDiskCacheDirectory(),
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.fileSizeKey],
                  options: [.skipsHiddenFiles]
              ) else {
            return PreparedAudioCacheStatistics(
                byteCount: 0,
                entryCount: 0,
                maximumByteCount: maxPreparedAudioDiskCacheBytes
            )
        }
        var bytes: UInt64 = 0
        var identifiers = Set<String>()
        for url in urls {
            if let values = try? url.resourceValues(forKeys: [.fileSizeKey]) {
                bytes += UInt64(values.fileSize ?? 0)
            }
            if url.pathExtension == "plist" {
                identifiers.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        return PreparedAudioCacheStatistics(
            byteCount: bytes,
            entryCount: identifiers.count,
            maximumByteCount: maxPreparedAudioDiskCacheBytes
        )
    }

    nonisolated private static func removePreparedAudioDiskCache() {
        migratePreparedAudioDiskCacheIfNeeded()
        preparedAudioDiskCacheLock.lock()
        defer { preparedAudioDiskCacheLock.unlock() }
        guard let root = preparedAudioDiskCacheRootDirectory() else { return }
        try? FileManager.default.removeItem(at: root)
    }

    nonisolated private static func preparePlaybackData(
        url: URL,
        headphoneSpatialSettings: HeadphoneSpatialSettings,
        upsamplingMode: UpsamplingMode,
        skipDSPAnalysis: Bool = false
    ) throws -> PreparedPlaybackData {
        migratePreparedAudioDiskCacheIfNeeded()
        let audioFile = try AVAudioFile(forReading: url)
        let bitDepth = audioFile.fileFormat.streamDescription.pointee.mBitsPerChannel
        let sourceSampleRate = audioFile.fileFormat.sampleRate
        let targetSampleRate = skipDSPAnalysis ? sourceSampleRate : Self.resolvedProcessingSampleRate(for: sourceSampleRate)
        let targetChannelCount = max(AVAudioChannelCount(2), audioFile.processingFormat.channelCount)
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannelCount,
            interleaved: false
        )!
        let sourceSignature = Self.fileSignatureForCache(url: url)
        let spatialProcessingApplied = headphoneSpatialSettings.isEnabled
            && Self.shouldApplyHeadphoneVirtualization
            && targetChannelCount >= 2

        // A disk-cache hit still expands compressed CAF data into full-track
        // PCM allocations. Apply the same live-memory budget before reading it;
        // otherwise a cache hit could bypass the allocation guard used by a
        // fresh conversion and trigger jetsam during playback.
        let sourceLength = try Self.checkedAudioFrameCount(
            audioFile.length,
            format: audioFile.processingFormat,
            failure: .sourceBufferFailed
        )
        try Self.validateOfflineProcessingFootprint(
            sourceFrameCount: sourceLength,
            sourceFormat: audioFile.processingFormat,
            targetFormat: targetFormat,
            upsamplingMode: upsamplingMode
        )

        if upsamplingMode.isPrecisionSinc,
           !skipDSPAnalysis,
           let cached = Self.loadPreparedPlaybackDataFromDisk(
               sourceURL: url,
               sourceAudioFile: audioFile,
               sourceFileSize: sourceSignature.fileSize,
               sourceModificationTime: sourceSignature.modificationTime,
               expectedTargetFormat: targetFormat,
               expectedUpsamplingMode: upsamplingMode,
               spatialSettings: headphoneSpatialSettings,
               spatialProcessingApplied: spatialProcessingApplied
           ) {
            return cached
        }
        try Task.checkCancellation()

        let convertedBuffer = try Self.makePlaybackBuffer(
            from: audioFile,
            targetFormat: targetFormat,
            upsamplingMode: upsamplingMode
        )
        try Task.checkCancellation()
        if upsamplingMode.isPrecisionSinc {
            let remainingMemory = availableAudioProcessMemoryBytes()
            if remainingMemory > 0,
               remainingMemory < proactiveMemoryPressureThresholdBytes {
                throw HiResEngineError.offlineBufferTooLarge
            }
        }
        let needsSpatialProcessingCopy = spatialProcessingApplied
        let playbackBuffer: AVAudioPCMBuffer
        if needsSpatialProcessingCopy {
            // Preserve an unprocessed base only when spatial processing will
            // actually mutate samples. Otherwise both properties can safely
            // reference the same allocation, avoiding a full-song copy.
            playbackBuffer = try Self.clonePlaybackBuffer(from: convertedBuffer)
            Self.applyHeadphoneVirtualizationIfNeeded(
                to: playbackBuffer,
                settings: headphoneSpatialSettings
            )
        } else {
            playbackBuffer = convertedBuffer
        }
        if !skipDSPAnalysis {
            guard Self.isFiniteAudioBuffer(playbackBuffer) else {
                throw HiResEngineError.upconvertFailed
            }
        }
        let cacheKey = Self.makeAnalysisCacheKey(
            url: url,
            targetSampleRate: targetSampleRate,
            upsamplingMode: upsamplingMode,
            spatialSettings: headphoneSpatialSettings
        )
        let diagnostics: SignalLevelDiagnostics
        let automaticDSPProfile: AutomaticDSPProfile
        let cacheHit: Bool
        
        if skipDSPAnalysis {
            diagnostics = .init(
                sourcePeakDBFS: 0,
                sourceRMSDBFS: -14,
                sourceIntegratedLoudnessLUFS: -14,
                recommendedInputTrimDB: 0,
                inputHeadroomDB: 3,
                outputTrimDB: 0,
                fxHeadroomDB: 0
            )
            automaticDSPProfile = .neutral
            cacheHit = false
        } else if let cached = Self.cachedAnalysis(for: cacheKey) {
            diagnostics = cached.diagnostics
            automaticDSPProfile = cached.automaticDSPProfile
            cacheHit = true
        } else {
            diagnostics = Self.analyzeSignalLevels(in: playbackBuffer)
            automaticDSPProfile = Self.analyzeAutomaticDSP(in: playbackBuffer, diagnostics: diagnostics)
            Self.storeCachedAnalysis(.init(diagnostics: diagnostics, automaticDSPProfile: automaticDSPProfile), for: cacheKey)
            cacheHit = false
        }
        let duration = Double(playbackBuffer.frameLength) / targetFormat.sampleRate
        let formatDescription = HiResPlaybackFormat(
            sampleRate: targetSampleRate,
            bitDepth: max(bitDepth, 24),
            channels: targetFormat.channelCount,
            sourceSampleRate: sourceSampleRate,
            sourceBitDepth: bitDepth == 0 ? 32 : bitDepth
        )

        let prepared = PreparedPlaybackData(
            url: url,
            audioFile: audioFile,
            baseBuffer: convertedBuffer,
            playbackBuffer: playbackBuffer,
            targetFormat: targetFormat,
            formatDescription: formatDescription,
            upsamplingMode: upsamplingMode,
            diagnostics: diagnostics,
            automaticDSPProfile: automaticDSPProfile,
            analysisCacheHit: cacheHit,
            duration: duration
        )
        if upsamplingMode.isPrecisionSinc, !skipDSPAnalysis {
            Self.schedulePreparedPlaybackDataDiskStore(
                prepared,
                sourceFileSize: sourceSignature.fileSize,
                sourceModificationTime: sourceSignature.modificationTime,
                spatialSettings: headphoneSpatialSettings,
                spatialProcessingApplied: spatialProcessingApplied
            )
        }
        return prepared
    }

    nonisolated private static func preparePlaybackDataInWorker(
        url: URL,
        headphoneSpatialSettings: HeadphoneSpatialSettings,
        upsamplingMode: UpsamplingMode,
        skipDSPAnalysis: Bool = false,
        priority: TaskPriority
    ) async throws -> PreparedPlaybackData {
        let worker = Task.detached(priority: priority) {
            try Self.preparePlaybackData(
                url: url,
                headphoneSpatialSettings: headphoneSpatialSettings,
                upsamplingMode: upsamplingMode,
                skipDSPAnalysis: skipDSPAnalysis
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private func applyPreparedPlaybackData(
        _ prepared: PreparedPlaybackData,
        effectSettings: [RealtimeAudioEffectSetting]
    ) throws {
        stop()
        currentAudioFile = prepared.audioFile
        currentAudioURL = prepared.url
        playbackOffset = 0
        let currentSession = AVAudioSession.sharedInstance()
        if abs(currentSession.sampleRate - prepared.targetFormat.sampleRate) > 0.1 || currentSession.category != .playback {
            try configureAudioSession(preferredSampleRate: prepared.targetFormat.sampleRate)
        }
        
        baseConvertedBuffer = prepared.baseBuffer
        convertedBuffer = prepared.playbackBuffer
        convertedFormat = prepared.targetFormat
        signalDiagnostics = prepared.diagnostics
        automaticDSPProfile = prepared.automaticDSPProfile
        lastAutomaticDSPCacheHit = prepared.analysisCacheHit
        currentUpsamplingMode = prepared.upsamplingMode
        applyAutomaticDSPProfile(prepared.automaticDSPProfile)
        duration = prepared.duration
        estimatedPipelineLatencyFrames = effectPipeline.reduce(0) { $0 + $1.estimatedLatencyFrames }
        configureProcessingFormat(prepared.targetFormat)
        currentFormat = prepared.formatDescription
        apply(effectSettings: effectSettings)
        try ensureEngineRunning()
        scheduleBuffer(from: 0, autoplay: false)
    }

    private func crossfadeToPreparedPlaybackData(
        _ prepared: PreparedPlaybackData,
        effectSettings: [RealtimeAudioEffectSetting],
        resumeTime: TimeInterval,
        evaluationTime: Date? = nil,
        shouldResume: Bool
    ) throws {
        let oldNode = activePlayerNode
        let newNode = isUpgradePlayerNodeActive ? playerNode : upgradePlayerNode
        let wasPlaying = oldNode.isPlaying

        // The user instructed: "通常音質プレーヤーと高音質プレーヤーは、最初の通常音質再生時には両方用意しておいてください。
        // 高音質のデータが整い次第、再生中の場所からフェードインするだけです。"
        // Since loadFastFile already configures the engine to the highest required processing format,
        // we DO NOT need to call configureAudioSession or configureProcessingFormat here.
        // Calling them mid-playback causes severe audio interruption/silence when hardware rejects the sample rate.
        currentAudioFile = prepared.audioFile
        currentAudioURL = prepared.url
        baseConvertedBuffer = prepared.baseBuffer
        convertedBuffer = prepared.playbackBuffer
        convertedFormat = prepared.targetFormat
        signalDiagnostics = prepared.diagnostics
        automaticDSPProfile = prepared.automaticDSPProfile
        lastAutomaticDSPCacheHit = prepared.analysisCacheHit
        currentUpsamplingMode = prepared.upsamplingMode
        applyAutomaticDSPProfile(prepared.automaticDSPProfile)
        duration = prepared.duration
        estimatedPipelineLatencyFrames = effectPipeline.reduce(0) { $0 + $1.estimatedLatencyFrames }
        currentFormat = prepared.formatDescription
        apply(effectSettings: effectSettings)

        let adjustedResumeTime: TimeInterval
        if let evalTime = evaluationTime, wasPlaying {
            // Engine did NOT stop. Audio kept advancing. Add elapsed time to stay perfectly synced!
            let elapsed = Date().timeIntervalSince(evalTime)
            adjustedResumeTime = resumeTime + elapsed
        } else {
            adjustedResumeTime = resumeTime
        }

        oldNode.volume = 1.0
        newNode.volume = 0.0
        try schedulePreparedBuffer(prepared.playbackBuffer, from: adjustedResumeTime, on: newNode)
        let crossfadeGeneration = playbackGeneration
        try ensureEngineRunning()
        if shouldResume {
            newNode.play()
        }

        // The replacement is already running before the old node is stopped.
        // A short gain crossfade prevents a click without creating silence.
        let steps = 16
        for step in 1...steps {
            let progress = Float(step) / Float(steps)
            let oldGain = 1.0 - progress
            let newGain = progress
            let delay = 0.004 * Double(step)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self, weak oldNode, weak newNode] in
                guard let self,
                      self.playbackGeneration == crossfadeGeneration,
                      let oldNode,
                      let newNode else { return }
                oldNode.volume = oldGain
                newNode.volume = newGain
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.064) { [weak self, weak oldNode] in
            guard let self,
                  self.playbackGeneration == crossfadeGeneration,
                  let oldNode else { return }
            oldNode.stop()
            oldNode.reset()
            oldNode.volume = 1.0 // Reset volume for next use
        }
        isUpgradePlayerNodeActive.toggle()
        playbackOffset = min(max(0, adjustedResumeTime), duration)
        playbackStartedAt = shouldResume ? Date() : nil
    }

    private func schedulePreparedBuffer(
        _ sourceBuffer: AVAudioPCMBuffer,
        from time: TimeInterval,
        on node: AVAudioPlayerNode
    ) throws {
        let sampleRate = sourceBuffer.format.sampleRate
        let startFrame = AVAudioFramePosition(max(0, min(time * sampleRate, Double(sourceBuffer.frameLength))))
        let remainingFrames = max(AVAudioFramePosition(0), AVAudioFramePosition(sourceBuffer.frameLength) - startFrame)
        guard remainingFrames > 0 else { return }
        guard let buffer = Self.playbackSlice(
            from: sourceBuffer,
            startingFrame: startFrame,
            frameCount: AVAudioFrameCount(remainingFrames)
        ) else { throw HiResEngineError.upconvertBufferFailed }

        playbackGeneration &+= 1
        let generation = playbackGeneration
        node.stop()
        node.reset()
        node.scheduleBuffer(
            buffer,
            at: nil,
            options: [],
            completionCallbackType: .dataPlayedBack
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, self.playbackGeneration == generation else { return }
                self.playbackStartedAt = nil
                self.playbackOffset = self.duration
                self.onPlaybackEnded?()
            }
        }
    }

    nonisolated private static func makePlaybackBuffer(
        from audioFile: AVAudioFile,
        targetFormat: AVAudioFormat,
        upsamplingMode: UpsamplingMode
    ) throws -> AVAudioPCMBuffer {
        let sourceFormat = audioFile.processingFormat
        let sourceLength = try Self.checkedAudioFrameCount(
            audioFile.length,
            format: sourceFormat,
            failure: .sourceBufferFailed
        )

        try Self.validateOfflineProcessingFootprint(
            sourceFrameCount: sourceLength,
            sourceFormat: sourceFormat,
            targetFormat: targetFormat,
            upsamplingMode: upsamplingMode
        )

        let isSameFormat =
            abs(sourceFormat.sampleRate - targetFormat.sampleRate) < 0.0001 &&
            sourceFormat.channelCount == targetFormat.channelCount &&
            sourceFormat.commonFormat == targetFormat.commonFormat &&
            sourceFormat.isInterleaved == targetFormat.isInterleaved

        switch upsamplingMode {
        case .avAudioConverter:
            guard let sourceBuffer = AVAudioPCMBuffer(
                pcmFormat: sourceFormat,
                frameCapacity: sourceLength
            ) else {
                throw HiResEngineError.sourceBufferFailed
            }
            try audioFile.read(into: sourceBuffer)
            if isSameFormat { return sourceBuffer }
            return try Self.convertBuffer(sourceBuffer, from: sourceFormat, to: targetFormat)
        case .precisionSincLinearEco,
             .precisionSincLinear,
             .precisionSincLinearMaster,
             .precisionSincMinimumPhaseEco,
             .precisionSincMinimumPhase,
             .precisionSincMinimumPhaseMaster,
             .precisionSincApodizingEco,
             .precisionSincApodizing,
             .precisionSincApodizingMaster,
             .precisionSinc:
            if isSameFormat {
                guard let sourceBuffer = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: sourceLength
                ) else {
                    throw HiResEngineError.sourceBufferFailed
                }
                try audioFile.read(into: sourceBuffer)
                return sourceBuffer
            }
            return try Self.makeChunkedPrecisionSincPlaybackBuffer(
                from: audioFile,
                sourceFrameCount: sourceLength,
                sourceFormat: sourceFormat,
                targetFormat: targetFormat,
                phaseMode: upsamplingMode.precisionSincPhaseMode ?? .apodizing,
                qualityMode: upsamplingMode.precisionSincQualityMode ?? .standard
            )
        }
    }

    /// Reads only the source frames needed for each output window. The final
    /// buffer remains contiguous for a click-free player-node handoff, while
    /// the full decoded source and normalized intermediate buffers no longer
    /// coexist in memory.
    nonisolated private static func makeChunkedPrecisionSincPlaybackBuffer(
        from audioFile: AVAudioFile,
        sourceFrameCount: AVAudioFrameCount,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        phaseMode: PrecisionSincPhaseMode,
        qualityMode: PrecisionSincQualityMode
    ) throws -> AVAudioPCMBuffer {
        let sourceRate = sourceFormat.sampleRate
        let targetRate = targetFormat.sampleRate
        guard sourceRate > 0, targetRate > 0 else {
            throw HiResEngineError.upconvertFailed
        }
        let ratio = targetRate / sourceRate
        let outputCapacity = try checkedAudioFrameCount(
            (Double(sourceFrameCount) * ratio).rounded(.up),
            format: targetFormat,
            failure: .upconvertBufferFailed
        )
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ), let outputChannels = outputBuffer.floatChannelData else {
            throw HiResEngineError.upconvertBufferFailed
        }

        let intermediateFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceRate,
            channels: targetFormat.channelCount,
            interleaved: false
        )!
        let kernelProfile = qualityMode.sincKernelProfile
        let kernelRadius = kernelProfile.radius
        let kernelSize = kernelRadius * 2 + 1
        let numPhases = kernelProfile.numPhases
        let cutoff = Float(min(1.0, targetRate / sourceRate) * Double(phaseMode.cutoffScale))
        let kernels = cachedPolyphaseSincKernels(
            cutoff: cutoff,
            kernelRadius: kernelRadius,
            kernelSize: kernelSize,
            numPhases: numPhases,
            phaseMode: phaseMode,
            qualityMode: qualityMode
        )
        let outputFrameCount = Int(outputCapacity)
        let sourceTotalFrames = Int(sourceFrameCount)
        let outputChunkFrames = 262_144

        try kernels.withUnsafeBufferPointer { kernelBuffer in
            guard let kernelBaseAddress = kernelBuffer.baseAddress else {
                throw HiResEngineError.upconvertFailed
            }
            var outputStart = 0
            while outputStart < outputFrameCount {
                try Task.checkCancellation()
                let remainingMemory = availableAudioProcessMemoryBytes()
                if remainingMemory > 0,
                   remainingMemory < proactiveMemoryPressureThresholdBytes {
                    throw HiResEngineError.offlineBufferTooLarge
                }
                let outputCount = min(outputChunkFrames, outputFrameCount - outputStart)
                let firstSourcePosition = Double(outputStart) / ratio
                let lastSourcePosition = Double(outputStart + outputCount - 1) / ratio
                let sourceReadStart = max(0, Int(firstSourcePosition.rounded(.down)) - kernelRadius)
                let sourceReadEnd = min(
                    sourceTotalFrames,
                    Int(lastSourcePosition.rounded(.down)) + kernelRadius + 1
                )
                let sourceReadCount = max(1, sourceReadEnd - sourceReadStart)
                let chunkStartedAt = CFAbsoluteTimeGetCurrent()
                let sourceChunkCapacity = try checkedAudioFrameCount(
                    Double(sourceReadCount),
                    format: sourceFormat,
                    failure: .sourceBufferFailed
                )
                guard let sourceChunk = AVAudioPCMBuffer(
                    pcmFormat: sourceFormat,
                    frameCapacity: sourceChunkCapacity
                ) else {
                    throw HiResEngineError.sourceBufferFailed
                }
                audioFile.framePosition = AVAudioFramePosition(sourceReadStart)
                try audioFile.read(into: sourceChunk, frameCount: sourceChunkCapacity)
                let normalizedChunk = try normalizePrecisionSincSourceChunk(
                    sourceChunk,
                    sourceFormat: sourceFormat,
                    intermediateFormat: intermediateFormat
                )
                guard let sourceChannels = normalizedChunk.floatChannelData else {
                    throw HiResEngineError.upconvertFailed
                }

                try withExtendedLifetime(normalizedChunk) {
                    for channel in 0..<Int(targetFormat.channelCount) {
                        try renderSincChunk(
                            source: sourceChannels[channel],
                            sourceFrameCount: Int(normalizedChunk.frameLength),
                            sourceFrameOffset: sourceReadStart,
                            output: outputChannels[channel].advanced(by: outputStart),
                            outputStartFrame: outputStart,
                            outputFrameCount: outputCount,
                            kernels: kernelBaseAddress,
                            ratio: ratio,
                            kernelRadius: kernelRadius,
                            kernelSize: kernelSize,
                            numPhases: numPhases
                        )
                    }
                }
                outputStart += outputCount
                try cooperativelyThrottleOfflineProcessing(
                    workDuration: CFAbsoluteTimeGetCurrent() - chunkStartedAt
                )
            }
        }
        outputBuffer.frameLength = outputCapacity
        return outputBuffer
    }

    /// Custom polyphase Sinc is intentionally CPU intensive. Running it at full
    /// speed for every song can exceed iOS's sustained CPU budget even when
    /// memory remains plentiful. Limit the worker to roughly 25% duty while
    /// keeping cancellation latency short.
    nonisolated private static func cooperativelyThrottleOfflineProcessing(
        workDuration: TimeInterval
    ) throws {
        guard workDuration.isFinite, workDuration > 0 else { return }
        var remainingDelay = workDuration * 3.0
        while remainingDelay > 0 {
            try Task.checkCancellation()
            let interval = min(0.020, remainingDelay)
            Thread.sleep(forTimeInterval: interval)
            remainingDelay -= interval
        }
    }

    nonisolated private static func normalizePrecisionSincSourceChunk(
        _ sourceBuffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat,
        intermediateFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        if sourceFormat.commonFormat == .pcmFormatFloat32,
           !sourceFormat.isInterleaved,
           sourceFormat.channelCount == intermediateFormat.channelCount {
            return sourceBuffer
        }
        if sourceFormat.commonFormat == .pcmFormatFloat32,
           !sourceFormat.isInterleaved,
           sourceFormat.channelCount == 1,
           intermediateFormat.channelCount == 2,
           let source = sourceBuffer.floatChannelData {
            guard let normalized = AVAudioPCMBuffer(
                pcmFormat: intermediateFormat,
                frameCapacity: sourceBuffer.frameLength
            ), let target = normalized.floatChannelData else {
                throw HiResEngineError.upconvertBufferFailed
            }
            normalized.frameLength = sourceBuffer.frameLength
            let count = Int(sourceBuffer.frameLength)
            target[0].update(from: source[0], count: count)
            target[1].update(from: source[0], count: count)
            return normalized
        }
        return try convertBuffer(
            sourceBuffer,
            from: sourceFormat,
            to: intermediateFormat
        )
    }

    nonisolated private static func renderSincChunk(
        source: UnsafePointer<Float>,
        sourceFrameCount: Int,
        sourceFrameOffset: Int,
        output: UnsafeMutablePointer<Float>,
        outputStartFrame: Int,
        outputFrameCount: Int,
        kernels: UnsafePointer<Float>,
        ratio: Double,
        kernelRadius: Int,
        kernelSize: Int,
        numPhases: Int
    ) throws {
        var edgeSamples = [Float](repeating: 0, count: kernelSize)
        for localOutputIndex in 0..<outputFrameCount {
            if localOutputIndex & 0x3FF == 0 {
                try Task.checkCancellation()
            }
            let globalOutputIndex = outputStartFrame + localOutputIndex
            let sourcePosition = Double(globalOutputIndex) / ratio
            let globalCenter = Int(sourcePosition)
            let localCenter = globalCenter - sourceFrameOffset
            let fractional = sourcePosition - Double(globalCenter)
            let phaseIndex = Int(min(
                Double(numPhases - 1),
                max(0, fractional * Double(numPhases))
            ))
            let kernel = kernels.advanced(by: phaseIndex * kernelSize)
            let startIndex = localCenter - kernelRadius
            var result: Float = 0
            if startIndex >= 0, startIndex + kernelSize <= sourceFrameCount {
                vDSP_dotpr(
                    kernel,
                    1,
                    source.advanced(by: startIndex),
                    1,
                    &result,
                    vDSP_Length(kernelSize)
                )
            } else {
                for kernelIndex in 0..<kernelSize {
                    let sampleIndex = startIndex + kernelIndex
                    edgeSamples[kernelIndex] = sampleIndex >= 0 && sampleIndex < sourceFrameCount
                        ? source[sampleIndex]
                        : 0
                }
                vDSP_dotpr(
                    kernel,
                    1,
                    edgeSamples,
                    1,
                    &result,
                    vDSP_Length(kernelSize)
                )
            }
            output[localOutputIndex] = result
        }
    }

    nonisolated private static func convertBuffer(
        _ sourceBuffer: AVAudioPCMBuffer,
        from sourceFormat: AVAudioFormat,
        to targetFormat: AVAudioFormat
    ) throws -> AVAudioPCMBuffer {
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        guard ratio.isFinite, ratio > 0 else {
            throw HiResEngineError.upconvertFailed
        }
        let outputCapacity = try Self.checkedAudioFrameCount(
            (Double(sourceBuffer.frameLength) * ratio).rounded(.up) + 1024,
            format: targetFormat,
            failure: .upconvertBufferFailed
        )
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw HiResEngineError.upconvertBufferFailed
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw HiResEngineError.upconvertFailed
        }
        var inputConsumed = false

        nonisolated(unsafe) let unsafeSourceBuffer = sourceBuffer
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if inputConsumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputConsumed = true
            outStatus.pointee = .haveData
            return unsafeSourceBuffer
        }

        if conversionError != nil {
            throw HiResEngineError.upconvertFailed
        }
        guard status == .haveData || status == .endOfStream else {
            throw HiResEngineError.upconvertFailed
        }

        return outputBuffer
    }

    nonisolated private static func makePrecisionSincPlaybackBuffer(
        from sourceBuffer: AVAudioPCMBuffer,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        phaseMode: PrecisionSincPhaseMode,
        qualityMode: PrecisionSincQualityMode
    ) throws -> AVAudioPCMBuffer {
        let intermediateFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sourceFormat.sampleRate,
            channels: targetFormat.channelCount,
            interleaved: false
        )!

        let intermediateBuffer: AVAudioPCMBuffer
        let alreadyNormalized =
            sourceFormat.commonFormat == intermediateFormat.commonFormat &&
            sourceFormat.channelCount == intermediateFormat.channelCount &&
            sourceFormat.isInterleaved == intermediateFormat.isInterleaved &&
            abs(sourceFormat.sampleRate - intermediateFormat.sampleRate) < 0.0001

        if alreadyNormalized {
            intermediateBuffer = sourceBuffer
        } else {
            intermediateBuffer = try Self.convertBuffer(sourceBuffer, from: sourceFormat, to: intermediateFormat)
        }

        return try Self.resampleBufferWithWindowedSinc(
            intermediateBuffer,
            to: targetFormat,
            phaseMode: phaseMode,
            qualityMode: qualityMode
        )
    }

    nonisolated private static func resampleBufferWithWindowedSinc(
        _ sourceBuffer: AVAudioPCMBuffer,
        to targetFormat: AVAudioFormat,
        phaseMode: PrecisionSincPhaseMode,
        qualityMode: PrecisionSincQualityMode
    ) throws -> AVAudioPCMBuffer {
        let sourceRate = sourceBuffer.format.sampleRate
        let targetRate = targetFormat.sampleRate
        guard sourceRate > 0, targetRate > 0 else {
            throw HiResEngineError.upconvertFailed
        }
        let ratio = targetRate / sourceRate
        let sourceFrameCount = Int(sourceBuffer.frameLength)
        guard sourceFrameCount > 0 else {
            throw HiResEngineError.upconvertFailed
        }
        let rawOutputFrameCount = (Double(sourceFrameCount) * ratio).rounded(.up)
        let outputCapacity = try Self.checkedAudioFrameCount(
            max(1, rawOutputFrameCount),
            format: targetFormat,
            failure: .upconvertBufferFailed
        )
        let outputFrameCount = Int(outputCapacity)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputCapacity
        ) else {
            throw HiResEngineError.upconvertBufferFailed
        }

        guard let sourceChannels = sourceBuffer.floatChannelData,
              let outputChannels = outputBuffer.floatChannelData else {
            throw HiResEngineError.upconvertFailed
        }

        let channelCount = Int(targetFormat.channelCount)
        guard channelCount > 0,
              sourceBuffer.format.channelCount == targetFormat.channelCount,
              sourceBuffer.format.commonFormat == .pcmFormatFloat32,
              targetFormat.commonFormat == .pcmFormatFloat32,
              !sourceBuffer.format.isInterleaved,
              !targetFormat.isInterleaved else {
            throw HiResEngineError.upconvertFailed
        }

        let cutoff = Float(min(1.0, targetRate / sourceRate) * Double(phaseMode.cutoffScale))
        let kernelProfile = qualityMode.sincKernelProfile
        let kernelRadius = kernelProfile.radius
        let kernelSize = kernelRadius * 2 + 1
        let numPhases = kernelProfile.numPhases
        let polyphaseKernels = Self.cachedPolyphaseSincKernels(
            cutoff: cutoff,
            kernelRadius: kernelRadius,
            kernelSize: kernelSize,
            numPhases: numPhases,
            phaseMode: phaseMode,
            qualityMode: qualityMode
        )

        try polyphaseKernels.withUnsafeBufferPointer { kernelBuffer in
            guard let kernelBaseAddress = kernelBuffer.baseAddress else {
                throw HiResEngineError.upconvertFailed
            }

            try withExtendedLifetime(sourceBuffer) {
                try withExtendedLifetime(outputBuffer) {
                    for channel in 0..<channelCount {
                        try Self.renderSincChannel(
                            source: sourceChannels[channel],
                            output: outputChannels[channel],
                            kernels: kernelBaseAddress,
                            sourceFrameCount: sourceFrameCount,
                            outputFrameCount: outputFrameCount,
                            ratio: ratio,
                            kernelRadius: kernelRadius,
                            kernelSize: kernelSize,
                            numPhases: numPhases
                        )
                    }
                }
            }
        }

        outputBuffer.frameLength = AVAudioFrameCount(outputFrameCount)
        return outputBuffer
    }

    nonisolated private static func renderSincChannel(
        source: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        kernels: UnsafePointer<Float>,
        sourceFrameCount: Int,
        outputFrameCount: Int,
        ratio: Double,
        kernelRadius: Int,
        kernelSize: Int,
        numPhases: Int
    ) throws {
        var edgeSamples = [Float](repeating: 0, count: kernelSize)
        var sourcePosition = 0.0
        let positionStep = 1.0 / ratio

        for outputIndex in 0..<outputFrameCount {
            if outputIndex & 0x3FFF == 0 {
                try Task.checkCancellation()
            }
            let center = Int(sourcePosition)
            let fractional = sourcePosition - Double(center)
            let phaseIndex = Int(min(Double(numPhases - 1), max(0, fractional * Double(numPhases))))
            let kernel = kernels.advanced(by: phaseIndex * kernelSize)
            let startIndex = center - kernelRadius

            var result: Float = 0
            if startIndex >= 0 && (startIndex + kernelSize) <= sourceFrameCount {
                vDSP_dotpr(kernel, 1, source.advanced(by: startIndex), 1, &result, vDSP_Length(kernelSize))
            } else {
                for kernelIndex in 0..<kernelSize {
                    let sampleIndex = startIndex + kernelIndex
                    edgeSamples[kernelIndex] = (sampleIndex >= 0 && sampleIndex < sourceFrameCount) ? source[sampleIndex] : 0
                }
                vDSP_dotpr(kernel, 1, edgeSamples, 1, &result, vDSP_Length(kernelSize))
            }

            output[outputIndex] = result
            sourcePosition += positionStep
        }
    }

    nonisolated private static func checkedAudioFrameCount(
        _ frameCount: AVAudioFramePosition,
        format: AVAudioFormat,
        failure: HiResEngineError
    ) throws -> AVAudioFrameCount {
        guard frameCount >= 0 else {
            throw failure
        }
        return try checkedAudioFrameCount(Double(frameCount), format: format, failure: failure)
    }

    nonisolated private static func checkedAudioFrameCount(
        _ frameCount: Double,
        format: AVAudioFormat,
        failure: HiResEngineError
    ) throws -> AVAudioFrameCount {
        guard frameCount.isFinite, frameCount >= 0, frameCount <= Double(UInt32.max) else {
            throw failure
        }

        let roundedFrameCount = UInt32(frameCount.rounded(.up))
        try validateOfflineBufferFootprint(frameCount: roundedFrameCount, format: format)
        return AVAudioFrameCount(roundedFrameCount)
    }

    nonisolated private static func validateOfflineBufferFootprint(
        frameCount: AVAudioFrameCount,
        format: AVAudioFormat
    ) throws {
        let streamDescription = format.streamDescription.pointee
        let bytesPerFrame = max(1, UInt64(streamDescription.mBytesPerFrame))
        let channelMultiplier = format.isInterleaved ? UInt64(1) : max(1, UInt64(format.channelCount))
        let frameByteWidth = bytesPerFrame.multipliedReportingOverflow(by: channelMultiplier)
        guard !frameByteWidth.overflow else {
            throw HiResEngineError.offlineBufferTooLarge
        }

        let byteCount = UInt64(frameCount).multipliedReportingOverflow(by: frameByteWidth.partialValue)
        guard !byteCount.overflow else {
            throw HiResEngineError.offlineBufferTooLarge
        }

        guard byteCount.partialValue <= maxOfflinePlaybackBufferBytes else {
            throw HiResEngineError.offlineBufferTooLarge
        }
    }

    nonisolated private static func validateOfflineProcessingFootprint(
        sourceFrameCount: AVAudioFrameCount,
        sourceFormat: AVAudioFormat,
        targetFormat: AVAudioFormat,
        upsamplingMode: UpsamplingMode
    ) throws {
        let sourceBytes = estimatedBufferBytes(frameCount: sourceFrameCount, format: sourceFormat)
        let ratio = targetFormat.sampleRate / max(sourceFormat.sampleRate, 1.0)
        let targetFrames = Double(sourceFrameCount) * max(ratio, 1.0)
        guard targetFrames.isFinite, targetFrames <= Double(UInt32.max) else {
            throw HiResEngineError.offlineBufferTooLarge
        }

        let targetFrameCount = AVAudioFrameCount(targetFrames.rounded(.up))
        let targetBytes = estimatedBufferBytes(frameCount: targetFrameCount, format: targetFormat)
        let normalizedSourceBytes = sourceFormat.commonFormat == .pcmFormatFloat32
            ? sourceBytes
            : estimatedBufferBytes(frameCount: sourceFrameCount, format: AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceFormat.sampleRate,
                channels: sourceFormat.channelCount,
                interleaved: false
            )!)
        let estimatedPeakBytes: UInt64
        if upsamplingMode.isPrecisionSinc {
            // Chunked Sinc keeps only a small decoded/normalized source
            // window alongside the final output and an optional spatial copy.
            let sourceWindowReserve = min(sourceBytes, 32 * 1_024 * 1_024)
            let normalizedWindowReserve = min(normalizedSourceBytes, 32 * 1_024 * 1_024)
            let first = targetBytes.addingReportingOverflow(targetBytes)
            let second = first.partialValue.addingReportingOverflow(targetBytes)
            let third = second.partialValue.addingReportingOverflow(sourceWindowReserve)
            let fourth = third.partialValue.addingReportingOverflow(normalizedWindowReserve)
            guard !first.overflow, !second.overflow, !third.overflow, !fourth.overflow else {
                throw HiResEngineError.offlineBufferTooLarge
            }
            estimatedPeakBytes = fourth.partialValue
        } else {
            let first = sourceBytes.addingReportingOverflow(normalizedSourceBytes)
            let second = first.partialValue.addingReportingOverflow(targetBytes)
            guard !first.overflow, !second.overflow else {
                throw HiResEngineError.offlineBufferTooLarge
            }
            estimatedPeakBytes = second.partialValue
        }
        guard estimatedPeakBytes <= maxOfflinePlaybackBufferBytes else {
            throw HiResEngineError.offlineBufferTooLarge
        }

        // Device RAM is not the same as the memory limit currently available
        // to this process. Check the live dirty-memory allowance immediately
        // before allocating a full-track PCM buffer, and retain a large reserve
        // for AVAudioEngine, artwork, the media library and transient system
        // allocations. A zero value means the platform cannot provide a useful
        // process limit (for example, some non-app test environments).
        let availableMemory = availableAudioProcessMemoryBytes()
        if availableMemory > 0 {
            let adaptiveReserve = min(
                maximumProcessMemoryReserveBytes,
                max(minimumProcessMemoryReserveBytes, availableMemory / 2)
            )
            let allocationBudget = availableMemory > adaptiveReserve
                ? availableMemory - adaptiveReserve
                : 0
            guard estimatedPeakBytes <= allocationBudget else {
                throw HiResEngineError.offlineBufferTooLarge
            }
        }
    }

    nonisolated private static func estimatedBufferBytes(
        frameCount: AVAudioFrameCount,
        format: AVAudioFormat
    ) -> UInt64 {
        let description = format.streamDescription.pointee
        let bytesPerSample = max(4, Int(description.mBitsPerChannel / 8))
        let channelCount = max(1, Int(format.channelCount))
        let bytes = UInt64(frameCount)
            .multipliedReportingOverflow(by: UInt64(bytesPerSample * channelCount))
        return bytes.overflow ? UInt64.max : bytes.partialValue
    }

    nonisolated private static func canAllocatePlaybackCopy(of buffer: AVAudioPCMBuffer) -> Bool {
        let requiredBytes = estimatedBufferBytes(
            frameCount: buffer.frameLength,
            format: buffer.format
        )
        guard requiredBytes != UInt64.max else { return false }
        let availableMemory = availableAudioProcessMemoryBytes()
        guard availableMemory > 0 else { return true }
        guard availableMemory > minimumProcessMemoryReserveBytes else { return false }
        return requiredBytes <= availableMemory - minimumProcessMemoryReserveBytes
    }

    nonisolated private static func isFiniteAudioBuffer(_ buffer: AVAudioPCMBuffer) -> Bool {
        guard let channelData = buffer.floatChannelData else { return false }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return false }

        for channel in 0..<channelCount {
            for frame in 0..<frameCount {
                if frame & 0x3FFF == 0, Task.isCancelled {
                    return false
                }
                let sample = channelData[channel][frame]
                guard sample.isFinite, abs(sample) <= 8.0 else { return false }
            }
        }
        return true
    }

    nonisolated private static func cachedPolyphaseSincKernels(
        cutoff: Float,
        kernelRadius: Int,
        kernelSize: Int,
        numPhases: Int,
        phaseMode: PrecisionSincPhaseMode,
        qualityMode: PrecisionSincQualityMode
    ) -> [Float] {
        let key = SincKernelCacheKey(
            kernelSize: kernelSize,
            numPhases: numPhases,
            cutoffMilli: Int((cutoff * 1000).rounded()),
            phaseMode: phaseMode,
            qualityMode: qualityMode
        )

        sincKernelCacheLock.lock()
        if let cached = sincKernelCache[key] {
            sincKernelCacheLock.unlock()
            return cached
        }
        sincKernelCacheLock.unlock()

        var kernels = [Float](repeating: 0, count: numPhases * kernelSize)

        let minimumPhaseFFTSize = max(2, 1 << Int(ceil(log2(Double(kernelSize * 2)))))
        let minimumPhaseForwardSetup = phaseMode == .minimumPhase
            ? vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(minimumPhaseFFTSize), .FORWARD)
            : nil
        let minimumPhaseInverseSetup = phaseMode == .minimumPhase
            ? vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(minimumPhaseFFTSize), .INVERSE)
            : nil
        defer {
            if let setup = minimumPhaseForwardSetup { vDSP_DFT_DestroySetup(setup) }
            if let setup = minimumPhaseInverseSetup { vDSP_DFT_DestroySetup(setup) }
        }

        for p in 0..<numPhases {
            let fractional = Float(p) / Float(numPhases)
            var totalWeight: Float = 0
            let phaseOffset = p * kernelSize

            for k in 0..<kernelSize {
                let distance = Float(k - kernelRadius) - fractional
                let coeff = Self.sincCoefficientFloat(
                    distance: distance,
                    cutoff: cutoff,
                    kernelRadius: kernelRadius,
                    phaseMode: phaseMode
                )
                kernels[phaseOffset + k] = coeff
                totalWeight += coeff
            }

            if phaseMode == .minimumPhase,
               let forwardSetup = minimumPhaseForwardSetup,
               let inverseSetup = minimumPhaseInverseSetup {
                let linearKernel = Array(kernels[phaseOffset..<(phaseOffset + kernelSize)])
                let minimumPhaseKernel = Self.minimumPhaseKernel(
                    linearKernel,
                    fftSize: minimumPhaseFFTSize,
                    forwardSetup: forwardSetup,
                    inverseSetup: inverseSetup
                )
                for k in 0..<kernelSize {
                    kernels[phaseOffset + k] = minimumPhaseKernel[k]
                }
                totalWeight = minimumPhaseKernel.reduce(0, +)
            }

            if abs(totalWeight) > 1e-9 {
                let invWeight = 1.0 / totalWeight
                for k in 0..<kernelSize {
                    kernels[phaseOffset + k] *= invWeight
                }
            } else {
                for k in 0..<kernelSize { kernels[phaseOffset + k] = 0 }
                kernels[phaseOffset + kernelRadius] = 1.0
            }
        }

        sincKernelCacheLock.lock()
        if sincKernelCache.count > 24 {
            sincKernelCache.removeAll(keepingCapacity: true)
        }
        sincKernelCache[key] = kernels
        sincKernelCacheLock.unlock()
        return kernels
    }

    nonisolated private static func minimumPhaseKernel(
        _ input: [Float],
        fftSize: Int,
        forwardSetup: vDSP_DFT_Setup,
        inverseSetup: vDSP_DFT_Setup
    ) -> [Float] {
        guard !input.isEmpty, fftSize >= input.count else { return input }

        var inputReal = Array(repeating: Float(0), count: fftSize)
        let inputImag = Array(repeating: Float(0), count: fftSize)
        inputReal.replaceSubrange(0..<input.count, with: input)
        var spectrumReal = Array(repeating: Float(0), count: fftSize)
        var spectrumImag = Array(repeating: Float(0), count: fftSize)

        inputReal.withUnsafeBufferPointer { realPointer in
            inputImag.withUnsafeBufferPointer { imagPointer in
                spectrumReal.withUnsafeMutableBufferPointer { outputRealPointer in
                    spectrumImag.withUnsafeMutableBufferPointer { outputImagPointer in
                        vDSP_DFT_Execute(
                            forwardSetup,
                            realPointer.baseAddress!,
                            imagPointer.baseAddress!,
                            outputRealPointer.baseAddress!,
                            outputImagPointer.baseAddress!
                        )
                    }
                }
            }
        }

        var logMagnitude = Array(repeating: Float(0), count: fftSize)
        for index in 0..<fftSize {
            let magnitude = max(1e-8, hypot(spectrumReal[index], spectrumImag[index]))
            logMagnitude[index] = log(magnitude)
        }

        var cepstrum = Array(repeating: Float(0), count: fftSize)
        var cepstrumImag = Array(repeating: Float(0), count: fftSize)
        let zeroImag = Array(repeating: Float(0), count: fftSize)
        logMagnitude.withUnsafeBufferPointer { realPointer in
            zeroImag.withUnsafeBufferPointer { imagPointer in
                cepstrum.withUnsafeMutableBufferPointer { outputRealPointer in
                    cepstrumImag.withUnsafeMutableBufferPointer { outputImagPointer in
                        vDSP_DFT_Execute(
                            inverseSetup,
                            realPointer.baseAddress!,
                            imagPointer.baseAddress!,
                            outputRealPointer.baseAddress!,
                            outputImagPointer.baseAddress!
                        )
                    }
                }
            }
        }

        let inverseScale = 1.0 / Float(fftSize)
        for index in 0..<fftSize {
            cepstrum[index] *= inverseScale
            cepstrumImag[index] = 0
        }
        if fftSize > 2 {
            for index in 1..<(fftSize / 2) {
                cepstrum[index] *= 2
            }
            for index in (fftSize / 2 + 1)..<fftSize {
                cepstrum[index] = 0
            }
        }

        var minimumLogReal = Array(repeating: Float(0), count: fftSize)
        var minimumLogImag = Array(repeating: Float(0), count: fftSize)
        cepstrum.withUnsafeBufferPointer { realPointer in
            cepstrumImag.withUnsafeBufferPointer { imagPointer in
                minimumLogReal.withUnsafeMutableBufferPointer { outputRealPointer in
                    minimumLogImag.withUnsafeMutableBufferPointer { outputImagPointer in
                        vDSP_DFT_Execute(
                            forwardSetup,
                            realPointer.baseAddress!,
                            imagPointer.baseAddress!,
                            outputRealPointer.baseAddress!,
                            outputImagPointer.baseAddress!
                        )
                    }
                }
            }
        }

        var minimumSpectrumReal = Array(repeating: Float(0), count: fftSize)
        var minimumSpectrumImag = Array(repeating: Float(0), count: fftSize)
        for index in 0..<fftSize {
            let magnitude = exp(minimumLogReal[index])
            minimumSpectrumReal[index] = magnitude * cos(minimumLogImag[index])
            minimumSpectrumImag[index] = magnitude * sin(minimumLogImag[index])
        }

        var outputReal = Array(repeating: Float(0), count: fftSize)
        var outputImag = Array(repeating: Float(0), count: fftSize)
        minimumSpectrumReal.withUnsafeBufferPointer { realPointer in
            minimumSpectrumImag.withUnsafeBufferPointer { imagPointer in
                outputReal.withUnsafeMutableBufferPointer { outputRealPointer in
                    outputImag.withUnsafeMutableBufferPointer { outputImagPointer in
                        vDSP_DFT_Execute(
                            inverseSetup,
                            realPointer.baseAddress!,
                            imagPointer.baseAddress!,
                            outputRealPointer.baseAddress!,
                            outputImagPointer.baseAddress!
                        )
                    }
                }
            }
        }

        let targetDC = input.reduce(0, +)
        let generatedDC = outputReal.prefix(input.count).reduce(0, +) * inverseScale
        let gain = abs(generatedDC) > 1e-8 ? targetDC / generatedDC : 1
        return outputReal.prefix(input.count).map { $0 * inverseScale * gain }
    }

    nonisolated private static func clearSincKernelCache() {
        sincKernelCacheLock.lock()
        sincKernelCache.removeAll(keepingCapacity: false)
        sincKernelCacheLock.unlock()
    }

    nonisolated private static func sincCoefficientFloat(
        distance: Float,
        cutoff: Float,
        kernelRadius: Int,
        phaseMode: PrecisionSincPhaseMode
    ) -> Float {
        let x = distance * cutoff
        let sinc: Float
        if abs(x) < 1e-7 {
            sinc = 1.0
        } else {
            let pix = Float.pi * x
            sinc = sin(pix) / pix
        }

        let radius = Float(kernelRadius)
        let n = distance + radius
        let N = radius * 2.0

        let window: Float
        switch phaseMode {
        case .linear:
            window = kaiserWindow(n: n, N: N, beta: 9.0)
        case .minimumPhase:
            window = kaiserWindow(n: n, N: N, beta: 7.0)
        case .apodizing:
            window = kaiserWindow(n: n, N: N, beta: 14.0)
        }
        
        return sinc * window * cutoff
    }

    nonisolated private static func clonePlaybackBuffer(from sourceBuffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        guard let clonedBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceBuffer.format,
            frameCapacity: sourceBuffer.frameCapacity
        ) else {
            throw HiResEngineError.upconvertBufferFailed
        }

        clonedBuffer.frameLength = sourceBuffer.frameLength
        guard let sourceChannels = sourceBuffer.floatChannelData,
              let targetChannels = clonedBuffer.floatChannelData else {
            return clonedBuffer
        }

        let channelCount = Int(sourceBuffer.format.channelCount)
        let frameCount = Int(sourceBuffer.frameLength)
        for channel in 0..<channelCount {
            targetChannels[channel].update(from: sourceChannels[channel], count: frameCount)
        }

        return clonedBuffer
    }

    // MARK: - Private: DSP Math Helpers

    nonisolated private static func besselI0(_ x: Float) -> Float {
        var sum: Float = 1.0
        var term: Float = 1.0
        let halfX = x / 2.0
        for k in 1...20 {
            term *= (halfX / Float(k))
            term *= (halfX / Float(k))
            sum += term
            if term < 1e-10 { break }
        }
        return sum
    }

    nonisolated private static func kaiserWindow(n: Float, N: Float, beta: Float) -> Float {
        let r = 1.0 - pow((2.0 * n / N) - 1.0, 2)
        let clampedR = max(0.0, r)
        return besselI0(beta * sqrt(clampedR)) / besselI0(beta)
    }

    nonisolated private static func applyTPDFDither(to buffer: AVAudioPCMBuffer, sourceBitDepth: UInt32) {
        guard sourceBitDepth <= 16, let channelData = buffer.floatChannelData else { return }
        let ditherAmplitude = Float(1.0) / Float(1 << sourceBitDepth)
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        
        for ch in 0..<channelCount {
            let samples = channelData[ch]
            for i in 0..<frameCount {
                let r1 = Float.random(in: -1.0...1.0)
                let r2 = Float.random(in: -1.0...1.0)
                samples[i] += ditherAmplitude * (r1 - r2) * 0.5
            }
        }
    }
}

nonisolated private struct SincKernelCacheKey: Hashable, Sendable {
    let kernelSize: Int
    let numPhases: Int
    let cutoffMilli: Int
    let phaseMode: PrecisionSincPhaseMode
    let qualityMode: PrecisionSincQualityMode

    nonisolated static func == (lhs: SincKernelCacheKey, rhs: SincKernelCacheKey) -> Bool {
        lhs.kernelSize == rhs.kernelSize &&
        lhs.numPhases == rhs.numPhases &&
        lhs.cutoffMilli == rhs.cutoffMilli &&
        lhs.phaseMode == rhs.phaseMode &&
        lhs.qualityMode == rhs.qualityMode
    }

    nonisolated func hash(into hasher: inout Hasher) {
        hasher.combine(kernelSize)
        hasher.combine(numPhases)
        hasher.combine(cutoffMilli)
        hasher.combine(phaseMode)
        hasher.combine(qualityMode)
    }
}

nonisolated private struct AnalysisCacheKey: Hashable, Sendable {
    let sourceIdentity: String
    let fileSize: UInt64
    let modificationTime: Int64
    let targetSampleRateRounded: Int
    let upsamplingModeRaw: String
    let hrtfPresetRaw: String
    let spatialMilli: Int
    let crossfeedMilli: Int
}

nonisolated private struct PreloadedPlaybackKey: Hashable, Sendable {
    let sourceIdentity: String
    let fileSize: UInt64
    let modificationTime: Int64
    let upsamplingModeRaw: String
    let hrtfPresetRaw: String
    let spatialMilli: Int
    let crossfeedMilli: Int
}

private struct AnalysisCacheValue {
    let diagnostics: SignalLevelDiagnostics
    let automaticDSPProfile: HiResPlaybackEngine.AutomaticDSPProfile
}

nonisolated private struct SincKernelProfile: Sendable {
    let radius: Int
    let numPhases: Int
}

private extension PrecisionSincPhaseMode {
    nonisolated var cutoffScale: Float {
        switch self {
        case .linear:
            return 0.97
        case .minimumPhase:
            return 0.94
        case .apodizing:
            return 0.90
        }
    }
}

private extension PrecisionSincQualityMode {
    nonisolated var sincKernelProfile: SincKernelProfile {
        switch self {
        case .eco:
            return SincKernelProfile(radius: 16, numPhases: 512)
        case .standard:
            return SincKernelProfile(radius: 24, numPhases: 1024)
        case .master:
            return SincKernelProfile(radius: 40, numPhases: 2048)
        }
    }
}
