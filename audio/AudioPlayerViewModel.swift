//
//  AudioPlayerViewModel.swift
//  audio
//
//  2026/04/02.
//

import AVFoundation
import Combine
import Darwin
import Foundation
import MediaPlayer
import MusicKit
import SwiftUI
import UIKit

enum PlaybackSource {
    case local
    case system
}

enum RepeatMode {
    case off
    case singleTrack
    case album
}

enum ShuffleMode {
    case off
    case album
    case library
}

enum LibraryActionFeedback: Equatable {
    case idle
    case working
    case completed(Int)
    case notice(String)
}

@MainActor
final class AudioPlayerViewModel: NSObject, ObservableObject {
    private struct SystemLibrarySnapshot {
        let songs: [SystemSong]
        let artists: [SystemArtist]
        let albums: [SystemAlbum]

        nonisolated init(songs: [SystemSong]) {
            let index = SystemLibraryIndex(songs: songs, normalize: AudioPlayerViewModel.normalizeSearchText)
            self.songs = songs
            artists = index.artists
            albums = index.albums
        }
    }

    @Published var isPlaying = false
    @Published var isProcessing = false
    @Published var progress = 0.0
    @Published var currentTimeText = "00:00"
    @Published var durationText = "00:00"
    @Published var nowPlayingArtwork: UIImage?
    @Published var trackTitle = L10n.tr("now_playing.placeholder.title")
    @Published var trackSubtitle = L10n.tr("now_playing.placeholder.subtitle")
    @Published var errorMessage: String?
    @Published var mediaLibraryAccess: MediaLibraryAccessState = .notDetermined
    @Published private(set) var cloudServiceAccessStatus: MusicAuthorization.Status = .notDetermined
    @Published private(set) var appleMusicAccessStatus: MusicAuthorization.Status = .notDetermined
    @Published private(set) var appleMusicCatalogSongs: [AppleMusicCatalogSongResult] = []
    @Published private(set) var appleMusicCatalogAlbums: [AppleMusicCatalogAlbumResult] = []
    @Published private(set) var isSearchingAppleMusicCatalog = false
    @Published private(set) var isAddingAppleMusicItemIDs: Set<String> = []
    @Published private(set) var addedAppleMusicItemIDs: Set<String> = []
    @Published private(set) var canModifyAppleMusicLibrary = false
    @Published var currentOutputRMS: Float = -120
    @Published var currentOutputPeak: Float = -120
    @Published var currentVUValue: Double = 0
    @Published var currentSpectrum: [Float] = Array(repeating: -120, count: 32)
    @Published private(set) var upsamplingMode: UpsamplingMode = AudioMemorySafetyMode.deviceDefault.automaticUpsamplingMode
    @Published private(set) var isChangingUpsamplingMode = false
    @Published private(set) var isEffectProcessing = false
    @Published private(set) var isSpatialProcessing = false
    @Published private(set) var isPlaybackStarting = false
    @Published var localPlaybackFormatDescription = L10n.playbackFormatUnavailable()
    @Published var systemArtists: [SystemArtist] = []
    @Published var systemAlbums: [SystemAlbum] = []
    @Published var systemSongs: [SystemSong] = []
    @Published var systemPlaylists: [SystemPlaylist] = []
    @Published private(set) var ongakuPlaylists: [OngakuPlaylist] = []
    @Published var searchText = ""
    @Published var effectSettings = AudioEffectModuleRegistry.makeDefaultSettings()
    @Published private(set) var selectedEffectPageTab: AudioEffectPageTab = .basic
    @Published var headphoneSpatialSettings = HeadphoneSpatialSettings.default
    @Published private(set) var audioOutputOverride = AudioOutputPolicy.currentOverride
    @Published private(set) var loudnessCompensationEnabled = AudioOutputPolicy.compensationEnabled
    @Published var automaticDSPStrength: Double = 1.0
    @Published var automaticDSPVoicing: AutomaticDSPVoicing = .natural
    @Published private(set) var isABReferenceMode = false
    @Published private(set) var isMemoryOptimizedMode = AudioMemorySafetyMode.deviceDefault.disablesHeavyDSP
    @Published private(set) var effectAuditSummaryText = L10n.tr("effects.signal.unavailable")
    @Published private(set) var audioRenderHealth = AudioRenderHealthSnapshot.healthy
    @Published private(set) var preparedAudioCacheStatistics = PreparedAudioCacheStatistics.empty
    @Published private(set) var isClearingPreparedAudioCache = false
    @Published private(set) var repeatMode: RepeatMode = .album
    @Published private(set) var shuffleMode: ShuffleMode = .off
    @Published private(set) var canGoToPreviousTrack = false
    @Published private(set) var canGoToNextTrack = false
    @Published private(set) var nowPlayingAlbum: SystemAlbum?
    @Published private(set) var selectedSystemSongID: UInt64?
    @Published private(set) var isLibraryBootstrapInProgress = false
    @Published private(set) var isInitialLibraryLoading = true
    @Published private(set) var isScanningLocalLibrary = false
    @Published private(set) var libraryLoadingMessage: String?
    @Published private(set) var systemLibraryFeedback: LibraryActionFeedback = .idle
    @Published private(set) var localLibraryFeedback: LibraryActionFeedback = .idle
    @Published private(set) var isRequestingSystemLibraryAccess = false
    @Published private(set) var isRequestingAppleMusicAccess = false
    @Published private(set) var trackOverlays: [String: LibraryTrackOverlay] = [:]

    @Published var filteredSystemArtists: [SystemArtist] = []
    @Published var filteredSystemAlbums: [SystemAlbum] = []
    @Published var filteredSystemSongs: [SystemSong] = []
    @Published var filteredSystemPlaylists: [SystemPlaylist] = []

    // 【重要】再生の安定性に関する最終結論 (Final Decision)
    // 開発環境において、applicationQueuePlayer等は通信エラー (ping did not pong) を回避できません。
    // 手法を模索した結果、最も特権が高く安定してDRM曲を再生できるのは systemMusicPlayer であると断定しました。
    // ※ 開発ビルドでは ICError -7013 (権限エラー) のログが出ますが、これは再生を妨げない非ブロックエラーです。
    private lazy var systemPlayer = MPMusicPlayerController.systemMusicPlayer
    private var updateTimer: Timer?
    private var visualizationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var searchTask: Task<Void, Never>?
    private var searchGeneration: UInt64 = 0
    private var librarySnapshotRevision: UInt64 = 0
    private var appleMusicSearchTask: Task<Void, Never>?
    private var playbackSource: PlaybackSource = .local
    private var systemQueue: [SystemSong] = []
    private var systemQueueIndex: Int?
    private var systemQueueTitle: String?
    private var pendingPlaybackSnapshot: PlaybackSnapshot?
    private var pendingEffectSettings: [StoredEffectSetting] = []
    private var isSystemPlayerConfigured = false
    private var isSystemPlayerStarting = false
    private var systemRequestedSongID: UInt64?
    private var systemRequestedStoreID = ""
    private enum SystemPreparationState {
        case idle, preparing, ready, failed(String)
    }
    private var systemPreparationState: SystemPreparationState = .idle
    private var hasInitializedHiResPlaybackEngine = false
    private var isApplicationActive = true
    private var memorySafetyMode = AudioMemorySafetyMode.deviceDefault
    private var shouldRestorePlaybackFromInitialLibrary = false
    private lazy var hiResPlaybackEngine: HiResPlaybackEngine = {
        let engine = HiResPlaybackEngine()
        engine.setMemorySafetyMode(memorySafetyMode)
        engine.onPlaybackEnded = { [weak self] in
            self?.handleLocalPlaybackEnded()
        }
        engine.setEffectsBypassed(selectedEffectPageTab == .off)
        engine.setSystemOutputVolume(AVAudioSession.sharedInstance().outputVolume)
        engine.refreshLoudnessCompensationRoute()
        engine.setAutomaticDSPStrength(playbackAutomaticDSPStrength, effectSettings: playbackEffectSettings)
        engine.setAutomaticDSPVoicing(automaticDSPVoicing)
        hasInitializedHiResPlaybackEngine = true
        return engine
    }()
    private let systemMediaLibrary = SystemMediaLibrary()
    private let appLibraryStore = AppLibraryStore()
    private let statePersistenceQueue = DispatchQueue(label: "audio.player.statePersistence", qos: .utility)
    private var wasPlayingBeforeSessionInterruption: Bool = false
    private var interruptedPlaybackSource: PlaybackSource?
    private var interruptionResumeTask: Task<Void, Never>?
    private var sessionActivationRetryTask: Task<Void, Never>?
    private var sessionActivationRequestID: UUID?
    private var systemTransportStartTask: Task<Void, Never>?
    private var interruptionAllowsImmediateResume = false
    private var playbackStartMonitorTask: Task<Void, Never>?
    private var unexpectedPlaybackRecoveryTask: Task<Void, Never>?
    private var remoteCommandRegistrations: [(command: MPRemoteCommand, target: Any)] = []
    private var isInterrupted = false
    private var userPauseIntentToken: UInt64 = 0
    private var interruptionPauseIntentBaseline: UInt64 = 0
    private var interruptionPlaybackPreparationBaseline: UInt64 = 0
    private var interruptionGeneration: UInt64 = 0
    private var isApplyingRealtimeEffects: Bool = false
    private var lastAutoPeakAdjustTime: TimeInterval = 0
    private var lastManualParameterReductionTime: TimeInterval = 0
    private var lastTrackEndHandledAt: TimeInterval = 0
    private var lastLocalTrackEndGeneration: UInt64?
    private var localProgressWatchdog = PlaybackProgressWatchdog()
    private var lastObservedSystemPlaybackSongID: UInt64?
    private var lastObservedSystemPlaybackProgress = 0.0
    private var lastOverlayCompletionKey: String?
    private var lastOverlayCompletionAt: TimeInterval = 0
    private var lastExplicitRemoteTransportCommandAt: TimeInterval = 0
    private var forcedPausedUntil: TimeInterval = 0

    private var playbackEffectSettings: [RealtimeAudioEffectSetting] {
        let activeKinds = AudioEffectModuleRegistry.activeKinds(for: selectedEffectPageTab)
        let selectedTabSettings = effectSettings.map { setting in
            guard !activeKinds.contains(setting.kind) else { return setting }
            var bypassed = setting
            bypassed.isEnabled = false
            return bypassed
        }
        let memorySafeSettings = memorySafetyMode.safeEffectSettings(selectedTabSettings)
        guard isABReferenceMode else { return memorySafeSettings }
        return memorySafeSettings.map { setting in
            var bypassed = setting
            bypassed.isEnabled = false
            return bypassed
        }
    }

    private var playbackAutomaticDSPStrength: Float {
        selectedEffectPageTab == .off || isABReferenceMode ? 0 : Float(automaticDSPStrength)
    }

    private var playbackSpatialSettings: HeadphoneSpatialSettings {
        var selectedTabSettings = headphoneSpatialSettings
        if selectedEffectPageTab != .pro {
            selectedTabSettings.isEnabled = false
        }
        return memorySafetyMode.safeSpatialSettings(selectedTabSettings)
    }

    private static let selectedEffectPageTabDefaultsKey = "selectedEffectPageTab"

    private func safeUpsamplingMode(_ requested: UpsamplingMode) -> UpsamplingMode {
        memorySafetyMode.safeUpsamplingMode(requested)
    }

    private var forcedPausedSource: PlaybackSource?
    private var lastNowPlayingTrackKey: String?
    private var lastNowPlayingState: MPNowPlayingPlaybackState = .unknown
    private var lastNowPlayingElapsed: TimeInterval = 0
    private var effectAuditRefreshTimer: Timer?
    private var isEffectAuditRefreshPrimed = false
    private var isEffectScreenActive = false
    private var spatialRequestID = UUID()
    private var headphoneSpatialApplyTimer: Timer?
    private var effectApplyTimer: Timer?
    private var reinforceTaskID = 0
    private var upsamplingReloadTask: Task<Void, Never>?
    @Published private var isPreparingLocalPlayback = false
    private var remotePlaybackFile: RemotePlaybackFile?
    private var musicPlaybackSnapshot: MusicAssetPreparation.Snapshot?
    @Published private var isPreparingSystemAsset = false
    private var systemAssetRecoveryTask: Task<Void, Never>? {
        didSet { isPreparingSystemAsset = systemAssetRecoveryTask != nil }
    }
    private var systemAssetRecoveryID = UUID()
    private var systemHandoffEngineOwner: UUID?
    private var systemAssetRecoveryGate = SystemAssetRecoveryGate()
    @Published private var systemAssetRecoveryFailure: String?
    private var localPlaybackLoadTask: Task<Void, Never>? {
        didSet {
            // Paused startup restoration also prepares PCM/format/DSP, but
            // does not set the autoplay flags. Publish readiness with the
            // task lifetime so the spinner and controls change together.
            isPreparingLocalPlayback = localPlaybackLoadTask != nil
        }
    }
    private var cacheMaintenanceTask: Task<Void, Never>?
    private var precisionUpgradeTask: Task<Void, Never>?
    private var qualityUpgradeRequestID = UUID()
    private var playbackPreparationToken: UInt64 = 0
    private var preloadTrackTask: Task<Void, Never>?
    private var lastUserPlaybackInteractionAt: CFAbsoluteTime = 0
    private let isBackgroundQualityUpgradeEnabled = true
    private var appleMusicSongLookup: [String: Song] = [:]
    private var appleMusicAlbumLookup: [String: Album] = [:]
    private var visualizationTickCount: Int = 0
    private var memorySafetyTickCount: Int = 0
    private var memoryRecoveryStableSampleCount: Int = 0
    private var memoryRecoveryNotBefore: CFAbsoluteTime = 0
    private var lastPublishedSpectrum: [Float] = []
    private var syntheticVisualizationPhase: Double = 0
    private let vuBallistics = BallisticSimulator()
    private var vuTransitionTask: Task<Void, Never>?
    private var outputVolumeObservation: NSKeyValueObservation?
    private var hasStartedInitialBootstrap = false
    private var initialBootstrapTask: Task<Void, Never>?
    private var systemLibraryRefreshTask: Task<Void, Never>?
    private var systemLibraryChangeDebounceTask: Task<Void, Never>?
    private var deferredSystemLibraryRefreshTask: Task<Void, Never>?
    private var deferredLocalLibraryScanTask: Task<Void, Never>?
    private var localLibraryScanTask: Task<Void, Never>?
    private var localLibraryScanGeneration: UInt64 = 0
    private var localLibraryChangeDebounceTask: Task<Void, Never>?
    private var localLibraryMonitor: DispatchSourceFileSystemObject?
    private var librarySnapshotPersistenceTask: Task<Void, Never>?
    private var systemLibraryRefreshGeneration: UInt64 = 0
    private var hasPendingSystemLibraryChange = false
    private var deferredLibrarySnapshot: SystemLibrarySnapshot?
    private var foregroundLibraryRecoveryTask: Task<Void, Never>?
    /// Files in Documents/Ongaku are an app-owned source. Keep them separate
    /// from MediaPlayer snapshots so a later fast/detailed system refresh can
    /// never overwrite them.
    private var localLibraryTracks: [LocalTrackMetadata] = []

    private var isPlaybackBusyForLibraryWork: Bool {
        if isPlaying || isProcessing || isPlaybackStarting || isPreparingLocalPlayback { return true }
        if hasInitializedHiResPlaybackEngine && hiResPlaybackEngine.isPlaying { return true }
        if isSystemPlayerConfigured && systemPlayer.playbackState == .playing { return true }
        return false
    }

    private var hasResidentLocalPlaybackTrack: Bool {
        playbackSource == .local
            && hasInitializedHiResPlaybackEngine
            && hiResPlaybackEngine.hasTrack
    }

    var hasTrack: Bool {
        selectedSystemSongID != nil
            || (hasInitializedHiResPlaybackEngine && hiResPlaybackEngine.hasTrack)
            || (isSystemPlayerConfigured && systemPlayer.nowPlayingItem != nil)
    }

    var canOpenNowPlayingAlbum: Bool {
        nowPlayingAlbum != nil
    }

    var shouldShowNowPlayingLoadingState: Bool {
        isInitialLibraryLoading && !hasTrack
    }

    var isLoading: Bool {
        let nativeReady: Bool
        switch playbackSource {
        case .local:
            nativeReady = hasInitializedHiResPlaybackEngine && hiResPlaybackEngine.hasTrack
                && !isPreparingLocalPlayback
        case .system:
            if case .ready = systemPreparationState { nativeReady = true }
            else { nativeReady = actualPlaybackState == .playing }
        }
        return PlaybackTransportPolicy.controlsBlocked(
            nativeReady: nativeReady,
            preparing: isProcessing || isPlaybackStarting || isPreparingLocalPlayback,
            initialLibraryLoading: isInitialLibraryLoading && !hasTrack
        )
    }

    var nowPlayingDisplayTitle: String {
        shouldShowNowPlayingLoadingState
            ? L10n.tr("now_playing.loading.title")
            : trackTitle
    }

    var nowPlayingDisplaySubtitle: String {
        shouldShowNowPlayingLoadingState
            ? L10n.tr("now_playing.loading.subtitle")
            : trackSubtitle
    }

    var supportsRealtimeEffects: Bool {
        playbackSource == .local && hasInitializedHiResPlaybackEngine && hiResPlaybackEngine.hasTrack
    }

    var accentColor: Color { Theme.accent }

    var canChangeUpsamplingMode: Bool {
        !isChangingUpsamplingMode
    }

    var realtimeEffectsStatusText: String {
        if selectedEffectPageTab == .off { return L10n.tr("effects.tab.off") }
        if supportsRealtimeEffects {
            return L10n.tr("effects.status.active")
        }
        return L10n.tr("effects.status.inactive")
    }

    var realtimeEffectsAvailabilityDetail: String {
        if supportsRealtimeEffects {
            return L10n.tr("effects.availability.active")
        }

        if isPreparingSystemAsset { return L10n.tr("effects.availability.preparing") }
        if playbackSource == .system, let systemAssetRecoveryFailure { return systemAssetRecoveryFailure }
        switch playbackSource {
        case .local:
            return hasInitializedHiResPlaybackEngine && hiResPlaybackEngine.hasTrack
                ? L10n.tr("effects.availability.local_waiting")
                : L10n.tr("effects.availability.local_none")
        case .system:
            if isCurrentTrackProtectedSystemPlayback {
                return L10n.tr("effects.availability.protected")
            }
            return L10n.tr("effects.availability.system")
        }
    }

    var canRetrySystemAssetRecovery: Bool {
        playbackSource == .system && systemAssetRecoveryFailure != nil && !isPreparingSystemAsset && isPlaying
    }

    func retrySystemAssetRecovery() {
        guard canRetrySystemAssetRecovery else { return }
        systemAssetRecoveryGate.reset()
        startSystemAssetRecoveryIfNeeded()
    }

    private var isCurrentTrackProtectedSystemPlayback: Bool {
        guard playbackSource == .system,
              let currentPlaybackSong else {
            return false
        }
        return (resolvedSystemSongID == currentPlaybackSong.id && systemPlayer.nowPlayingItem?.hasProtectedAsset == true)
            || systemMediaLibrary.mediaItem(for: currentPlaybackSong.id)?.hasProtectedAsset == true
    }

    var signalDiagnosticsSummary: String {
        hiResPlaybackEngine.signalDiagnostics?.summary ?? L10n.tr("effects.signal.unavailable")
    }

    var audioRenderHealthSummary: String {
        if audioRenderHealth.dropoutCount == 0 {
            return L10n.tr("effects.render_health.healthy")
        }

        let status = audioRenderHealth.isStalled
            ? L10n.tr("effects.render_health.stalled")
            : L10n.tr("effects.render_health.recovered")
        return L10n.tr(
            "effects.render_health.summary",
            audioRenderHealth.dropoutCount,
            audioRenderHealth.maxRenderGapMilliseconds,
            status
        )
    }

    var effectAuditSummary: String {
        Self.makeEffectAuditSummary(from: hiResPlaybackEngine.refreshEffectLevelAudits())
    }

    var automaticDSPSummary: String {
        let status = hiResPlaybackEngine.automaticDSPStatus
        return L10n.tr(
            "effects.auto_dsp.summary",
            status.lowShelfGainDB,
            status.lowMidGainDB,
            status.presenceGainDB,
            status.highShelfGainDB,
            status.strength * 100.0,
            status.cacheHit ? L10n.tr("effects.auto_dsp.cache.hit") : L10n.tr("effects.auto_dsp.cache.miss"),
            status.cacheHits,
            status.cacheMisses
        )
    }

    private static func makeEffectAuditSummary(from audits: [EffectLevelAudit]) -> String {
        guard !audits.isEmpty else { return L10n.tr("effects.signal.unavailable") }
        let prioritized = audits.filter(\.isEnabled)
        let visible = prioritized.isEmpty ? audits : prioritized
        return visible.map { audit in
            let peakRisk = audit.outputPeakDBFS > -1.0
            let levelJumpRisk = abs(audit.rmsDeltaDB) > 8.0
            let status = peakRisk ? "CLIP RISK" : (levelJumpRisk ? "LEVEL JUMP" : "OK")
            return "\(audit.kind.displayName): IN \(String(format: "%.1f", audit.inputRMSDBFS)) / OUT \(String(format: "%.1f", audit.outputRMSDBFS)) dBFS, PEAK \(String(format: "%.1f", audit.outputPeakDBFS)) dBFS (\(Self.formatSigned(audit.rmsDeltaDB)) dB) [\(status)]"
        }.joined(separator: "\n")
    }

    private static func formatSigned(_ value: Float) -> String {
        String(format: value >= 0 ? "+%.1f" : "%.1f", value)
    }

    var activeEffectNames: [String] {
        var names = playbackEffectSettings
            .filter(\.isEnabled)
            .map(\.kind.displayName)
        if playbackSpatialSettings.isEnabled {
            names.insert(L10n.headphoneSpatialName(), at: 0)
        }
        return names
    }

    var nowPlayingEffectsBadgeText: String? {
        let names = activeEffectNames
        guard !names.isEmpty else { return nil }
        if names.count == 1 {
            return String(format: L10n.tr("effects.badge.single"), names[0])
        }
        return String(format: L10n.tr("effects.badge.multiple"), names.count)
    }

    /// 合計DSP適用数（アップサンプリングを1つ、エフェクト各々を1つとして算出）
    var totalDSPCount: Int {
        var count = playbackEffectSettings.filter(\.isEnabled).count
        if playbackSpatialSettings.isEnabled {
            count += 1
        }
        // ローカル再生時は常にアップサンプリングが適用されているため+1
        if playbackSource == .local && hasInitializedHiResPlaybackEngine && hiResPlaybackEngine.hasTrack {
            count += 1
        }
        return count
    }

    /// 再生信号経路のサマリーテキスト
    /// 例: "192kHz / 24bit ・ DSP: 3"
    var playbackSignalSummary: String? {
        guard !isPreparingLocalPlayback, playbackSource == .local,
              hasInitializedHiResPlaybackEngine, hiResPlaybackEngine.hasTrack else { return nil }
        
        // フォーマット情報 (例: "192kHz / 24bit")
        let format = hiResPlaybackEngine.currentFormat?.description ?? ""
        let dspCount = totalDSPCount
        
        if format.isEmpty && dspCount == 0 { return nil }
        
        let dspLabel = String(format: L10n.tr("effects.badge.multiple"), dspCount)
        if format.isEmpty { return dspLabel }
        
        return "\(format) \(L10n.tr("separator.dot")) \(dspLabel)"
    }

    var lyricsPlaybackSong: SystemSong? { currentPlaybackSong }

    // Read the transport clock, not a rounded display string or cached library duration.
    var lyricsPlaybackTime: TimeInterval {
        let time = playbackSource == .local ? hiResPlaybackEngine.currentTime() : systemPlayer.currentPlaybackTime
        return time.isFinite ? max(0, time) : 0
    }

    func seekLyrics(to time: TimeInterval, songKey: String) {
        guard currentPlaybackSong?.overlayKey == songKey, time.isFinite else { return }
        let duration = playbackSource == .local ? hiResPlaybackEngine.duration : (systemPlayer.nowPlayingItem?.playbackDuration ?? 0)
        guard duration > 0 else { return }
        seek(to: min(max(time / duration, 0), 1))
    }

    private var currentPlaybackSong: SystemSong? {
        if let selectedSystemSongID,
           let selectedSong = systemSongs.first(where: { $0.id == selectedSystemSongID }) {
            return selectedSong
        }
        if let selectedSystemSongID {
            return systemQueue.first { $0.id == selectedSystemSongID }
        }
        return nil
    }

    private var currentAlbumSongs: [SystemSong] {
        if let currentPlaybackSong,
           let albumQueue = albumQueue(for: currentPlaybackSong) {
            return albumQueue
        }
        if let nowPlayingAlbum {
            return songs(for: nowPlayingAlbum)
        }
        return []
    }


    var isSingleTrackRepeatEnabled: Bool { repeatMode == .singleTrack }
    var isAlbumRepeatEnabled: Bool { repeatMode == .album }
    var isAlbumShuffleEnabled: Bool { shuffleMode == .album }
    var isLibraryShuffleEnabled: Bool { shuffleMode == .library }
    var canUseAlbumScopedPlaybackModes: Bool {
        currentPlaybackSong != nil && currentAlbumSongs.count > 1
    }
    var canUseLibraryShuffle: Bool {
        !systemSongs.isEmpty && currentPlaybackSong != nil
    }

    var hasActiveSearch: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var canSearchAppleMusicCatalog: Bool {
        appleMusicAccessStatus == .authorized
    }

    var appleMusicStatusMessage: String? {
        guard appleMusicAccessStatus == .authorized else { return nil }
        guard !canModifyAppleMusicLibrary else { return nil }
        return L10n.tr("apple_music.library_unavailable")
    }

    private func setupSearchDebounce() {
        $searchText
            .dropFirst()
            .debounce(for: .seconds(0.45), scheduler: DispatchQueue.main)
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.performSearch()
            }
            .store(in: &cancellables)
    }

    private func performSearch(refreshCatalog: Bool = true) {
        searchTask?.cancel()
        searchGeneration &+= 1
        let request = searchGeneration
        let revision = librarySnapshotRevision
        if refreshCatalog { appleMusicSearchTask?.cancel() }
        
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            appleMusicSearchTask?.cancel()
            filteredSystemArtists = systemArtists
            filteredSystemAlbums = systemAlbums
            filteredSystemSongs = systemSongs
            filteredSystemPlaylists = systemPlaylists
            appleMusicCatalogSongs = []
            appleMusicCatalogAlbums = []
            appleMusicSongLookup = [:]
            appleMusicAlbumLookup = [:]
            isSearchingAppleMusicCatalog = false
            return
        }

        // 検索対象のデータをキャプチャ（MainActor上で現在のスナップショットを取得）
        let poets = systemArtists
        let discography = systemAlbums
        let overlays = trackOverlays
        let tracks = systemSongs.map { song in
            var searchableSong = song
            if let tags = overlays[song.overlayKey]?.displayTags {
                searchableSong.normalizedSearchTerms.append(
                    contentsOf: tags.map(Self.normalizeSearchText)
                )
            }
            return searchableSong
        }
        let lists = systemPlaylists

        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            
            // バックグラウンドスレッドで重い計算を実行
            let artists = Self.rankedSearchResults(in: poets, query: query, sortKey: \.name)
            let albums = Self.rankedSearchResults(in: discography, query: query, sortKey: \.title)
            let songs = Self.rankedSearchResults(in: tracks, query: query, sortKey: \.title)
            let playlists = Self.rankedSearchResults(in: lists, query: query, sortKey: \.name)
            
            if Task.isCancelled { return }
            
            await MainActor.run {
                guard !Task.isCancelled,
                      SystemLibraryIndex.acceptsSearchResult(
                        query: query, currentQuery: self.searchText,
                        revision: revision, currentRevision: self.librarySnapshotRevision,
                        request: request, currentRequest: self.searchGeneration
                      ) else { return }
                self.filteredSystemArtists = artists
                self.filteredSystemAlbums = albums
                self.filteredSystemSongs = songs
                self.filteredSystemPlaylists = playlists
            }
        }

        guard refreshCatalog else { return }
        guard canSearchAppleMusicCatalog else {
            appleMusicCatalogSongs = []
            appleMusicCatalogAlbums = []
            appleMusicSongLookup = [:]
            appleMusicAlbumLookup = [:]
            isSearchingAppleMusicCatalog = false
            return
        }

        isSearchingAppleMusicCatalog = true
        appleMusicSearchTask = Task { [weak self] in
            await self?.performAppleMusicCatalogSearch(for: query)
        }
    }

    private func performAppleMusicCatalogSearch(for query: String) async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty, canSearchAppleMusicCatalog else {
            appleMusicCatalogSongs = []
            appleMusicCatalogAlbums = []
            appleMusicSongLookup = [:]
            appleMusicAlbumLookup = [:]
            isSearchingAppleMusicCatalog = false
            return
        }

        guard trimmedQuery.count >= 2 else {
            appleMusicCatalogSongs = []
            appleMusicCatalogAlbums = []
            appleMusicSongLookup = [:]
            appleMusicAlbumLookup = [:]
            isSearchingAppleMusicCatalog = false
            return
        }

        defer {
            isSearchingAppleMusicCatalog = false
        }

        do {
            var request = MusicCatalogSearchRequest(
                term: trimmedQuery,
                types: [Song.self]
            )
            request.limit = 12
            let response = try await request.response()
            guard !Task.isCancelled else { return }

            let songs = Array(response.songs.prefix(12))

            appleMusicSongLookup = Dictionary(
                uniqueKeysWithValues: songs.compactMap { song in
                    guard let id = Self.validCatalogItemIDString(song.id) else { return nil }
                    return (id, song)
                }
            )
            appleMusicAlbumLookup = [:]

            appleMusicCatalogSongs = songs.compactMap { song in
                guard let id = Self.validCatalogItemIDString(song.id) else { return nil }
                return AppleMusicCatalogSongResult(
                    id: id,
                    title: song.title,
                    artistName: song.artistName,
                    artworkURL: song.artwork?.url(width: 160, height: 160)
                )
            }
            appleMusicCatalogAlbums = []
        } catch is CancellationError {
            return
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled {
                return
            }
            appleMusicCatalogSongs = []
            appleMusicCatalogAlbums = []
            appleMusicSongLookup = [:]
            appleMusicAlbumLookup = [:]
            errorMessage = L10n.tr("error.apple_music_search_failed", error.localizedDescription)
        }
    }

    // バックグラウンドスレッドから直接呼べるように nonisolated static に設定
    nonisolated private static func rankedSearchResults<Item>(
        in items: [Item],
        query: String,
        sortKey: KeyPath<Item, String>
    ) -> [Item] where Item: SearchableItem, Item: Sendable {
        let scoredItems: [(item: Item, score: Int)] = items.compactMap { item in
            guard let score = Self.searchScore(for: query, itemFields: item.getNormalizedSearchTerms()) else {
                return nil
            }
            return (item: item, score: score)
        }

        return scoredItems
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.item[keyPath: sortKey]
                    .localizedCaseInsensitiveCompare(rhs.item[keyPath: sortKey]) == .orderedAscending
            }
            .map(\.item)
    }

    nonisolated private static func catalogItemIDString(_ id: MusicItemID) -> String {
        String(describing: id)
    }

    nonisolated private static func validCatalogItemIDString(_ id: MusicItemID) -> String? {
        let resolved = catalogItemIDString(id).trimmingCharacters(in: .whitespacesAndNewlines)
        return resolved.isEmpty ? nil : resolved
    }



    var searchResultCountSummary: String {
        guard hasActiveSearch else {
            return L10n.tr("search.summary.placeholder")
        }

        let playlistCount = filteredSystemPlaylists.count
        let artistCount = filteredSystemArtists.count
        let albumCount = filteredSystemAlbums.count
        let songCount = filteredSystemSongs.count
        let totalCount = playlistCount + artistCount + albumCount + songCount

        guard totalCount > 0 else {
            return L10n.tr("search.summary.empty")
        }

        return L10n.searchSummary(total: totalCount, playlists: playlistCount, artists: artistCount, albums: albumCount, songs: songCount)
    }

    override init() {
        super.init()
        PlaybackDebugLogger.event("vm.lifecycle.init instance=\(ObjectIdentifier(self))")
        loadLibraryState()
        loadTrackOverlays()
        loadOngakuPlaylists()
        mediaLibraryAccess = systemMediaLibrary.currentAccessState()
        cloudServiceAccessStatus = systemMediaLibrary.currentCloudServiceAuthorizationStatus()
        appleMusicAccessStatus = systemMediaLibrary.currentCloudServiceAuthorizationStatus()
        configureAudioSessionObservers()
        configureRemoteCommands()
        setupSearchDebounce()
        setupAppLifecycleObservers()
        configureLibraryChangeObservers()
        configureOutputVolumeObservation()
    }

    deinit {
        initialBootstrapTask?.cancel()
        systemLibraryRefreshTask?.cancel()
        systemLibraryChangeDebounceTask?.cancel()
        deferredSystemLibraryRefreshTask?.cancel()
        deferredLocalLibraryScanTask?.cancel()
        localLibraryScanTask?.cancel()
        localLibraryChangeDebounceTask?.cancel()
        localLibraryMonitor?.cancel()
        librarySnapshotPersistenceTask?.cancel()
        searchTask?.cancel()
        appleMusicSearchTask?.cancel()
        upsamplingReloadTask?.cancel()
        localPlaybackLoadTask?.cancel()
        cacheMaintenanceTask?.cancel()
        precisionUpgradeTask?.cancel()
        systemAssetRecoveryTask?.cancel()
        preloadTrackTask?.cancel()
        vuTransitionTask?.cancel()
        updateTimer?.invalidate()
        visualizationTimer?.invalidate()
        effectAuditRefreshTimer?.invalidate()
        effectApplyTimer?.invalidate()
        headphoneSpatialApplyTimer?.invalidate()
        outputVolumeObservation?.invalidate()
        interruptionResumeTask?.cancel()
        systemTransportStartTask?.cancel()
        sessionActivationRetryTask?.cancel()
        playbackStartMonitorTask?.cancel()
        unexpectedPlaybackRecoveryTask?.cancel()
        print("[Playback] vm.lifecycle.deinit instance=\(ObjectIdentifier(self))")
        for registration in remoteCommandRegistrations {
            registration.command.removeTarget(registration.target)
        }
        MPMediaLibrary.default().endGeneratingLibraryChangeNotifications()
        NotificationCenter.default.removeObserver(self)
    }

    func startInitialBootstrapIfNeeded() {
        guard !hasStartedInitialBootstrap else { return }
        hasStartedInitialBootstrap = true
        isInitialLibraryLoading = true
        shouldRestorePlaybackFromInitialLibrary = true
        isLibraryBootstrapInProgress = mediaLibraryAccess == .authorized

        initialBootstrapTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await Task.yield()
            if self.mediaLibraryAccess == .authorized {
                // Publish the cache before starting a fresh MPMediaQuery. This
                // prevents both jobs from completing after playback begins.
                let restoredCachedLibrary = await self.loadCachedSystemLibrarySnapshotIfAvailable()
                // A cached library is already usable. Refresh its metadata in
                // the background without putting the relaunched app back into
                // a full-screen loading state.
                self.refreshSystemLibrary(showLoadingState: !restoredCachedLibrary)
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    _ = await self.ensureCloudServiceAuthorizationForProtectedPlayback(promptIfNeeded: false)
                }
            }

            Task { @MainActor [weak self] in
                await self?.refreshAppleMusicLibraryCapability()
            }
            if self.mediaLibraryAccess != .authorized {
                self.isLibraryBootstrapInProgress = false
                self.isInitialLibraryLoading = false
            }
        }
    }

    private func configureAudioSessionObservers() {
        let session = AVAudioSession.sharedInstance()
        // Session mutations now run on a worker. Never read/write view-model
        // state on a notification's arbitrary posting thread, or block that
        // thread waiting for MainActor while the media server is handling IPC.
        NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleAudioSessionInterruption($0) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AVAudioSession.mediaServicesWereResetNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleMediaServicesWereReset($0) }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification, object: session)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.handleAudioRouteChange($0) }
            .store(in: &cancellables)
    }

    private func setupAppLifecycleObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppWillResignActive),
            name: UIApplication.willResignActiveNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleThermalStateChange),
            name: ProcessInfo.thermalStateDidChangeNotification,
            object: nil
        )
    }

    private func configureLibraryChangeObservers() {
        let mediaLibrary = MPMediaLibrary.default()
        mediaLibrary.beginGeneratingLibraryChangeNotifications()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemMediaLibraryDidChange),
            name: .MPMediaLibraryDidChange,
            object: mediaLibrary
        )
        startLocalLibraryMonitoring()
    }

    private func startLocalLibraryMonitoring() {
        localLibraryMonitor?.cancel()
        localLibraryMonitor = nil

        LocalMediaManager.shared.ensureOngakuDirectoryExists()
        let directoryURL = LocalMediaManager.shared.libraryDirectoryURL
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            PlaybackDebugLogger.warning(
                "library.local.monitor_unavailable path=\(directoryURL.path)"
            )
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .extend, .attrib, .link, .rename, .revoke],
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.scheduleLocalLibraryChangeRefresh()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        localLibraryMonitor = source
        source.resume()
    }

    private func scheduleLocalLibraryChangeRefresh(delay: Duration = .milliseconds(700)) {
        localLibraryChangeDebounceTask?.cancel()
        localLibraryChangeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            self.localLibraryChangeDebounceTask = nil
            // Reopen the descriptor as well. A Files operation may replace or
            // rename the directory inode that the previous source observed.
            self.startLocalLibraryMonitoring()
            self.scanLocalLibrary()
        }
    }

    @objc private func handleSystemMediaLibraryDidChange() {
        guard mediaLibraryAccess == .authorized else { return }
        hasPendingSystemLibraryChange = true
        systemLibraryChangeDebounceTask?.cancel()
        systemLibraryChangeDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard let self, !Task.isCancelled else { return }
            self.systemLibraryChangeDebounceTask = nil
            self.scheduleDeferredSystemLibraryRefresh()
        }
    }

    private func scheduleDeferredSystemLibraryRefresh() {
        guard hasPendingSystemLibraryChange else { return }

        let canRefresh = mediaLibraryAccess == .authorized
            && !isPlaybackBusyForLibraryWork
            && !hasResidentLocalPlaybackTrack
            && systemLibraryRefreshTask == nil
        if canRefresh {
            hasPendingSystemLibraryChange = false
            deferredSystemLibraryRefreshTask?.cancel()
            deferredSystemLibraryRefreshTask = nil
            refreshSystemLibrary(showLoadingState: false)
            return
        }

        guard deferredSystemLibraryRefreshTask == nil else { return }
        deferredSystemLibraryRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, !Task.isCancelled else { return }
            self.deferredSystemLibraryRefreshTask = nil
            self.scheduleDeferredSystemLibraryRefresh()
        }
    }

    private func configureOutputVolumeObservation() {
        let session = AVAudioSession.sharedInstance()
        outputVolumeObservation = session.observe(\.outputVolume, options: [.initial, .new]) { [weak self] _, change in
            guard let self, let newValue = change.newValue else { return }
            Task { @MainActor [weak self] in
                guard let self, self.hasInitializedHiResPlaybackEngine else { return }
                self.hiResPlaybackEngine.setSystemOutputVolume(newValue)
            }
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        resumePendingInterruptionIfNeeded()
        refreshAudioOutputPreferences()
        guard hasInitializedHiResPlaybackEngine else { return }
        hiResPlaybackEngine.refreshLoudnessCompensationRoute()
        applyHeadphoneSpatialSettingsIfNeeded(immediately: true)
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
        PlaybackDebugLogger.event(
            "audio.route.changed reason=\(String(describing: reason)) enginePlaying=\(hiResPlaybackEngine.isPlaying)"
        )
        if playbackSource == .local,
           isPlaying,
           !isInterrupted,
           !hiResPlaybackEngine.isPlaying {
            scheduleUnexpectedLocalPlaybackRecovery(reason: "route_change")
        }
    }

    @objc private func handleAppDidBecomeActive() {
        isApplicationActive = true
        reconcileLocalPlaybackAfterForeground()
        resumePendingInterruptionIfNeeded()
        if playbackSource == .system {
            // Music may have resumed from the lock screen while this app was
            // suspended. Observe its current state, not our old pause window.
            clearForcedPausedWindow()
        }
        // アプリが前面に戻った際は、システム（ウィジェット）との乖離を防ぐため強制的に同期します。
        refreshPlaybackState()
        flushDeferredLibrarySnapshotIfPlaybackIsIdle(allowWhilePlaying: true)
        recoverEmptyLibraryAfterForeground()
        refreshNowPlayingAlbum()
        if hasInitializedHiResPlaybackEngine {
            hiResPlaybackEngine.setRealtimeAnalysisEnabled(true)
        }
        if isPlaying {
            startTimer()
        } else if !isPlaybackStarting {
            stopTimer(animateMeter: false)
        }
        updateNowPlayingInfo(force: true)
        resumeAutomaticQualityUpgradeIfNeeded()
        startSystemAssetRecoveryIfNeeded()
        scheduleDeferredSystemLibraryRefresh()
        scheduleLocalLibraryChangeRefresh(delay: .milliseconds(250))
    }

    /// Reconcile before refreshPlaybackState overwrites the pre-suspension intent.
    /// Foreground alone is not permission to take audio from another app.
    private func reconcileLocalPlaybackAfterForeground() {
        guard playbackSource == .local, hasInitializedHiResPlaybackEngine,
              hiResPlaybackEngine.hasTrack, !isInForcedPausedWindow else { return }
        audioRenderHealth = hiResPlaybackEngine.pollRenderHealth()
        let otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying
        if isInterrupted {
            guard wasPlayingBeforeSessionInterruption,
                  interruptedPlaybackSource == .local,
                  userPauseIntentToken == interruptionPauseIntentBaseline,
                  playbackPreparationToken == interruptionPlaybackPreparationBaseline,
                  !otherAudioPlaying else { return }
            // iOS may suspend us without delivering an interruption-end event.
            // Permit an activation attempt; the session still arbitrates calls.
            isInterrupted = false
            interruptionAllowsImmediateResume = false
            PlaybackDebugLogger.event("audio.foreground.reconcile missing_end=true")
        } else if isPlaying, !isPlaybackStarting,
                  interruptionResumeTask == nil, unexpectedPlaybackRecoveryTask == nil,
                  !hiResPlaybackEngine.isPlaying || audioRenderHealth.isStalled {
            interruptionGeneration &+= 1
            wasPlayingBeforeSessionInterruption = true
            interruptedPlaybackSource = .local
            interruptionPauseIntentBaseline = userPauseIntentToken
            interruptionPlaybackPreparationBaseline = playbackPreparationToken
            interruptionAllowsImmediateResume = false
            isPlaying = false
            PlaybackDebugLogger.event(
                "audio.foreground.reconcile stale_playing=true otherAudio=\(otherAudioPlaying) stalled=\(audioRenderHealth.isStalled)"
            )
        }
    }

    @objc private func handleAppWillResignActive() {
        guard isApplicationActive else { return }
        isApplicationActive = false
        stopVisualizationTimer()
        stopEffectAuditRefreshTimer()
        if hasInitializedHiResPlaybackEngine {
            hiResPlaybackEngine.setRealtimeAnalysisEnabled(false)
        }
        // The app's active audio session allows background conversion while
        // local playback continues. Music-owned playback cannot grant us that.
        if playbackSource != .local || !isPlaying {
            cancelOptionalQualityWork(reason: "application_inactive")
        }
        // アプリがバックグラウンドに回る直前に、現在の正しい状態をシステムに刻み込みます。
        updateNowPlayingInfo(force: true)
    }

    @objc private func handleAppDidEnterBackground() {
        // willResignActive normally performs this first, but repeat it here so
        // unusual lifecycle ordering can never leave visualization DSP active.
        stopVisualizationTimer()
        stopEffectAuditRefreshTimer()
        if hasInitializedHiResPlaybackEngine {
            hiResPlaybackEngine.setRealtimeAnalysisEnabled(false)
        }
        guard playbackSource == .local, isPlaying, hiResPlaybackEngine.hasTrack else {
            PlaybackDebugLogger.event("app.background.enter playback=inactive")
            return
        }

        // A running local player already owns its playback session. Repeating
        // synchronous activation on screen lock can block UI and contend with
        // an interruption; lifecycle changes alone must not take audio back.
        PlaybackDebugLogger.event(
            "app.background.enter playback=local enginePlaying=\(hiResPlaybackEngine.isPlaying) sessionUnchanged=true \(HiResPlaybackEngine.processMemoryDiagnostic)"
        )
    }

    @objc private func handleMemoryWarning() {
        enterMemoryOptimizedMode(.constrained, reason: "system_memory_warning")
    }

    @objc private func handleThermalStateChange() {
        let thermalState = ProcessInfo.processInfo.thermalState
        guard thermalState == .serious || thermalState == .critical else { return }
        cancelOptionalQualityWork(reason: "thermal_\(thermalState.rawValue)")
    }

    private func cancelOptionalQualityWork(reason: String) {
        cancelSystemAssetRecovery()
        precisionUpgradeTask?.cancel()
        precisionUpgradeTask = nil
        preloadTrackTask?.cancel()
        preloadTrackTask = nil
        hiResPlaybackEngine.cancelBackgroundPreparation()
        PlaybackDebugLogger.warning(
            "audio.optional_work.cancelled reason=\(reason) \(HiResPlaybackEngine.processMemoryDiagnostic)"
        )
    }

    /// Shrinks optional work without stopping or rebuilding the audible track.
    /// This is deliberately idempotent because a memory warning may arrive
    /// after the proactive monitor has already entered constrained mode.
    private func enterMemoryOptimizedMode(
        _ mode: AudioMemorySafetyMode,
        reason: String,
        cancelCurrentQualityUpgrade: Bool = true
    ) {
        let previousMode = memorySafetyMode
        memorySafetyMode = mode
        isMemoryOptimizedMode = mode.disablesHeavyDSP
        upsamplingMode = mode.automaticUpsamplingMode
        memoryRecoveryStableSampleCount = 0
        if previousMode != mode {
            // Give autorelease pools, media-library work, and background apps
            // time to release their allocations before considering an upgrade.
            memoryRecoveryNotBefore = CFAbsoluteTimeGetCurrent() + 15
        }

        preloadTrackTask?.cancel()
        preloadTrackTask = nil
        if cancelCurrentQualityUpgrade {
            precisionUpgradeTask?.cancel()
            precisionUpgradeTask = nil
        }

        // Library snapshots and media queries are optional while audio is
        // resident. Releasing them here avoids an audio-memory event turning
        // into a second peak on the main actor.
        cancelLibraryWorkForPlayback(force: true)
        if !systemSongs.isEmpty { deferredLibrarySnapshot = nil }

        if hasInitializedHiResPlaybackEngine {
            hiResPlaybackEngine.setMemorySafetyMode(mode)
            hiResPlaybackEngine.releasePreloadedResources()
            hiResPlaybackEngine.releaseBaseBufferForMemoryPressure()
            hiResPlaybackEngine.apply(effectSettings: playbackEffectSettings)
        }

        if previousMode != mode {
            let availableMB = HiResPlaybackEngine.availableProcessMemoryBytes / (1_024 * 1_024)
            PlaybackDebugLogger.warning(
                "memory.safety.enter reason=\(reason) mode=\(String(describing: mode)) availableMB=\(availableMB)"
            )
        }
    }

    private func applyProactiveMemorySafetyIfNeeded() {
        let availableMemory = HiResPlaybackEngine.availableProcessMemoryBytes
        guard availableMemory > 0 else { return }

        if availableMemory <= HiResPlaybackEngine.proactiveMemoryPressureThresholdBytes {
            memoryRecoveryStableSampleCount = 0
            enterMemoryOptimizedMode(.constrained, reason: "low_process_headroom")
            return
        }

        guard memorySafetyMode != .normal else {
            memoryRecoveryStableSampleCount = 0
            return
        }
        guard CFAbsoluteTimeGetCurrent() >= memoryRecoveryNotBefore,
              availableMemory >= HiResPlaybackEngine.memoryRecoveryThresholdBytes else {
            memoryRecoveryStableSampleCount = 0
            return
        }

        // This method runs every two seconds. Require five consecutive healthy
        // samples so a short-lived allocation dip cannot trigger a costly
        // offline rebuild.
        memoryRecoveryStableSampleCount += 1
        guard memoryRecoveryStableSampleCount >= 5 else { return }
        memoryRecoveryStableSampleCount = 0

        // Physical RAM is only an initial conservative hint. Recovery is based
        // on current process headroom and the exact allocation estimate for
        // the active track, so a 4 GB device is not permanently locked out of
        // Precision Sinc after temporary pressure clears.
        let recoveryMode = AudioMemorySafetyMode.normal
        guard recoveryMode != memorySafetyMode else { return }

        if recoveryMode == .normal,
           playbackSource == .local,
           hiResPlaybackEngine.hasTrack,
           let currentURL = hiResPlaybackEngine.currentAudioURL {
            do {
                try HiResPlaybackEngine.validateOfflinePreparation(
                    url: musicPlaybackSnapshot?.url ?? currentURL,
                    upsamplingMode: recoveryMode.automaticUpsamplingMode)
            } catch {
                // Defer any failed preflight without mistaking unreadable metadata
                // for a capacity limit or interrupting native playback.
                memoryRecoveryNotBefore = CFAbsoluteTimeGetCurrent() + 30
                PlaybackDebugLogger.event(
                    "memory.safety.recovery_deferred \(AudioPreparationFailure.diagnostic(error, fallbackStage: .offlinePreflight))")
                return
            }
        }

        recoverMemorySafetyMode(to: recoveryMode, availableMemory: availableMemory)
    }

    private func recoverMemorySafetyMode(
        to mode: AudioMemorySafetyMode,
        availableMemory: UInt64
    ) {
        let previousMode = memorySafetyMode
        memorySafetyMode = mode
        isMemoryOptimizedMode = mode.disablesHeavyDSP
        upsamplingMode = mode.automaticUpsamplingMode
        memoryRecoveryNotBefore = 0

        if hasInitializedHiResPlaybackEngine {
            hiResPlaybackEngine.setMemorySafetyMode(mode)
            hiResPlaybackEngine.apply(effectSettings: playbackEffectSettings)
        }

        let availableMB = availableMemory / (1_024 * 1_024)
        PlaybackDebugLogger.event(
            "memory.safety.recovered from=\(String(describing: previousMode)) mode=\(String(describing: mode)) availableMB=\(availableMB)"
        )

        guard mode == .normal,
              playbackSource == .local,
              hiResPlaybackEngine.hasTrack,
              hiResPlaybackEngine.isPlaying,
              hiResPlaybackEngine.activeUpsamplingMode != mode.automaticUpsamplingMode,
              let songID = selectedSystemSongID,
              let currentURL = hiResPlaybackEngine.currentAudioURL else {
            return
        }

        startPrecisionSincUpgrade(
            songID: songID,
            assetURL: currentURL,
            targetUpsampling: mode.automaticUpsamplingMode
        )
    }

    func setEffectEnabled(_ isEnabled: Bool, for kind: RealtimeAudioEffectKind) {
        guard let index = effectSettings.firstIndex(where: { $0.kind == kind }) else { return }
        effectSettings[index].isEnabled = isEnabled
        scheduleEffectApply(after: 0.30)
    }

    var visibleEffectSettings: [RealtimeAudioEffectSetting] {
        let visibleKinds = AudioEffectModuleRegistry.activeKinds(for: selectedEffectPageTab)
        return effectSettings.filter { visibleKinds.contains($0.kind) }
    }

    func selectEffectPageTab(_ tab: AudioEffectPageTab) {
        guard selectedEffectPageTab != tab else { return }
        selectedEffectPageTab = tab
        UserDefaults.standard.set(tab.rawValue, forKey: Self.selectedEffectPageTabDefaultsKey)

        effectApplyTimer?.invalidate()
        effectApplyTimer = nil
        hiResPlaybackEngine.setEffectsBypassed(tab == .off)
        hiResPlaybackEngine.setAutomaticDSPStrength(playbackAutomaticDSPStrength, effectSettings: playbackEffectSettings)
        applyRealtimeEffects(skipAutoPeakAdjustment: true)

        isSpatialProcessing = true
        applyHeadphoneSpatialSettingsIfNeeded(immediately: true)
    }

    func setEffectParameter(_ value: Double, key: String, for kind: RealtimeAudioEffectKind) {
        guard value.isFinite,
              let index = effectSettings.firstIndex(where: { $0.kind == kind }) else { return }

        let oldValue = effectSettings[index].parameters[key] ?? value
        effectSettings[index].parameters[key] = value
        
        // If the value is being manually reduced, mark the time to suppress auto-peak adjustment.
        // This prevents the "sticky" slider feel and unwanted reduction of other effect parameters.
        if value < oldValue {
            lastManualParameterReductionTime = CFAbsoluteTimeGetCurrent()
        }
        
        applyRealtimeEffects()
        persistLibraryState()
    }

    func refreshAudioOutputPreferences() {
        audioOutputOverride = AudioOutputPolicy.currentOverride
        loudnessCompensationEnabled = AudioOutputPolicy.compensationEnabled
    }

    func setAudioOutputOverride(_ value: AudioOutputOverride) {
        AudioOutputPolicy.currentOverride = value
        audioOutputOverride = value
        guard hasInitializedHiResPlaybackEngine else { return }
        hiResPlaybackEngine.refreshLoudnessCompensationRoute()
        applyHeadphoneSpatialSettingsIfNeeded(immediately: true)
    }

    func setLoudnessCompensationEnabled(_ enabled: Bool) {
        AudioOutputPolicy.compensationEnabled = enabled
        loudnessCompensationEnabled = enabled
        guard hasInitializedHiResPlaybackEngine else { return }
        hiResPlaybackEngine.refreshLoudnessCompensationRoute()
    }

    func setHeadphoneSpatialEnabled(_ isEnabled: Bool) {
        headphoneSpatialSettings.isEnabled = isEnabled
        isSpatialProcessing = true
        headphoneSpatialApplyTimer?.invalidate()
        headphoneSpatialApplyTimer = Timer.scheduledTimer(
            timeInterval: 0.30,
            target: self,
            selector: #selector(handleHeadphoneSpatialToggleTimer),
            userInfo: nil,
            repeats: false
        )
    }

    func setHeadphoneSpatialParameter(_ value: Double, key: String) {
        switch key {
        case "spatial":
            headphoneSpatialSettings.spatial = min(max(value, 0.0), 1.0)
        case "crossfeed":
            headphoneSpatialSettings.crossfeed = min(max(value, 0.0), 1.0)
        default:
            return
        }
        scheduleHeadphoneSpatialSettingsApply()
    }

    func setHeadphoneHRTFPreset(_ preset: HeadphoneHRTFPreset) {
        guard headphoneSpatialSettings.preset != preset else { return }
        headphoneSpatialSettings.preset = preset
        scheduleHeadphoneSpatialPresetApply()
        persistLibraryState()
    }

    func setAutomaticDSPStrength(_ value: Double) {
        guard value.isFinite else { return }
        let clamped = min(max(value, 0.0), 1.5)
        guard abs(clamped - automaticDSPStrength) >= 0.001 else { return }
        automaticDSPStrength = clamped
        hiResPlaybackEngine.setAutomaticDSPStrength(playbackAutomaticDSPStrength, effectSettings: playbackEffectSettings)
        refreshPlaybackState()
        persistLibraryState()
    }

    func setAutomaticDSPVoicing(_ voicing: AutomaticDSPVoicing) {
        guard automaticDSPVoicing != voicing else { return }
        automaticDSPVoicing = voicing
        hiResPlaybackEngine.setAutomaticDSPVoicing(voicing)
        persistLibraryState()
    }

    func toggleABReferenceMode() {
        isABReferenceMode.toggle()
        hiResPlaybackEngine.apply(effectSettings: playbackEffectSettings)
        hiResPlaybackEngine.setAutomaticDSPStrength(
            playbackAutomaticDSPStrength,
            effectSettings: playbackEffectSettings
        )
        refreshEffectAuditSummary()
    }

    func setUpsamplingMode(_ mode: UpsamplingMode) {
        // Retained for source compatibility with older callers. Upsampling is
        // selected automatically from the current memory safety mode.
        let automaticMode = memorySafetyMode.automaticUpsamplingMode
        guard upsamplingMode != automaticMode else { return }
        
        upsamplingMode = automaticMode
        
        // 以前の切り替え処理が進行中であればキャンセルする
        upsamplingReloadTask?.cancel()
        
        upsamplingReloadTask = Task { @MainActor in
            persistLibraryState()
            
            // 即座に現在の曲へ反映させる
            if playbackSource == .local && hiResPlaybackEngine.hasTrack {
                await reloadCurrentLocalTrackForUpsamplingModeChange()
            }
        }
    }

    var preparedAudioCacheSummary: String {
        guard preparedAudioCacheStatistics.maximumByteCount > 0 else {
            return L10n.tr("settings.audio_cache.loading")
        }
        let current = Self.formattedByteCount(preparedAudioCacheStatistics.byteCount)
        let maximum = Self.formattedByteCount(preparedAudioCacheStatistics.maximumByteCount)
        return L10n.tr(
            "settings.audio_cache.summary",
            current,
            maximum,
            preparedAudioCacheStatistics.entryCount
        )
    }

    func refreshPreparedAudioCacheStatistics() {
        guard !isClearingPreparedAudioCache else { return }
        cacheMaintenanceTask?.cancel()
        cacheMaintenanceTask = Task { @MainActor [weak self] in
            async let prepared = HiResPlaybackEngine.preparedAudioCacheStatistics()
            async let remote = RemoteAudioCache.shared.statistics()
            let (preparedStatistics, remoteStatistics) = await (prepared, remote)
            let statistics = Self.combinedCacheStatistics(
                prepared: preparedStatistics,
                remote: remoteStatistics
            )
            guard let self, !Task.isCancelled else { return }
            self.preparedAudioCacheStatistics = statistics
            self.cacheMaintenanceTask = nil
        }
    }

    func clearPreparedAudioCache() {
        guard !isClearingPreparedAudioCache else { return }
        cacheMaintenanceTask?.cancel()
        preloadTrackTask?.cancel()
        precisionUpgradeTask?.cancel()
        isClearingPreparedAudioCache = true
        if hasInitializedHiResPlaybackEngine {
            hiResPlaybackEngine.releasePreloadedResources()
        }
        cacheMaintenanceTask = Task { @MainActor [weak self] in
            async let clearPrepared: Void = HiResPlaybackEngine.clearPreparedAudioDiskCache()
            async let clearRemote: Void = RemoteAudioCache.shared.clear()
            _ = await (clearPrepared, clearRemote)
            guard let self, !Task.isCancelled else { return }
            async let prepared = HiResPlaybackEngine.preparedAudioCacheStatistics()
            async let remote = RemoteAudioCache.shared.statistics()
            let (preparedStatistics, remoteStatistics) = await (prepared, remote)
            self.preparedAudioCacheStatistics = Self.combinedCacheStatistics(
                prepared: preparedStatistics,
                remote: remoteStatistics
            )
            self.isClearingPreparedAudioCache = false
            self.cacheMaintenanceTask = nil
        }
    }

    nonisolated private static func formattedByteCount(_ byteCount: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(min(byteCount, UInt64(Int64.max))),
            countStyle: .file
        )
    }

    nonisolated private static func combinedCacheStatistics(
        prepared: PreparedAudioCacheStatistics,
        remote: RemoteAudioCacheStatistics
    ) -> PreparedAudioCacheStatistics {
        PreparedAudioCacheStatistics(
            byteCount: prepared.byteCount + remote.byteCount,
            entryCount: prepared.entryCount + remote.entryCount,
            maximumByteCount: prepared.maximumByteCount + remote.maximumByteCount
        )
    }

    func requestSystemLibraryAccess() {
        guard !isRequestingSystemLibraryAccess else { return }
        isRequestingSystemLibraryAccess = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isRequestingSystemLibraryAccess = false }

            mediaLibraryAccess = await systemMediaLibrary.requestAccess()
            if mediaLibraryAccess == .authorized {
                refreshSystemLibrary()
                _ = await ensureCloudServiceAuthorizationForProtectedPlayback(promptIfNeeded: false)
            } else {
                isLibraryBootstrapInProgress = false
                isInitialLibraryLoading = false
                if systemLibraryFeedback == .working {
                    systemLibraryFeedback = .notice(L10n.tr("settings.library_feedback.permission"))
                }
            }
        }
    }

    func reloadSystemLibrary() {
        if let reason = libraryActionUnavailableReason {
            systemLibraryFeedback = .notice(reason)
            return
        }
        if hasResidentLocalPlaybackTrack {
            systemLibraryFeedback = .notice(L10n.tr("settings.library_feedback.resident"))
            return
        }
        systemLibraryFeedback = .working
        guard mediaLibraryAccess == .authorized else {
            requestSystemLibraryAccess()
            return
        }
        refreshSystemLibrary()
    }

    func scanLocalLibraryFromSettings() {
        if let reason = libraryActionUnavailableReason {
            localLibraryFeedback = .notice(reason)
            return
        }
        localLibraryFeedback = .working
        scanLocalLibrary()
    }

    private var libraryActionUnavailableReason: String? {
        if isPlaybackBusyForLibraryWork { return L10n.tr("settings.library_feedback.playback") }
        if systemLibraryRefreshTask != nil || isScanningLocalLibrary || isRequestingSystemLibraryAccess {
            return L10n.tr("settings.library_feedback.busy")
        }
        return nil
    }

    func requestAppleMusicAccess() {
        guard !isRequestingAppleMusicAccess else { return }
        isRequestingAppleMusicAccess = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { isRequestingAppleMusicAccess = false }

            appleMusicAccessStatus = await systemMediaLibrary.requestCloudServiceAuthorization()
            await refreshAppleMusicLibraryCapability()
            if hasActiveSearch {
                performSearch()
            }
        }
    }

    private func refreshAppleMusicLibraryCapability() async {
        guard appleMusicAccessStatus == .authorized else {
            canModifyAppleMusicLibrary = false
            return
        }

        do {
            let subscription = try await MusicSubscription.current
            canModifyAppleMusicLibrary = subscription.hasCloudLibraryEnabled
        } catch {
            canModifyAppleMusicLibrary = false
        }
    }

    func refreshSystemLibrary(showLoadingState: Bool = true, recoveringEmptyLibrary: Bool = false) {
        let isLocalPlaybackActive = playbackSource == .local && isPlaying && hasInitializedHiResPlaybackEngine
        let isSystemPlaybackActive = playbackSource == .system && isSystemPlayerConfigured && systemPlayer.playbackState == .playing

        // MPMediaQuery and metadata expansion can consume enough CPU/memory to
        // starve the realtime renderer. Library refresh is never urgent enough
        // to compete with playback or its startup transition.
        let canRecoverEmptyLibrary = recoveringEmptyLibrary && systemSongs.isEmpty
            && isApplicationActive && !isProcessing && !isPlaybackStarting
        if !canRecoverEmptyLibrary
            && (isPlaybackBusyForLibraryWork || isLocalPlaybackActive || hasResidentLocalPlaybackTrack || isSystemPlaybackActive) {
            if systemLibraryFeedback == .working {
                systemLibraryFeedback = .notice(L10n.tr("settings.library_feedback.interrupted"))
            }
            isLibraryBootstrapInProgress = false
            isInitialLibraryLoading = false
            libraryLoadingMessage = nil
            return
        }

        // Coalesce duplicate requests from startup, permission callbacks, and
        // scene transitions. A second scan only wastes I/O and CPU.
        guard systemLibraryRefreshTask == nil else { return }

        let shouldRestorePlayback = shouldRestorePlaybackFromInitialLibrary
            && !isLocalPlaybackActive
            && !isSystemPlaybackActive
        shouldRestorePlaybackFromInitialLibrary = false
        systemLibraryRefreshTask?.cancel()
        isLibraryBootstrapInProgress = showLoadingState
            && !isLocalPlaybackActive
            && !isSystemPlaybackActive
        systemLibraryRefreshGeneration &+= 1
        let generation = systemLibraryRefreshGeneration
        let library = systemMediaLibrary

        systemLibraryRefreshTask = Task { [weak self] in
            if showLoadingState {
                self?.libraryLoadingMessage = L10n.tr("settings.system_library_loading")
            }
            defer {
                if let self, generation == self.systemLibraryRefreshGeneration {
                    self.isLibraryBootstrapInProgress = false
                    self.isInitialLibraryLoading = false
                    self.systemLibraryRefreshTask = nil
                    self.libraryLoadingMessage = nil
                    if self.systemLibraryFeedback == .working {
                        self.systemLibraryFeedback = .notice(L10n.tr("settings.library_feedback.interrupted"))
                    }
                    // A system-only snapshot does not contain files stored in
                    // Documents/Ongaku. Always merge those files back after a
                    // reload so local songs cannot disappear from the UI.
                    self.scanLocalLibrary()
                }
            }
            let fastWorker = Task.detached(priority: .background) {
                try Self.buildFastSystemLibrarySnapshot(using: library)
            }
            let fastSnapshot: SystemLibrarySnapshot
            do {
                fastSnapshot = try await withTaskCancellationHandler {
                    try await fastWorker.value
                } onCancel: {
                    fastWorker.cancel()
                }
            } catch {
                if !Task.isCancelled, let self,
                   generation == self.systemLibraryRefreshGeneration {
                    self.hasPendingSystemLibraryChange = true
                    PlaybackDebugLogger.warning("library.snapshot.failed error=\(error.localizedDescription)")
                }
                return
            }

            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard generation == self.systemLibraryRefreshGeneration else { return }

            if !showLoadingState, fastSnapshot.songs.isEmpty,
               (self.systemSongs.contains { $0.url == nil }
                || self.deferredLibrarySnapshot?.songs.contains { $0.url == nil } == true) {
                self.hasPendingSystemLibraryChange = true
                PlaybackDebugLogger.warning("library.snapshot.rejected reason=empty_automatic_refresh")
                return
            }

            self.applySystemLibrarySnapshot(fastSnapshot, restorePlayback: shouldRestorePlayback, isFinal: true)
            self.persistCachedSystemLibrarySnapshot(fastSnapshot)
            if self.systemLibraryFeedback == .working {
                self.systemLibraryFeedback = .completed(fastSnapshot.songs.count)
            }

            // One song query supplies every navigation index. Independent
            // artist/album queries can disagree during a Music library sync.
            PlaybackDebugLogger.event("library.snapshot songs=\(fastSnapshot.songs.count) artists=\(fastSnapshot.artists.count) albums=\(fastSnapshot.albums.count)")
            self.systemLibraryRefreshTask = nil
        }
    }

    func scanLocalLibrary() {
        guard !isScanningLocalLibrary else { return }
        guard !isPlaybackBusyForLibraryWork,
              systemLibraryRefreshTask == nil else {
            scheduleDeferredLocalLibraryScan()
            return
        }

        deferredLocalLibraryScanTask?.cancel()
        deferredLocalLibraryScanTask = nil

        isScanningLocalLibrary = true
        libraryLoadingMessage = L10n.tr("settings.local_library_scanning")
        localLibraryScanTask?.cancel()
        localLibraryScanGeneration &+= 1
        let generation = localLibraryScanGeneration
        localLibraryScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.localLibraryScanGeneration == generation {
                    self.isScanningLocalLibrary = false
                    self.localLibraryScanTask = nil
                    self.libraryLoadingMessage = nil
                    if self.localLibraryFeedback == .working {
                        self.localLibraryFeedback = .notice(L10n.tr("settings.library_feedback.interrupted"))
                    }
                }
            }

            let localWorker = Task.detached(priority: .background) {
                await LocalMediaManager.shared.scanLocalFiles()
            }
            let localTracks = await withTaskCancellationHandler {
                await localWorker.value
            } onCancel: {
                localWorker.cancel()
            }
            guard !Task.isCancelled, self.localLibraryScanGeneration == generation else { return }

            self.localLibraryTracks = localTracks

            let baseSnapshot = SystemLibrarySnapshot(
                songs: (self.deferredLibrarySnapshot?.songs ?? self.systemSongs).filter { $0.url == nil }
            )
            let mergedSnapshot = Self.mergedSystemLibrarySnapshot(base: baseSnapshot, with: localTracks)
            self.applySystemLibrarySnapshot(mergedSnapshot, restorePlayback: false, isFinal: false)
            self.persistCachedSystemLibrarySnapshot(mergedSnapshot)
            if self.localLibraryFeedback == .working {
                self.localLibraryFeedback = .completed(localTracks.count)
            }
        }
    }

    /// A transfer can finish while the system library is still rebuilding or
    /// while playback owns the audio engine. Preserve that scan request and
    /// run it as soon as library work becomes safe instead of silently losing it.
    private func scheduleDeferredLocalLibraryScan() {
        guard deferredLocalLibraryScanTask == nil else { return }
        deferredLocalLibraryScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                if !self.isPlaybackBusyForLibraryWork,
                   !self.isScanningLocalLibrary,
                   self.systemLibraryRefreshTask == nil {
                    self.deferredLocalLibraryScanTask = nil
                    self.scanLocalLibrary()
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func addAppleMusicSongToLibrary(_ result: AppleMusicCatalogSongResult) {
        guard let song = appleMusicSongLookup[result.id] else { return }
        addAppleMusicItem(song, itemID: result.id)
    }

    func addAppleMusicAlbumToLibrary(_ result: AppleMusicCatalogAlbumResult) {
        guard let album = appleMusicAlbumLookup[result.id] else { return }
        addAppleMusicItem(album, itemID: result.id)
    }

    private func addAppleMusicItem<Item: MusicLibraryAddable>(_ item: Item, itemID: String) {
        guard appleMusicAccessStatus == .authorized else {
            errorMessage = L10n.tr("error.apple_music_access_required_for_add")
            return
        }

        isAddingAppleMusicItemIDs.insert(itemID)

        Task { @MainActor in
            defer { isAddingAppleMusicItemIDs.remove(itemID) }

            do {
                try await MusicLibrary.shared.add(item)
                addedAppleMusicItemIDs.insert(itemID)
                await refreshAppleMusicLibraryCapability()
            } catch {
                errorMessage = L10n.tr("error.apple_music_add_failed", error.localizedDescription)
            }
        }
    }

    private func ensureCloudServiceAuthorizationForProtectedPlayback(promptIfNeeded: Bool) async -> Bool {
        let currentStatus = systemMediaLibrary.currentCloudServiceAuthorizationStatus()
        cloudServiceAccessStatus = currentStatus

        switch currentStatus {
        case .authorized:
            return true
        case .notDetermined where promptIfNeeded:
            let requestedStatus = await systemMediaLibrary.requestCloudServiceAuthorization()
            cloudServiceAccessStatus = requestedStatus
            return requestedStatus == .authorized
        default:
            return false
        }
    }

    private func logProtectedPlaybackDiagnostics(_ label: String, queueItems: [MPMediaItem] = []) {
        let nowPlayingID = systemPlayer.nowPlayingItem.map { String($0.persistentID) } ?? "nil"
        let queueIDs = queueItems.map { String($0.persistentID) }.joined(separator: ",")
        print("""
        [SystemPlayer][\(label)] auth=\(cloudServiceAccessStatus.rawValue) \
        playbackState=\(systemPlayer.playbackState.rawValue) \
        nowPlayingID=\(nowPlayingID) \
        expectedID=\(selectedSystemSongID.map(String.init) ?? "nil") \
        observedStoreID=\(systemPlayer.nowPlayingItem?.playbackStoreID ?? "nil") \
        expectedStoreID=\(systemRequestedStoreID) \
        queueCount=\(queueItems.count) \
        queueIDs=[\(queueIDs)]
        """)
    }

    func setEffectScreenActive(_ isActive: Bool) {
        isEffectScreenActive = isActive
        if isActive {
            scheduleEffectAuditRefresh(after: 0.8)
        } else {
            stopEffectAuditRefreshTimer()
        }
    }

    func songs(for artist: SystemArtist) -> [SystemSong] {
        systemSongs.filter { SystemLibraryIndex.contains($0, artist: artist) }
    }

    func findArtist(for album: SystemAlbum) -> SystemArtist? {
        // 曲と同じ演奏者名で、現在のアーティスト一覧へ戻します。
        let albumSongs = songs(for: album)
        if let firstSong = albumSongs.first {
            return systemArtists.first(where: { $0.name == firstSong.artist })
        }
        return systemArtists.first(where: { $0.name == album.artist })
    }

    func albums(for artist: SystemArtist) -> [SystemAlbum] {
        let artistSongs = songs(for: artist)
        let albumIDs = Set(artistSongs.compactMap(\.albumID))
        let fallbackSongs = artistSongs.filter { $0.albumID == nil }
        return systemAlbums.filter { album in
            albumIDs.contains(album.id) || fallbackSongs.contains { SystemLibraryIndex.contains($0, album: album) }
        }
    }

    func songs(for album: SystemAlbum) -> [SystemSong] {
        let indexedSongs = systemSongs.filter { SystemLibraryIndex.contains($0, album: album) }
        let albumSongs = indexedSongs.isEmpty
            ? systemQueue.filter { SystemLibraryIndex.contains($0, album: album) }
            : indexedSongs

        return SystemLibraryIndex.orderedAlbumSongs(albumSongs)
    }

    func songs(in playlist: SystemPlaylist) -> [SystemSong] {
        systemMediaLibrary.songs(in: playlist)
    }

    func albumArtwork(for album: SystemAlbum, size: CGSize = CGSize(width: 280, height: 280)) -> UIImage? {
        guard album.localIdentity == nil else { return nil }
        return systemMediaLibrary.artwork(for: album, size: size)
    }

    func albumArtworkURLs(for album: SystemAlbum) -> [URL] {
        songs(for: album).compactMap(\.url).filter(\.isFileURL)
    }

    func songArtwork(for song: SystemSong, size: CGSize = CGSize(width: 80, height: 80)) -> UIImage? {
        guard song.url == nil else { return nil }
        return systemMediaLibrary.artwork(for: song.id, size: size)
    }

    func overlay(for song: SystemSong) -> LibraryTrackOverlay {
        trackOverlays[song.overlayKey] ?? .empty(for: song)
    }

    func setFavorite(_ isFavorite: Bool, for song: SystemSong) {
        guard song.supports(.metadataOverlay) else { return }
        updateOverlay(for: song) { overlay in
            overlay.isFavorite = isFavorite
        }
    }

    func setRating(_ rating: Int, for song: SystemSong) {
        guard song.supports(.metadataOverlay) else { return }
        updateOverlay(for: song) { overlay in
            overlay.rating = min(max(rating, 0), 5)
        }
    }

    func setDisplayTags(_ tags: [String], for song: SystemSong) {
        guard song.supports(.metadataOverlay) else { return }
        updateOverlay(for: song) { overlay in
            overlay.displayTags = tags
        }
        if hasActiveSearch { performSearch() }
    }

    @discardableResult
    func createOngakuPlaylist(named name: String) -> UUID? {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else { return nil }
        var playlist = OngakuPlaylist(
            id: UUID(),
            name: normalizedName,
            trackKeys: [],
            createdAt: .now,
            updatedAt: .now
        )
        playlist.normalize()
        ongakuPlaylists.append(playlist)
        ongakuPlaylists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        persistOngakuPlaylists()
        return playlist.id
    }

    func deleteOngakuPlaylist(_ playlist: OngakuPlaylist) {
        ongakuPlaylists.removeAll { $0.id == playlist.id }
        persistOngakuPlaylists()
    }

    func add(_ song: SystemSong, to playlistID: UUID) {
        guard let index = ongakuPlaylists.firstIndex(where: { $0.id == playlistID }),
              !ongakuPlaylists[index].trackKeys.contains(song.overlayKey) else { return }
        ongakuPlaylists[index].trackKeys.append(song.overlayKey)
        ongakuPlaylists[index].updatedAt = .now
        persistOngakuPlaylists()
    }

    func remove(_ song: SystemSong, from playlistID: UUID) {
        guard let index = ongakuPlaylists.firstIndex(where: { $0.id == playlistID }) else { return }
        ongakuPlaylists[index].trackKeys.removeAll { $0 == song.overlayKey }
        ongakuPlaylists[index].updatedAt = .now
        persistOngakuPlaylists()
    }

    func songs(in playlist: OngakuPlaylist) -> [SystemSong] {
        let songsByKey = Dictionary(
            systemSongs.map { ($0.overlayKey, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return playlist.trackKeys.compactMap { songsByKey[$0] }
    }

    func contains(_ song: SystemSong, in playlist: OngakuPlaylist) -> Bool {
        playlist.trackKeys.contains(song.overlayKey)
    }

    func ongakuPlaylist(id: UUID) -> OngakuPlaylist? {
        ongakuPlaylists.first { $0.id == id }
    }

    func syncTrackOverlays() -> [DeviceSyncTrackOverlay] {
        systemSongs.compactMap { song in
            guard song.source == .systemMusic,
                  let overlay = trackOverlays[song.overlayKey] else { return nil }
            return DeviceSyncTrackOverlay(
                sourceKey: overlay.trackKey,
                title: song.title,
                artist: song.artist,
                album: song.album,
                duration: song.duration,
                isFavorite: overlay.isFavorite,
                rating: overlay.rating,
                playCount: overlay.playCount,
                skipCount: overlay.skipCount,
                lastPlayedAt: overlay.lastPlayedAt,
                displayTags: overlay.displayTags,
                updatedAt: overlay.updatedAt
            )
        }
    }

    func syncPlaylistOverlays() -> [DeviceSyncPlaylistOverlay] {
        let songsByKey = Dictionary(
            systemSongs.map { ($0.overlayKey, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        return ongakuPlaylists.map { playlist in
            DeviceSyncPlaylistOverlay(
                id: playlist.id,
                name: playlist.name,
                tracks: playlist.trackKeys.compactMap { key in
                    guard let song = songsByKey[key] else { return nil }
                    return DeviceSyncTrackReference(
                        sourceKey: song.overlayKey,
                        title: song.title,
                        artist: song.artist,
                        album: song.album,
                        duration: song.duration
                    )
                },
                createdAt: playlist.createdAt,
                updatedAt: playlist.updatedAt
            )
        }
    }

    func mergeSyncedPlaylistOverlays(_ remotePlaylists: [DeviceSyncPlaylistOverlay]) {
        var didChange = false
        for remote in remotePlaylists {
            if let local = ongakuPlaylists.first(where: { $0.id == remote.id }),
               local.updatedAt >= remote.updatedAt {
                continue
            }

            var matchedKeys: [String] = []
            var canApply = true
            for reference in remote.tracks {
                let matches = systemSongs.filter(reference.matches)
                guard matches.count == 1, let song = matches.first else {
                    canApply = false
                    break
                }
                matchedKeys.append(song.overlayKey)
            }
            guard canApply else { continue }

            var merged = OngakuPlaylist(
                id: remote.id,
                name: remote.name,
                trackKeys: matchedKeys,
                createdAt: remote.createdAt,
                updatedAt: remote.updatedAt
            )
            merged.normalize()
            guard !merged.name.isEmpty else { continue }
            if let index = ongakuPlaylists.firstIndex(where: { $0.id == remote.id }) {
                ongakuPlaylists[index] = merged
            } else {
                ongakuPlaylists.append(merged)
            }
            didChange = true
        }
        if didChange {
            ongakuPlaylists.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            persistOngakuPlaylists()
        }
    }

    func mergeSyncedTrackOverlays(
        _ remoteOverlays: [DeviceSyncTrackOverlay]
    ) -> DeviceSyncOverlayReceipt {
        var didChange = false
        var receiptItems: [DeviceSyncOverlayReceiptItem] = []
        var ignoredCount = 0
        for remote in remoteOverlays {
            let matches = systemSongs.filter {
                $0.source == .systemMusic && remote.matches($0)
            }
            // Ambiguous metadata must never update multiple unrelated songs.
            guard matches.count == 1, let song = matches.first else {
                ignoredCount += 1
                continue
            }

            let existing = trackOverlays[song.overlayKey]
            var merged = existing ?? .empty(for: song)
            var fields: Set<DeviceSyncOverlayField> = []
            if existing == nil || remote.updatedAt > merged.updatedAt {
                if merged.isFavorite != remote.isFavorite {
                    merged.isFavorite = remote.isFavorite
                    fields.insert(.favorite)
                }
                let rating = min(max(remote.rating, 0), 5)
                if merged.rating != rating {
                    merged.rating = rating
                    fields.insert(.rating)
                }
                if let tags = remote.displayTags, merged.displayTags != tags {
                    merged.displayTags = tags
                    fields.insert(.displayTags)
                }
            }
            if remote.playCount > merged.playCount {
                merged.playCount = remote.playCount
                fields.insert(.playCount)
            }
            if remote.skipCount > merged.skipCount {
                merged.skipCount = remote.skipCount
                fields.insert(.skipCount)
            }
            if let remoteLastPlayedAt = remote.lastPlayedAt,
               merged.lastPlayedAt.map({ remoteLastPlayedAt > $0 }) ?? true {
                merged.lastPlayedAt = remoteLastPlayedAt
                fields.insert(.lastPlayedAt)
            }
            if fields.isEmpty {
                ignoredCount += 1
            } else {
                merged.updatedAt = max(merged.updatedAt, remote.updatedAt)
                merged.normalize()
                trackOverlays[song.overlayKey] = merged
                didChange = true
                receiptItems.append(DeviceSyncOverlayReceiptItem(
                    sourceKey: remote.sourceKey,
                    fields: fields.sorted { $0.rawValue < $1.rawValue }
                ))
            }
        }
        if didChange {
            persistTrackOverlays()
        }
        return DeviceSyncOverlayReceipt(
            id: UUID(),
            appliedAt: .now,
            items: receiptItems,
            ignoredCount: ignoredCount
        )
    }

    func artistArtwork(for artist: SystemArtist, size: CGSize = CGSize(width: 120, height: 120)) -> UIImage? {
        guard songs(for: artist).contains(where: { $0.url == nil }) else { return nil }
        return systemMediaLibrary.artworkForArtist(id: artist.id, name: artist.name, size: size)
    }

    func playSystemSong(_ song: SystemSong) {
        playSystemQueue([song], startAt: 0, title: nil)
    }

    func isSongActive(_ song: SystemSong) -> Bool {
        selectedSystemSongID == song.id
    }

    func songsForNowPlayingAlbum() -> [SystemSong] {
        guard let nowPlayingAlbum else { return [] }
        return songs(for: nowPlayingAlbum)
    }

    func playSystemQueue(_ songs: [SystemSong], startAt index: Int, title: String?) {
        lastUserPlaybackInteractionAt = CFAbsoluteTimeGetCurrent()
        guard songs.indices.contains(index) else { return }
        let song = songs[index]
        if selectedSystemSongID != song.id {
            recordCurrentSystemSongAsSkippedIfNeeded()
        }
        PlaybackDebugLogger.event(
            "audio.queue.request songID=\(song.id) index=\(index) title=\(song.title)"
        )

        // Ignore a duplicate row/control action while this exact track is
        // already being prepared. Starting a second transition cancels the
        // first load, stops the engine twice, and needlessly repeats the media
        // library query.
        guard !(selectedSystemSongID == song.id && isPlaybackStarting) else {
            return
        }

        // Invalidate the old DRM starter/monitor BEFORE the first suspension or
        // metadata lookup. Its late notifications must not own the new request.
        stopCurrentPlaybackForTransition(pauseSystemPlayback: true)

        errorMessage = nil
        cancelLibraryWorkForPlayback(force: true)
        // A user-selected track always wins over startup restoration. This
        // prevents a late library scan from replacing the active transition.
        shouldRestorePlaybackFromInitialLibrary = false
        systemQueue = songs
        systemQueueIndex = index
        systemQueueTitle = title
        selectedSystemSongID = song.id
        // Publish loading immediately, before media metadata/artwork lookup.
        isProcessing = true
        isPlaybackStarting = true
        playbackStartMonitorTask?.cancel()
        playbackStartMonitorTask = nil
        
        // ユーザー体験の向上：再生ボタンを押した瞬間に曲情報をUIに反映させる
        trackTitle = song.title
        trackSubtitle = queueAwareSubtitle(artist: song.artist, album: song.album, queueTitle: title)

        // MPMediaQuery can synchronously contact the privacy-accounting and
        // media-library services. Keep it out of the gesture transaction so a
        // temporarily busy system service cannot trip the gesture gate.
        nowPlayingArtwork = nil
        nowPlayingAlbum = matchingAlbum(from: song)

        isPlaying = false
        playbackPreparationToken &+= 1
        let prepareToken = playbackPreparationToken
        let preparePauseToken = userPauseIntentToken
        precisionUpgradeTask?.cancel()
        preloadTrackTask?.cancel()
        localPlaybackFormatDescription = L10n.tr("playback.preparing")

        Task {
            // UIが現在の「isProcessing = true」を描画する猶予を作る
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard prepareToken == playbackPreparationToken,
                  preparePauseToken == userPauseIntentToken,
                  selectedSystemSongID == song.id else { return }

            // ローカルファイル（URL保持）またはシステムライブラリ（assetURL取得可能）の判定
            let (playbackURL, currentItem) = resolvePlayableAsset(for: song)
            if let currentItem {
                nowPlayingArtwork = currentItem.artwork?.image(at: CGSize(width: 600, height: 600))
                nowPlayingAlbum = resolveAlbum(from: currentItem)
            }

            if let assetURL = playbackURL {
                // ローカルファイルはアートワーク取得を待たずに再生準備へ進む。
                if currentItem == nil {
                    nowPlayingAlbum = matchingAlbum(from: song)
                }
                
                let hiResStarted = playHiResLocalOrSystemSong(
                    song: song,
                    mediaItem: currentItem,
                    assetURL: assetURL,
                    queueTitle: title,
                    autoplay: true
                )
                let activePreparationToken = playbackPreparationToken
                if !hiResStarted {
                    guard selectedSystemSongID == song.id else { return }
                    if let item = currentItem {
                        prepareSystemPlaybackFallback(song: song, mediaItem: item, queueTitle: title, autoplay: true)
                    } else {
                        errorMessage = L10n.tr("error.playback_prepare_failed")
                        isProcessing = false
                        isPlaybackStarting = false
                    }
                } else {
                    let didStart = await waitUntilLocalPlaybackStarts()
                    guard activePreparationToken == playbackPreparationToken,
                          preparePauseToken == userPauseIntentToken,
                          selectedSystemSongID == song.id else { return }
                    isProcessing = false
                    if didStart {
                        isPlaybackStarting = false
                    } else {
                        monitorPlaybackStart(for: .local)
                    }
                }
                if activePreparationToken == playbackPreparationToken,
                   selectedSystemSongID == song.id {
                    scheduleNextTrackPreload(after: index)
                }
                persistLibraryState()
                return
            }

            guard let selectedItem = currentItem else {
                isProcessing = false
                isPlaybackStarting = false
                isPlaying = false
                errorMessage = L10n.tr("error.song_not_found")
                return
            }
            let cloudServiceAuthorized = await ensureCloudServiceAuthorizationForProtectedPlayback(promptIfNeeded: true)
            guard prepareToken == playbackPreparationToken,
                  preparePauseToken == userPauseIntentToken,
                  selectedSystemSongID == song.id else { return }
            logProtectedPlaybackDiagnostics("authorization_checked")
            guard cloudServiceAuthorized else {
                isProcessing = false
                isPlaybackStarting = false
                isPlaying = false
                errorMessage = L10n.tr("error.apple_music_access_required")
                return
            }

            playbackSource = .system
            ensureSystemPlayerConfigured()
            systemPlayer.repeatMode = .none
            systemPlayer.shuffleMode = .off

            // Preserve Music's background queue, but fetch the remainder in one
            // batch. Stop at an imported file so native playback cannot skip it.
            let followingIDs = songs.dropFirst(index + 1)
                .prefix { $0.source == .systemMusic }.map(\.id)
            let followingItems = systemMediaLibrary.mediaItems(for: followingIDs)
            startProtectedSystemPlayback(with: [selectedItem] + followingItems)
            // ここでは defer で isProcessing を false にせず、startProtectedSystemPlayback の非同期処理に委ねる
        }
    }

    func playPreviousTrack() {
        lastUserPlaybackInteractionAt = CFAbsoluteTimeGetCurrent()
        guard let currentIndex = systemQueueIndex, !systemQueue.isEmpty else { return }

        if currentIndex > 0 {
            playSystemQueue(systemQueue, startAt: currentIndex - 1, title: systemQueueTitle)
        } else if repeatMode == .album {
            playSystemQueue(systemQueue, startAt: systemQueue.count - 1, title: systemQueueTitle)
        }
    }

    func playNextTrack() {
        lastUserPlaybackInteractionAt = CFAbsoluteTimeGetCurrent()
        guard let currentIndex = systemQueueIndex, !systemQueue.isEmpty else { return }

        if currentIndex + 1 < systemQueue.count {
            playSystemQueue(systemQueue, startAt: currentIndex + 1, title: systemQueueTitle)
        } else if repeatMode == .album {
            playSystemQueue(systemQueue, startAt: 0, title: systemQueueTitle)
        }
    }

    func toggleSingleTrackRepeat() {
        repeatMode = repeatMode == .singleTrack ? .off : .singleTrack
        if repeatMode == .singleTrack {
            shuffleMode = .off
        }
        updateQueueCapabilities()
    }

    func toggleAlbumRepeat() {
        if repeatMode == .album {
            repeatMode = .off
            updateQueueCapabilities()
            return
        }

        repeatMode = .album
        shuffleMode = .off
        updateQueueCapabilities()
    }

    func toggleAlbumShuffle() {
        if shuffleMode == .album {
            shuffleMode = .off
            updateQueueCapabilities()
            return
        }

        guard canUseAlbumScopedPlaybackModes,
              let currentSong = currentPlaybackSong else {
            return
        }

        let shuffledQueue = makeShuffledQueue(from: currentAlbumSongs, currentSong: currentSong)
        guard !shuffledQueue.isEmpty else { return }

        shuffleMode = .album
        repeatMode = .off
        
        systemQueue = shuffledQueue
        systemQueueIndex = 0
        systemQueueTitle = L10n.queueShuffleTitle(currentSong.album)
        
        updateQueueCapabilities()
        persistLibraryState()
    }

    func toggleLibraryShuffle() {
        if shuffleMode == .library {
            shuffleMode = .off
            updateQueueCapabilities()
            return
        }

        guard canUseLibraryShuffle,
              let currentSong = currentPlaybackSong else {
            return
        }
        
        let shuffledQueue = makeShuffledQueue(from: systemSongs, currentSong: currentSong)
        guard !shuffledQueue.isEmpty else { return }

        shuffleMode = .library
        repeatMode = .off
        
        systemQueue = shuffledQueue
        systemQueueIndex = 0
        systemQueueTitle = L10n.tr("queue.shuffle.library")
        
        updateQueueCapabilities()
        persistLibraryState()
    }

    func togglePlayback(origin: String = "app") {
        PlaybackDebugLogger.event("audio.transport.toggle origin=\(origin) source=\(playbackSource) playing=\(isPlaying) loading=\(isPlaybackStarting)")
        if actualPlaybackState == .playing || isPlaybackStarting
            || unexpectedPlaybackRecoveryTask != nil {
            _ = handleRemotePauseCommand(origin: origin)
        } else {
            _ = handleRemotePlayCommand()
        }
    }

    func seek(to newProgress: Double) {
        switch playbackSource {
        case .local:
            guard hiResPlaybackEngine.duration > 0 else { return }
            let targetTime = newProgress * hiResPlaybackEngine.duration
            do {
                try hiResPlaybackEngine.seek(to: targetTime)
            } catch {
                errorMessage = L10n.tr("error.seek_failed", error.localizedDescription)
            }
            refreshPlaybackState()
            updateNowPlayingInfo(force: true)
        case .system:
            guard isSystemPlayerConfigured else { return }
            guard let item = systemPlayer.nowPlayingItem, item.playbackDuration > 0 else { return }
            systemPlayer.currentPlaybackTime = newProgress * item.playbackDuration
            syncSystemPlaybackState()
            updateNowPlayingInfo(force: true)
        }
    }

    func skip(by seconds: TimeInterval) {
        switch playbackSource {
        case .local:
            guard hiResPlaybackEngine.hasTrack else { return }
            do {
                try hiResPlaybackEngine.skip(by: seconds)
            } catch {
                errorMessage = L10n.tr("error.skip_failed", error.localizedDescription)
            }
            refreshPlaybackState()
            updateNowPlayingInfo(force: true)
        case .system:
            guard isSystemPlayerConfigured else { return }
            guard let item = systemPlayer.nowPlayingItem else { return }
            let next = min(max(0, systemPlayer.currentPlaybackTime + seconds), item.playbackDuration)
            systemPlayer.currentPlaybackTime = next
            syncSystemPlaybackState()
            updateNowPlayingInfo(force: true)
        }
    }

    private func loadLibraryState() {
        let state = appLibraryStore.loadState()
        if let rawTab = UserDefaults.standard.string(forKey: Self.selectedEffectPageTabDefaultsKey),
           let restoredTab = AudioEffectPageTab(rawValue: rawTab) {
            selectedEffectPageTab = restoredTab
        }
        pendingPlaybackSnapshot = state.playback
        pendingEffectSettings = state.effectSettings
        headphoneSpatialSettings = state.headphoneSpatialSettings
        upsamplingMode = memorySafetyMode.automaticUpsamplingMode
        automaticDSPStrength = min(max(state.automaticDSPStrength, 0.0), 1.5)
        automaticDSPVoicing = state.automaticDSPVoicing
        restoreEffectSettingsIfNeeded()
    }

    private func loadCachedSystemLibrarySnapshotIfAvailable() async -> Bool {
        let revisionBeforeRead = librarySnapshotRevision
        let restoredSnapshot = await Task.detached(priority: .utility) { () -> SystemLibrarySnapshot? in
            guard let cached = AppLibraryStore().loadCachedSystemLibrarySnapshot() else { return nil }
            // Discard the old derived indexes, not songs. They may already
            // have lost valid Apple IDs to the former high-bit source filter.
            return SystemLibrarySnapshot(songs: cached.songs.filter { $0.url == nil })
        }.value
        guard let snapshot = restoredSnapshot, systemSongs.isEmpty,
              librarySnapshotRevision == revisionBeforeRead,
              deferredLibrarySnapshot?.songs.isEmpty != false else { return false }

        // A launch-time disk decode can finish after the user has selected a
        // track. Publishing thousands of rows then creates a large main-thread
        // update that can starve the realtime renderer.
        guard !isPlaybackBusyForLibraryWork, !hasResidentLocalPlaybackTrack else {
            deferredLibrarySnapshot = snapshot
            isLibraryBootstrapInProgress = false
            isInitialLibraryLoading = false
            return !snapshot.songs.isEmpty
        }

        applyLibrarySnapshotToPublishedState(snapshot)
        let restoredContent = !snapshot.songs.isEmpty
        if restoredContent {
            // Cached content is immediately usable; the fresh scan continues
            // in the background without blocking the library interface.
            isLibraryBootstrapInProgress = false
            isInitialLibraryLoading = false
            libraryLoadingMessage = nil
        }
        return restoredContent
    }

    private func recoverEmptyLibraryAfterForeground() {
        guard systemSongs.isEmpty, foregroundLibraryRecoveryTask == nil,
              mediaLibraryAccess == .authorized else { return }
        foregroundLibraryRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.foregroundLibraryRecoveryTask = nil }
            _ = await self.loadCachedSystemLibrarySnapshotIfAvailable()
            guard self.isApplicationActive else { return }
            self.flushDeferredLibrarySnapshotIfPlaybackIsIdle(allowWhilePlaying: true)
            if self.systemSongs.isEmpty {
                self.refreshSystemLibrary(showLoadingState: false, recoveringEmptyLibrary: true)
            }
            PlaybackDebugLogger.event("library.foreground.recovery songs=\(self.systemSongs.count)")
        }
    }

    private func persistCachedSystemLibrarySnapshot(_ snapshot: SystemLibrarySnapshot) {
        let cached = CachedSystemLibrarySnapshot(
            songs: snapshot.songs,
            artists: snapshot.artists,
            albums: snapshot.albums
        )
        librarySnapshotPersistenceTask?.cancel()
        librarySnapshotPersistenceTask = Task.detached(priority: .utility) {
            try? AppLibraryStore().saveCachedSystemLibrarySnapshot(cached)
        }
    }

    private func persistLibraryState() {
        let state = AppLibraryState(
            playback: currentPlaybackSnapshot(),
            effectSettings: currentStoredEffectSettings(),
            headphoneSpatialSettings: headphoneSpatialSettings,
            upsamplingMode: upsamplingMode,
            automaticDSPStrength: automaticDSPStrength,
            automaticDSPVoicing: automaticDSPVoicing
        )
        statePersistenceQueue.async { [appLibraryStore, weak self] in
            do {
                try appLibraryStore.saveState(state)
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = L10n.tr("error.library_save_failed", error.localizedDescription)
                }
            }
        }
    }

    private func loadTrackOverlays() {
        let overlays = appLibraryStore.loadTrackOverlays()
        trackOverlays = Dictionary(
            overlays.map { ($0.trackKey, $0) },
            uniquingKeysWith: { current, candidate in
                current.updatedAt >= candidate.updatedAt ? current : candidate
            }
        )
    }

    private func loadOngakuPlaylists() {
        ongakuPlaylists = appLibraryStore.loadOngakuPlaylists()
    }

    private func updateOverlay(
        for song: SystemSong,
        change: (inout LibraryTrackOverlay) -> Void
    ) {
        var overlay = trackOverlays[song.overlayKey] ?? .empty(for: song)
        change(&overlay)
        overlay.normalize()
        overlay.updatedAt = .now
        trackOverlays[song.overlayKey] = overlay
        persistTrackOverlays()
    }

    private func persistTrackOverlays() {
        let snapshot = trackOverlays.values.sorted { $0.trackKey < $1.trackKey }
        statePersistenceQueue.async { [appLibraryStore, weak self] in
            do {
                try appLibraryStore.saveTrackOverlays(snapshot)
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = L10n.tr("error.library_save_failed", error.localizedDescription)
                }
            }
        }
    }

    private func persistOngakuPlaylists() {
        let snapshot = ongakuPlaylists
        statePersistenceQueue.async { [appLibraryStore, weak self] in
            do {
                try appLibraryStore.saveOngakuPlaylists(snapshot)
            } catch {
                DispatchQueue.main.async {
                    self?.errorMessage = L10n.tr("error.library_save_failed", error.localizedDescription)
                }
            }
        }
    }

    private func recordCurrentSystemSongAsCompleted() {
        guard let song = currentPlaybackSong,
              song.source == .systemMusic else { return }
        recordSystemSongAsCompleted(song)
    }

    private func recordSystemSongAsCompleted(_ song: SystemSong) {
        let now = CFAbsoluteTimeGetCurrent()
        guard lastOverlayCompletionKey != song.overlayKey
                || now - lastOverlayCompletionAt > 2 else { return }
        lastOverlayCompletionKey = song.overlayKey
        lastOverlayCompletionAt = now
        updateOverlay(for: song) { overlay in
            overlay.playCount += 1
            overlay.lastPlayedAt = .now
        }
    }

    private func recordCurrentSystemSongAsSkippedIfNeeded() {
        guard isPlaying,
              progress < 0.9,
              let song = currentPlaybackSong,
              song.source == .systemMusic else { return }
        updateOverlay(for: song) { overlay in
            overlay.skipCount += 1
        }
    }

    private func refreshPlaybackState() {
        let oldIsPlaying = isPlaying
        
        switch playbackSource {
        case .local:
            guard hiResPlaybackEngine.hasTrack else {
                progress = 0
                currentTimeText = "00:00"
                localPlaybackFormatDescription = L10n.playbackFormatUnavailable()
                isPlaying = false
                updateQueueCapabilities()
                updateNowPlayingInfo()
                return
            }
            let currentTime = hiResPlaybackEngine.currentTime()
            progress = hiResPlaybackEngine.duration > 0 ? currentTime / hiResPlaybackEngine.duration : 0
            currentTimeText = formatTime(currentTime)
            durationText = formatTime(hiResPlaybackEngine.duration)
            localPlaybackFormatDescription = hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
            
            // 強制停止期間（ユーザーの停止操作直後）は、エンジンの報告を無視して「一時停止中」を維持します。
            isPlaying = actualPlaybackState == .playing
            
        case .system:
            syncSystemPlaybackState()
        }
        
        updateQueueCapabilities()
        flushDeferredLibrarySnapshotIfPlaybackIsIdle()
        
        if isPlaying != oldIsPlaying {
            if playbackSource == .local {
                reinforceNowPlayingTransportState()
            } else {
                updateNowPlayingInfo(force: true)
            }
        } else {
            updateNowPlayingInfo()
        }
    }

    private var actualPlaybackState: MPNowPlayingPlaybackState {
        if isInterrupted {
            return .paused
        }
        if isInForcedPausedWindow {
            return .paused
        }
        
        switch playbackSource {
        case .local:
            guard hasInitializedHiResPlaybackEngine,
                  !wasPlayingBeforeSessionInterruption,
                  unexpectedPlaybackRecoveryTask == nil,
                  !audioRenderHealth.isStalled else { return .paused }
            return PlaybackTransportPolicy.isPlaying(
                nodePlaying: hiResPlaybackEngine.isPlaying,
                engineRunning: hiResPlaybackEngine.isEngineRunning,
                interrupted: isInterrupted, explicitlyPaused: isInForcedPausedWindow
            ) ? .playing : .paused
        case .system:
            guard isSystemPlayerConfigured else { return .paused }
            let state: MPNowPlayingPlaybackState = systemPlayer.playbackState == .playing ? .playing : .paused
            return state
        }
    }

    private func reinforceNowPlayingTransportState() {
        // 【重要】ウィジェット同期の補強
        // iOSのメディア通信は非同期かつ不安定なため、停止直後に複数回の再送を行い、
        // システム側の「再生中」への予測復帰 (Prediction) を強力に抑え込みます。
        reinforceTaskID += 1
        let taskID = reinforceTaskID
        let preparationToken = playbackPreparationToken
        updateNowPlayingInfo(force: true)

        let delays: [TimeInterval] = [0.15, 0.45, 1.2]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.reinforceTaskID == taskID,
                      self.playbackPreparationToken == preparationToken, !self.isInterrupted else { return }
                // forcedPausedWindowが終了していても、停止状態の場合は明示的に書き込む
                self.updateNowPlayingInfo(force: true)
                
                // システム再生時: forcedPausedWindow外でwatchdogが必要
                if self.playbackSource == .system, !self.isPlaying {
                    self.runPlaybackWatchdog()
                }
            }
        }
    }

    private var isInForcedPausedWindow: Bool {
        guard let forcedPausedSource else { return false }
        guard forcedPausedSource == playbackSource else { 
            return false 
        }
        let now = CFAbsoluteTimeGetCurrent()
        let active = now < forcedPausedUntil
        return active
    }

    private func beginForcedPausedWindow(for source: PlaybackSource, duration: TimeInterval = 5.0) {
        forcedPausedSource = source
        forcedPausedUntil = CFAbsoluteTimeGetCurrent() + max(0.2, duration)
    }

    private func clearForcedPausedWindow() {
        forcedPausedSource = nil
        forcedPausedUntil = 0
    }


    private func scheduleSystemPauseStabilizationChecks() {
        let delays: [TimeInterval] = [0.15, 0.45, 0.9]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.enforceSystemForcedPausedIfNeeded()
            }
        }
    }

    @discardableResult
    private func enforceSystemForcedPausedIfNeeded() -> Bool {
        return runPlaybackWatchdog()
    }

    /// プレーヤーとウィジェットの状態を常時監視し、乖離があれば強制的に是正します。
    @discardableResult
    private func runPlaybackWatchdog() -> Bool {
        // アプリ側が「停止中」と判断しているのに、エンジンやシステムプレーヤーが
        // 「再生中」になっている不整合を検知・修正します。
        // ただし DRM 起動シーケンス中（isSystemPlayerStarting）は isPlaying が
        // まだ false のためこのガードに入ってしまうが、pause() すると起動が壊れるため除外する。
        guard PlaybackTransportPolicy.shouldEnforcePause(
            explicitlyPaused: isInForcedPausedWindow,
            interrupted: isInterrupted,
            starting: isPlaybackStarting || isSystemPlayerStarting,
            recovering: interruptionResumeTask != nil || unexpectedPlaybackRecoveryTask != nil
        ) else { return false }

        PlaybackDebugLogger.event("audio.transport.enforce_pause source=\(playbackSource) pauseToken=\(userPauseIntentToken)")
        var didCorrect = false

        switch playbackSource {
        case .local:
            // 独自エンジン（AVAudioEngine）の場合、playerNodeだけでなく
            // 土台の engine も物理的に止まっていないと、OSが「再生中」と断定し
            // ウィジェットを戻してしまうことがあるため、両方の状態を監視します。
            if hiResPlaybackEngine.isPlaying || hiResPlaybackEngine.isEngineRunning {
                hiResPlaybackEngine.pause()
                didCorrect = true
            }
        case .system:
            if isSystemPlayerConfigured && systemPlayer.playbackState == .playing {
                systemPlayer.pause()
                didCorrect = true
            }
        }

        // 強制停止期間中（isInForcedPausedWindow）は、ウィジェットが勝手に
        // 再生状態に戻らないよう、定期的に「停止中」のメタデータを上書き送信します。
        if isInForcedPausedWindow {
            forcedWriteNowPlayingPaused()
        }

        if didCorrect {
            // 不整合を修正した場合は即座に通知を補強します。
            reinforceNowPlayingTransportState()
        }

        return didCorrect
    }

    private func syncSystemPlaybackState() {
        guard playbackSource == .system else { return }
        guard isSystemPlayerConfigured else {
            isPlaying = false
            updateQueueCapabilities()
            return
        }

        guard acceptsCurrentSystemObservation else { return }
        guard let item = systemPlayer.nowPlayingItem else {
            progress = 0
            currentTimeText = "00:00"
            isPlaying = false
            updateQueueCapabilities()
            return
        }

        let observedSongID = resolvedSystemSongID ?? UInt64(item.persistentID)
        if let previousSongID = lastObservedSystemPlaybackSongID,
           previousSongID != observedSongID,
           lastObservedSystemPlaybackProgress >= 0.9,
           let completedSong = systemSongs.first(where: { $0.id == previousSongID }),
           completedSong.source == .systemMusic {
            recordSystemSongAsCompleted(completedSong)
        }
        if lastObservedSystemPlaybackSongID != observedSongID {
            cancelSystemAssetRecovery()
            systemAssetRecoveryFailure = nil
            lastObservedSystemPlaybackSongID = observedSongID
            lastObservedSystemPlaybackProgress = 0
        }

        selectedSystemSongID = observedSongID
        if let matchedIndex = systemQueue.firstIndex(where: { $0.id == selectedSystemSongID }) {
            systemQueueIndex = matchedIndex
        }
        trackTitle = item.title ?? L10n.unknownTitle()
        trackSubtitle = queueAwareSubtitle(
            artist: item.artist ?? L10n.unknownArtist(),
            album: item.albumTitle ?? L10n.unknownAlbum(),
            queueTitle: systemQueueTitle
        )
        let duration = item.playbackDuration
        let current = systemPlayer.currentPlaybackTime
        progress = duration > 0 ? current / duration : 0
        lastObservedSystemPlaybackProgress = max(lastObservedSystemPlaybackProgress, progress)
        currentTimeText = formatTime(current)
        durationText = formatTime(duration)
        nowPlayingArtwork = item.artwork?.image(at: CGSize(width: 600, height: 600))
        nowPlayingAlbum = resolveAlbum(from: item)
        isPlaying = actualPlaybackState == .playing
        if isPlaying, errorMessage == L10n.tr("error.system_playback_timeout") {
            errorMessage = nil
        }
        if (isPlaybackStarting || isSystemPlayerStarting),
           PlaybackTransportPolicy.systemStartConfirmed(
            expectedSongID: selectedSystemSongID, observedSongID: observedSongID,
            playing: systemPlayer.playbackState == .playing,
            interrupted: isInterrupted, explicitlyPaused: isInForcedPausedWindow
           ) {
            // Confirmation, not the lifetime of the retry Task, owns the spinner.
            isPlaybackStarting = false
            isProcessing = false
            isSystemPlayerStarting = false
            errorMessage = nil
        }
        updateQueueCapabilities()
        // Start from observed playback as well as explicit play requests. This
        // covers late Music starts, automatic queue advancement and restoration.
        if isPlaying { startSystemAssetRecoveryIfNeeded() }
    }

    private var acceptsCurrentSystemObservation: Bool {
        guard isSystemPlayerConfigured else { return false }
        return PlaybackTransportPolicy.acceptsSystemObservation(
            systemSource: playbackSource == .system,
            starting: isPlaybackStarting || isSystemPlayerStarting,
            selectedSongID: selectedSystemSongID,
            observedSongID: resolvedSystemSongID
        )
    }

    private var resolvedSystemSongID: UInt64? {
        guard isSystemPlayerConfigured, let item = systemPlayer.nowPlayingItem else { return nil }
        if let requestedID = systemRequestedSongID,
           PlaybackTransportPolicy.systemItemsMatch(
            expectedID: requestedID, expectedStoreID: systemRequestedStoreID,
            observedID: UInt64(item.persistentID), observedStoreID: item.playbackStoreID
           ) {
            return requestedID
        }
        return UInt64(item.persistentID)
    }

    private var isSystemPlaybackAtTrackEnd: Bool {
        guard let item = systemPlayer.nowPlayingItem else {
            return lastObservedSystemPlaybackSongID == selectedSystemSongID
                && lastObservedSystemPlaybackProgress >= 0.99
        }
        let duration = item.playbackDuration
        guard duration.isFinite, duration > 0 else { return false }
        return (duration - systemPlayer.currentPlaybackTime) <= 0.5
    }

    private var hasNextTrackInQueue: Bool {
        guard let currentIndex = systemQueueIndex else { return false }
        return currentIndex + 1 < systemQueue.count
    }

    private func startTimer() {
        cancelLibraryWorkForPlayback()
        stopTimer(animateMeter: false)
        updateTimer = Timer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(handleTimerTick),
            userInfo: nil,
            repeats: true
        )
        if let updateTimer { RunLoop.main.add(updateTimer, forMode: .common) }
        startVisualizationTimer()
    }

    private func stopTimer(animateMeter: Bool = true) {
        updateTimer?.invalidate()
        updateTimer = nil
        localProgressWatchdog.reset()
        stopVisualizationTimer()
        vuTransitionTask?.cancel()
        vuTransitionTask = nil
        if animateMeter {
            startVUMeterFadeOut()
        }
    }

    private func startVUMeterFadeOut() {
        vuTransitionTask?.cancel()
        let startValue = currentVUValue
        guard startValue > 0.001 else {
            resetVisualizationMeters()
            return
        }

        vuTransitionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let frameCount = 30
            for frame in 1...frameCount {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 33_000_000)
                guard !Task.isCancelled else { return }
                let progress = Double(frame) / Double(frameCount)
                let easedProgress = progress * progress * (3.0 - 2.0 * progress)
                self.currentVUValue = startValue * (1.0 - easedProgress)
            }
            self.resetVisualizationMeters()
            self.vuTransitionTask = nil
        }
    }

    private func startVisualizationTimer() {
        stopVisualizationTimer()
        guard isApplicationActive else { return }
        visualizationTimer = MeterVisualizationTiming.makeTimer(
            target: self, selector: #selector(handleVisualizationTimerTick)
        )
    }

    private func stopVisualizationTimer() {
        visualizationTimer?.invalidate()
        visualizationTimer = nil
    }

    @objc private func handleVisualizationTimerTick() {
        updateLevels()
    }

    private func updateLevels() {
        guard hasTrack else {
            resetVisualizationMeters()
            return
        }
        visualizationTickCount &+= 1

        if playbackSource == .system {
            updateSyntheticLevelsForSystemPlayback()
            return
        }

        let levels = hiResPlaybackEngine.finalOutputLevels
        updateVUMeterValue(rmsDBFS: levels.rmsDBFS)

        // 微小変化の連続Publishを抑えてメインスレッドの再描画負荷を下げる
        if abs(levels.rmsDBFS - currentOutputRMS) > 0.2 {
            currentOutputRMS = levels.rmsDBFS
        }
        if abs(levels.peakDBFS - currentOutputPeak) > 0.2 {
            currentOutputPeak = levels.peakDBFS
        }

        // Keep spectrum publication at the existing 15 Hz while the needle runs at 60 Hz.
        if visualizationTickCount % MeterVisualizationTiming.spectrumStride == 0, !levels.spectrum.isEmpty {
            if lastPublishedSpectrum.count != levels.spectrum.count {
                lastPublishedSpectrum = levels.spectrum
                currentSpectrum = levels.spectrum
                return
            }

            var maxDelta: Float = 0
            for i in levels.spectrum.indices {
                let delta = abs(levels.spectrum[i] - lastPublishedSpectrum[i])
                if delta > maxDelta { maxDelta = delta }
                if maxDelta >= 0.7 { break }
            }
            if maxDelta >= 0.7 {
                lastPublishedSpectrum = levels.spectrum
                currentSpectrum = levels.spectrum
            }
        }
    }

    private func updateSyntheticLevelsForSystemPlayback() {
        guard isPlaying else {
            resetVisualizationMeters(resetSpectrum: visualizationTickCount % MeterVisualizationTiming.spectrumStride == 0)
            return
        }

        guard supportsRealtimeEffects else {
            // DRM/system playback cannot expose audio samples. The user can still select
            // any visualization, but its meters stay at rest until real samples are available.
            resetVisualizationMeters(resetSpectrum: visualizationTickCount % MeterVisualizationTiming.spectrumStride == 0)
            return
        }

        syntheticVisualizationPhase += 0.08 * 30 / MeterVisualizationTiming.refreshRate
        let t = syntheticVisualizationPhase

        let rms = -24.0 + Float((sin(t * 1.3) + sin(t * 0.47) * 0.6) * 5.5)
        let peak = rms + 5.0 + Float((sin(t * 2.4) + 1.0) * 1.8)
        currentOutputRMS = min(-6, max(-40, rms))
        currentOutputPeak = min(-1, max(-30, peak))
        updateVUMeterValue(rmsDBFS: currentOutputRMS)

        if visualizationTickCount % MeterVisualizationTiming.spectrumStride != 0 { return }

        let count = max(64, currentSpectrum.count)
        var pseudo = Array(repeating: Float(-120), count: count)
        let bassCenter = Int(Double(count) * 0.16)
        let midCenter = Int(Double(count) * 0.45)
        let trebleCenter = Int(Double(count) * 0.78)

        for i in 0..<count {
            let x = Double(i) / Double(max(1, count - 1))
            let bass = exp(-pow((Double(i - bassCenter) / Double(count) * 8.5), 2)) * (0.7 + 0.3 * sin(t * 0.9))
            let mid = exp(-pow((Double(i - midCenter) / Double(count) * 9.5), 2)) * (0.6 + 0.4 * sin(t * 1.4 + x * 4.0))
            let treble = exp(-pow((Double(i - trebleCenter) / Double(count) * 11.0), 2)) * (0.5 + 0.5 * sin(t * 1.9 + x * 6.0))
            let energy = max(0.0, bass + mid + treble)
            pseudo[i] = Float(-78.0 + energy * 62.0)
        }
        currentSpectrum = pseudo
    }

    private func resetVisualizationMeters(resetSpectrum: Bool = false) {
        if currentOutputRMS != -120 { currentOutputRMS = -120 }
        if currentOutputPeak != -120 { currentOutputPeak = -120 }
        if currentVUValue != 0 { currentVUValue = 0 }
        vuBallistics.reset()
        if resetSpectrum, !currentSpectrum.isEmpty {
            currentSpectrum = Array(repeating: -120, count: max(32, currentSpectrum.count))
        }
    }

    private func updateVUMeterValue(rmsDBFS: Float) {
        let target = normalizedVUTarget(rmsDBFS: rmsDBFS)
        let nextValue = vuBallistics.update(target: target)
        if abs(nextValue - currentVUValue) > 0.0005 {
            currentVUValue = nextValue
        }
    }

    private func normalizedVUTarget(rmsDBFS: Float) -> Double {
        let rms = Double(rmsDBFS)
        guard rms.isFinite, rms > -100 else { return 0 }

        // A VU meter indicates average program level, not sample peaks.
        // Fixed -18 dBFS alignment preserves real level differences instead
        // of adapting the baseline until quiet and loud passages look alike.
        return VUMeterScale.normalizedValue(rmsDBFS: rms)
    }

    private func scheduleEffectAuditRefresh(after delay: TimeInterval) {
        stopEffectAuditRefreshTimer()
        isEffectAuditRefreshPrimed = true
        effectAuditSummaryText = L10n.tr("effects.signal.unavailable")
        effectAuditRefreshTimer = Timer.scheduledTimer(
            timeInterval: max(0.25, delay),
            target: self,
            selector: #selector(handleEffectAuditRefreshTimer),
            userInfo: nil,
            repeats: false
        )
    }

    private func startEffectAuditRefreshTimer() {
        stopEffectAuditRefreshTimer()
        isEffectAuditRefreshPrimed = false
        effectAuditRefreshTimer = Timer.scheduledTimer(
            timeInterval: 0.45,
            target: self,
            selector: #selector(handleEffectAuditRefreshTimer),
            userInfo: nil,
            repeats: true
        )
    }

    private func stopEffectAuditRefreshTimer() {
        effectAuditRefreshTimer?.invalidate()
        effectAuditRefreshTimer = nil
        isEffectAuditRefreshPrimed = false
    }

    private func stopLocalPlayback(clearTrackSelection: Bool = false) {
        unexpectedPlaybackRecoveryTask?.cancel()
        unexpectedPlaybackRecoveryTask = nil
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        localPlaybackLoadTask?.cancel()
        localPlaybackLoadTask = nil
        hiResPlaybackEngine.cancelBackgroundPreparation()
        hiResPlaybackEngine.stop(afterDrain: { PlaybackAudioSession.shared.deactivate() })
        remotePlaybackFile = nil
        musicPlaybackSnapshot = nil
        localPlaybackFormatDescription = L10n.playbackFormatUnavailable()
        isPlaying = false
        stopTimer()
        stopVisualizationTimer()
        beginForcedPausedWindow(for: .local)
        if clearTrackSelection {
            selectedSystemSongID = nil
        }
        
        // Session release is queued only after the final output has drained.
        
        reinforceNowPlayingTransportState()
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "00:00" }
        let totalSeconds = Int(interval.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    @objc private func handleTimerTick() {
        guard !isInterrupted else {
            refreshPlaybackState()
            return
        }
        memorySafetyTickCount &+= 1
        if memorySafetyTickCount % 8 == 0 {
            let elapsed = playbackSource == .local
                ? hiResPlaybackEngine.currentTime() : systemPlayer.currentPlaybackTime
            if elapsed < 10 {
                let running = hasInitializedHiResPlaybackEngine && hiResPlaybackEngine.isEngineRunning
                PlaybackDebugLogger.event("audio.transport.sample source=\(playbackSource) time=\(elapsed) playing=\(isPlaying) engineRunning=\(running) interrupted=\(isInterrupted) forcedPause=\(isInForcedPausedWindow)")
            }
            applyProactiveMemorySafetyIfNeeded()
        }

        // Fallback end detection: some devices/routes don't always emit reliable completion transitions.
        switch playbackSource {
        case .local:
            let renderHealth = hiResPlaybackEngine.pollRenderHealth()
            if renderHealth != audioRenderHealth { audioRenderHealth = renderHealth }
            let hasTrack = hiResPlaybackEngine.hasTrack
            let duration = hiResPlaybackEngine.duration
            let current = hiResPlaybackEngine.currentTime()
            let isEnginePlaying = hiResPlaybackEngine.isPlaying
            let reachedEnd = hasTrack && duration > 0 && current >= max(0, duration - 0.03)

            // Accepted EOF survives a temporary UI state refresh or a recovery
            // owner deferring the callback. Explicit pause/stop invalidates it.
            if hiResPlaybackEngine.hasReachedPlaybackEnd {
                handleLocalPlaybackEnded()
                return
            }

            // Output render callbacks can continue with silence after the
            // source timeline freezes. Observe source progress separately.
            let sourceStalled = localProgressWatchdog.observe(
                generation: hiResPlaybackEngine.playbackScheduleID,
                position: current,
                expectedToProgress: isPlaying && isEnginePlaying && !isPlaybackStarting
                    && !isInForcedPausedWindow && interruptionResumeTask == nil
                    && unexpectedPlaybackRecoveryTask == nil,
                now: ProcessInfo.processInfo.systemUptime
            )
            if isPlaying && (!isEnginePlaying || renderHealth.isStalled || sourceStalled) {
                if isInForcedPausedWindow {
                    return
                }
                if reachedEnd {
                    handleLocalPlaybackEnded()
                } else {
                    // Route changes and transient media-service failures can
                    // stop the node while its track remains valid.
                    scheduleUnexpectedLocalPlaybackRecovery(reason: sourceStalled ? "source_progress_stalled"
                        : (renderHealth.isStalled ? "render_stalled" : "render_node_stopped"))
                }
                return
            }

            if isPlaying && reachedEnd {
                if isInForcedPausedWindow {
                    return
                }
                handleLocalPlaybackEnded()
                return
            }
        case .system:
            if isSystemPlayerConfigured,
               !isPlaybackStarting, !isSystemPlayerStarting,
               systemPlayer.playbackState == .stopped,
               isSystemPlaybackAtTrackEnd {
                handleSystemPlaybackEnded()
                return
            }
        }
        refreshPlaybackState()
        runPlaybackWatchdog()
    }

    @objc private func handleEffectAuditRefreshTimer() {
        refreshEffectAuditSummary()
        if isEffectAuditRefreshPrimed {
            startEffectAuditRefreshTimer()
        }
    }

    private func handleSystemNowPlayingChanged() {
        guard acceptsCurrentSystemObservation else { return }
        syncSystemPlaybackState()
        updateNowPlayingInfo(force: true)
    }

    private func handleSystemPlaybackChanged() {
        guard acceptsCurrentSystemObservation else { return }

        let state = systemPlayer.playbackState
        PlaybackDebugLogger.event("audio.system.state state=\(state.rawValue) time=\(systemPlayer.currentPlaybackTime) starting=\(isPlaybackStarting)")

        if state == .playing && !isInterrupted && !isInForcedPausedWindow {
            startTimer()
            startVisualizationTimer()
        } else if state == .paused || state == .stopped {
            stopTimer()
        }

        syncSystemPlaybackState()
        runPlaybackWatchdog()
        updateNowPlayingInfo(force: true)

        guard !isInterrupted, interruptionResumeTask == nil, !isInForcedPausedWindow,
              !isPlaybackStarting, !isSystemPlayerStarting else { return }
        guard state != .playing else { return }
        guard isSystemPlaybackAtTrackEnd else { return }
        handleSystemPlaybackEnded()
    }

    private func updateQueueCapabilities() {
        if let systemQueueIndex {
            canGoToPreviousTrack = systemQueueIndex > 0 || (repeatMode == .album && !systemQueue.isEmpty)
            canGoToNextTrack = systemQueueIndex + 1 < systemQueue.count || (repeatMode == .album && !systemQueue.isEmpty)
        } else {
            canGoToPreviousTrack = false
            canGoToNextTrack = false
        }

        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.previousTrackCommand.isEnabled = canGoToPreviousTrack
        commandCenter.nextTrackCommand.isEnabled = canGoToNextTrack
    }

    private func refreshEffectAuditSummary() {
        guard isEffectScreenActive else { return }
        effectAuditSummaryText = Self.makeEffectAuditSummary(from: hiResPlaybackEngine.refreshEffectLevelAudits())
    }

    private func scheduleEffectApply(after delay: TimeInterval) {
        isEffectProcessing = true
        effectApplyTimer?.invalidate()
        effectApplyTimer = Timer.scheduledTimer(
            timeInterval: delay,
            target: self,
            selector: #selector(handleEffectApplyTimer),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func handleEffectApplyTimer() {
        effectApplyTimer?.invalidate()
        effectApplyTimer = nil
        defer { isEffectProcessing = false }
        applyRealtimeEffects()
        persistLibraryState()
    }

    private func applyRealtimeEffects(skipAutoPeakAdjustment: Bool = false) {
        guard !isApplyingRealtimeEffects else { return }
        isApplyingRealtimeEffects = true
        isEffectProcessing = true
        defer {
            isApplyingRealtimeEffects = false
            isEffectProcessing = false
        }

        hiResPlaybackEngine.apply(effectSettings: playbackEffectSettings)
        refreshEffectAuditSummary()
        guard !skipAutoPeakAdjustment else { return }
        autoAdjustEffectsForClippingIfNeeded()
    }

    private func autoAdjustEffectsForClippingIfNeeded() {
        // Only react to true clipping (peak over 0 dBFS).
        let audits = hiResPlaybackEngine.refreshEffectLevelAudits()
        guard !audits.isEmpty else { return }

        // Simple rate limit to avoid thrashing while UI is busy.
        let now = CFAbsoluteTimeGetCurrent()
        
        // Suppress automatic adjustment if the user has manually reduced any parameter recently.
        // This lets the user find the stable point themselves without the app fighting them.
        if now - lastManualParameterReductionTime < 1.5 { return }
        
        if now - lastAutoPeakAdjustTime < 0.18 { return }

        var didAdjust = false

        for audit in audits where audit.isEnabled && audit.outputPeakDBFS > 0.0 {
            guard let index = effectSettings.firstIndex(where: { $0.kind == audit.kind }) else { continue }

            // Reduce proportionally to how far we exceed 0 dBFS.
            let overDB = min(6.0, Double(audit.outputPeakDBFS)) // clamp to keep adjustments bounded
            let baseStep: Double = 0.02 + (overDB * 0.03) // ~0.05 at +1dB, ~0.11 at +3dB

            // Each module declares its own ordered reduction strategy. This
            // keeps clipping protection independent from concrete effects.
            let reductionKeys = AudioEffectModuleRegistry.clippingReductionParameterKeys(
                for: audit.kind
            )
            for key in reductionKeys {
                let currentValue = effectSettings[index].parameters[key] ?? 0.0
                let reducedValue = max(0.0, currentValue - baseStep)
                guard reducedValue < currentValue else { continue }
                effectSettings[index].parameters[key] = reducedValue
                didAdjust = true
                break
            }
        }

        guard didAdjust else { return }
        lastAutoPeakAdjustTime = now

        // Re-apply directly once with the adjusted values.
        hiResPlaybackEngine.apply(effectSettings: playbackEffectSettings)
        refreshEffectAuditSummary()
        persistLibraryState()
    }

    private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        // systemMusicPlayer belongs to Music, not our AVAudioSession. Music
        // taking audio from our engine must not cancel its own startup task.
        // Its playback notifications are authoritative for system playback.
        if playbackSource == .system {
            PlaybackDebugLogger.event("audio.system.app_session_interruption type=\(type.rawValue)")
            syncSystemPlaybackState()
            return
        }

        // Capture transport state on main-queue notification delivery before
        // scheduling the recovery task. The
        // render watchdog can observe the OS-stopped node in the meantime and
        // set `isPlaying` to false, losing the intent that existed when the
        // interruption actually began.
        let sourceAtNotification = playbackSource
        let wasActiveAtNotification: Bool
        switch sourceAtNotification {
        case .local:
            wasActiveAtNotification = isPlaying
                || isPlaybackStarting
                || updateTimer != nil
                || (hasInitializedHiResPlaybackEngine && hiResPlaybackEngine.isPlaying)
        case .system:
            wasActiveAtNotification = isPlaying
                || isPlaybackStarting
                || updateTimer != nil
                || (isSystemPlayerConfigured && systemPlayer.playbackState == .playing)
        }
        let pauseIntentAtNotification = userPauseIntentToken
        let preparationAtNotification = playbackPreparationToken

        Task { @MainActor [weak self] in
            guard let self else { return }
            guard self.playbackSource == sourceAtNotification,
                  self.playbackPreparationToken == preparationAtNotification else { return }

            switch type {
            case .began:
                // Nested/duplicate began notifications must not overwrite the
                // original `was playing` snapshot with the already-paused UI.
                guard !self.isInterrupted else {
                    PlaybackDebugLogger.event("audio.interruption.began duplicate=true")
                    return
                }

                self.interruptionGeneration &+= 1
                self.interruptionResumeTask?.cancel()
                self.interruptionResumeTask = nil
                self.wasPlayingBeforeSessionInterruption = wasActiveAtNotification
                    || (self.wasPlayingBeforeSessionInterruption
                        && self.userPauseIntentToken == self.interruptionPauseIntentBaseline
                        && self.playbackPreparationToken == self.interruptionPlaybackPreparationBaseline)
                self.systemTransportStartTask?.cancel()
                self.systemTransportStartTask = nil
                self.sessionActivationRetryTask?.cancel()
                self.sessionActivationRetryTask = nil
                self.unexpectedPlaybackRecoveryTask?.cancel()
                self.unexpectedPlaybackRecoveryTask = nil
                self.reinforceTaskID += 1
                self.interruptedPlaybackSource = sourceAtNotification
                self.interruptionPauseIntentBaseline = pauseIntentAtNotification
                self.interruptionPlaybackPreparationBaseline = preparationAtNotification
                self.isInterrupted = PlaybackTransportPolicy.interruptionRemainsActive(
                    after: .began
                )
                self.interruptionAllowsImmediateResume = false
                self.isSystemPlayerStarting = false
                self.isPlaying = false
                self.isPlaybackStarting = false
                self.stopTimer()

                guard wasActiveAtNotification else {
                    self.refreshPlaybackState()
                    self.updateNowPlayingInfo(force: true)
                    return
                }

                switch sourceAtNotification {
                case .local:
                    if self.hasInitializedHiResPlaybackEngine {
                        self.hiResPlaybackEngine.pause()
                    }
                case .system:
                    // The system player has already been interrupted by iOS.
                    // Calling pause() here can turn a temporary interruption
                    // into an explicit transport pause, so preserve its queue.
                    break
                }

                PlaybackDebugLogger.event(
                    "audio.interruption.began source=\(String(describing: sourceAtNotification))"
                )
                self.refreshPlaybackState()
                self.updateNowPlayingInfo(force: true)

            case .ended:
                self.isInterrupted = PlaybackTransportPolicy.interruptionRemainsActive(after: .ended)
                let rawOptions = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                self.interruptionAllowsImmediateResume = options.contains(.shouldResume)
                let noPauseIntentSinceInterruption = self.userPauseIntentToken
                    == self.interruptionPauseIntentBaseline
                let samePlaybackRequest = self.playbackPreparationToken
                    == self.interruptionPlaybackPreparationBaseline

                guard self.wasPlayingBeforeSessionInterruption,
                      noPauseIntentSinceInterruption,
                      samePlaybackRequest else {
                    self.clearInterruptionResumeState()
                    self.refreshPlaybackState()
                    self.updateNowPlayingInfo(force: true)
                    return
                }

                // Some apps finish an interruption without shouldResume. The
                // captured user intent remains authoritative in that case.
                let resumeSource = self.interruptedPlaybackSource ?? self.playbackSource
                let generation = self.interruptionGeneration
                PlaybackDebugLogger.event(
                    "audio.interruption.ended source=\(String(describing: resumeSource)) shouldResume=\(options.contains(.shouldResume))"
                )
                self.resumePlaybackAfterInterruption(
                    source: resumeSource,
                    generation: generation
                )
            @unknown default:
                break
            }
        }
    }

    private func clearInterruptionResumeState() {
        wasPlayingBeforeSessionInterruption = false
        interruptedPlaybackSource = nil
        interruptionPauseIntentBaseline = userPauseIntentToken
        interruptionPlaybackPreparationBaseline = playbackPreparationToken
        interruptionResumeTask = nil
    }

    private func cancelInterruptionResume() {
        interruptionGeneration &+= 1
        interruptionResumeTask?.cancel()
        clearInterruptionResumeState()
    }

    private func resumePendingInterruptionIfNeeded() {
        guard !isInterrupted, wasPlayingBeforeSessionInterruption,
              interruptionResumeTask == nil,
              userPauseIntentToken == interruptionPauseIntentBaseline,
              playbackPreparationToken == interruptionPlaybackPreparationBaseline,
              let source = interruptedPlaybackSource else { return }
        resumePlaybackAfterInterruption(source: source, generation: interruptionGeneration)
    }

    private func resumePlaybackAfterInterruption(
        source: PlaybackSource,
        generation: UInt64
    ) {
        guard interruptionResumeTask == nil else { return }
        let backgroundLease = PlaybackRecoveryBackgroundLease()
        interruptionResumeTask = Task { @MainActor [weak self] in
            defer { backgroundLease.end() }
            guard let self else { return }
            let retryDelays: [UInt64] = [0, 200_000_000, 500_000_000, 1_000_000_000,
                                         2_000_000_000, 3_000_000_000, 5_000_000_000, 5_000_000_000]
            var lastActivationError: Error?

            for (attempt, delay) in retryDelays.enumerated() {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay)
                }
                guard self.wasPlayingBeforeSessionInterruption,
                      !self.isInterrupted,
                      self.interruptionGeneration == generation,
                      self.userPauseIntentToken == self.interruptionPauseIntentBaseline,
                      self.playbackPreparationToken == self.interruptionPlaybackPreparationBaseline,
                      self.playbackSource == source,
                      !Task.isCancelled else {
                    if self.interruptionGeneration == generation {
                        self.clearInterruptionResumeState()
                    }
                    return
                }

                if backgroundLease.expired { break }
                // Without an explicit OS resume recommendation, wait for the
                // other app to release audio instead of taking it back.
                guard PlaybackTransportPolicy.mayResume(
                    osRecommended: self.interruptionAllowsImmediateResume,
                    otherAudioPlaying: AVAudioSession.sharedInstance().isOtherAudioPlaying
                ) else { continue }

                do {
                    try await PlaybackAudioSession.shared.activate()
                    if backgroundLease.expired { break }
                    guard self.wasPlayingBeforeSessionInterruption,
                          !self.isInterrupted,
                          self.interruptionGeneration == generation,
                          self.userPauseIntentToken == self.interruptionPauseIntentBaseline,
                          self.playbackPreparationToken == self.interruptionPlaybackPreparationBaseline,
                          self.playbackSource == source,
                          !Task.isCancelled else { return }

                    let didResume: Bool
                    switch source {
                    case .local:
                        guard self.hasInitializedHiResPlaybackEngine,
                              self.hiResPlaybackEngine.hasTrack else {
                            // Preparation can still be in flight; its completion
                            // will retry the preserved interruption intent.
                            self.interruptionResumeTask = nil
                            return
                        }
                        // A node's playing flag may survive loss of render I/O.
                        // Rebuild its schedule at the retained position, through
                        // the existing protected seek/start envelope.
                        try self.hiResPlaybackEngine.seek(to: self.hiResPlaybackEngine.currentTime())
                        try self.hiResPlaybackEngine.play()
                        try await self.hiResPlaybackEngine.waitForPlaybackProgress()
                        self.audioRenderHealth = self.hiResPlaybackEngine.pollRenderHealth()
                        didResume = self.hiResPlaybackEngine.hasReachedPlaybackEnd
                            || (self.hiResPlaybackEngine.isPlaying && !self.audioRenderHealth.isStalled)
                    case .system:
                        self.ensureSystemPlayerConfigured()
                        self.systemPlayer.play()
                        var confirmed = false
                        for poll in 0..<5 {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                            guard !Task.isCancelled,
                                  self.interruptionGeneration == generation,
                                  self.userPauseIntentToken == self.interruptionPauseIntentBaseline else {
                                if self.interruptionGeneration == generation {
                                    self.clearInterruptionResumeState()
                                }
                                return
                            }
                            if self.systemPlayer.playbackState == .playing {
                                confirmed = true
                                break
                            }
                            if poll == 1 || poll == 3 {
                                self.systemPlayer.play()
                            }
                        }
                        didResume = confirmed
                    }

                    if didResume,
                       !self.isInterrupted,
                       self.interruptionGeneration == generation,
                       self.userPauseIntentToken == self.interruptionPauseIntentBaseline,
                       self.playbackPreparationToken == self.interruptionPlaybackPreparationBaseline {
                        self.clearInterruptionResumeState()
                        self.clearForcedPausedWindow()
                        self.isPlaying = true
                        self.isProcessing = false
                        self.isPlaybackStarting = false
                        self.errorMessage = nil
                        self.startTimer()
                        if source == .local {
                            if self.hiResPlaybackEngine.hasReachedPlaybackEnd {
                                self.handleLocalPlaybackEnded()
                                return
                            }
                            self.refreshPlaybackState()
                            self.resumeAutomaticQualityUpgradeIfNeeded()
                        } else {
                            self.syncSystemPlaybackState()
                        }
                        self.updateNowPlayingInfo(force: true)
                        PlaybackDebugLogger.event(
                            "audio.interruption.resume ready=true attempt=\(attempt + 1) source=\(String(describing: source))"
                        )
                        self.clearInterruptionResumeState()
                        return
                    }
                } catch {
                    lastActivationError = error
                }
            }

            guard !Task.isCancelled, self.interruptionGeneration == generation,
                  self.userPauseIntentToken == self.interruptionPauseIntentBaseline,
                  self.playbackPreparationToken == self.interruptionPlaybackPreparationBaseline else { return }
            if source == .system, self.actualPlaybackState == .playing {
                self.clearInterruptionResumeState()
                self.refreshPlaybackState()
                self.startTimer()
                return
            }
            if let lastActivationError {
                self.errorMessage = L10n.tr(
                    "error.playback_session_failed",
                    lastActivationError.localizedDescription
                )
            }
            PlaybackDebugLogger.warning(
                "audio.interruption.resume ready=false source=\(String(describing: source))"
            )
            if source == .local { self.hiResPlaybackEngine.pause() }
            self.isPlaying = false
            self.stopTimer()
            self.refreshPlaybackState()
            self.updateNowPlayingInfo(force: true)
            // Preserve the intent for the next route/foreground/interruption
            // event. A transient activation failure is not a user pause.
            self.interruptionResumeTask = nil
        }
    }

    /// Recovers from a transient AVAudioPlayerNode/route failure without
    /// rebuilding the library or abandoning the selected track. The request is
    /// bounded and tied to the current transport tokens so it cannot restart
    /// after a user pause or a different song selection.
    private func scheduleUnexpectedLocalPlaybackRecovery(reason: String) {
        guard unexpectedPlaybackRecoveryTask == nil,
              playbackSource == .local,
              hasInitializedHiResPlaybackEngine,
              hiResPlaybackEngine.hasTrack,
              isPlaying,
              !isInterrupted,
              !isInForcedPausedWindow else {
            return
        }

        let preparationToken = playbackPreparationToken
        let pauseIntentToken = userPauseIntentToken
        let expectedSongID = selectedSystemSongID
        let expectedURL = hiResPlaybackEngine.currentAudioURL
        let resumeTime = hiResPlaybackEngine.currentTime()
        isPlaybackStarting = true

        PlaybackDebugLogger.warning(
            "audio.local.unexpected_stop reason=\(reason) current=\(String(format: "%.3f", resumeTime)) engineRunning=\(hiResPlaybackEngine.isEngineRunning)"
        )

        let backgroundLease = PlaybackRecoveryBackgroundLease()
        unexpectedPlaybackRecoveryTask = Task { @MainActor [weak self] in
            defer { backgroundLease.end() }
            guard let self else { return }
            let retryDelays: [UInt64] = [150_000_000, 500_000_000, 1_200_000_000]
            var lastError: Error?

            for (index, delay) in retryDelays.enumerated() {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }

                guard !Task.isCancelled,
                      !backgroundLease.expired,
                      self.playbackSource == .local,
                      self.playbackPreparationToken == preparationToken,
                      self.userPauseIntentToken == pauseIntentToken,
                      self.selectedSystemSongID == expectedSongID,
                      self.hiResPlaybackEngine.currentAudioURL == expectedURL,
                      !self.isInterrupted,
                      !self.isInForcedPausedWindow else {
                    self.unexpectedPlaybackRecoveryTask = nil
                    self.isPlaybackStarting = false
                    return
                }

                // EOF may arrive while this recovery waits. Consume that
                // schedule before seeking, which would invalidate its evidence.
                if self.hiResPlaybackEngine.hasReachedPlaybackEnd {
                    self.unexpectedPlaybackRecoveryTask = nil
                    self.isPlaybackStarting = false
                    self.isProcessing = false
                    PlaybackDebugLogger.event("audio.local.recovery_completed_by_eof reason=\(reason)")
                    self.handleLocalPlaybackEnded()
                    return
                }
                guard !AVAudioSession.sharedInstance().isOtherAudioPlaying else { continue }
                do {
                    try await PlaybackAudioSession.shared.activate()
                    if backgroundLease.expired { break }
                    guard PlaybackTransportPolicy.requestIsCurrent(
                        pauseToken: pauseIntentToken, currentPauseToken: self.userPauseIntentToken,
                        preparationToken: preparationToken, currentPreparationToken: self.playbackPreparationToken,
                        interrupted: self.isInterrupted, cancelled: Task.isCancelled
                    ),
                       self.playbackSource == .local,
                       self.selectedSystemSongID == expectedSongID,
                       self.hiResPlaybackEngine.currentAudioURL == expectedURL else { return }

                    if self.hiResPlaybackEngine.hasReachedPlaybackEnd {
                        self.unexpectedPlaybackRecoveryTask = nil
                        self.isPlaybackStarting = false
                        self.isProcessing = false
                        PlaybackDebugLogger.event("audio.local.recovery_completed_by_eof reason=\(reason)")
                        self.handleLocalPlaybackEnded()
                        return
                    }

                    let safeResumeTime = min(
                        max(0, resumeTime),
                        max(0, self.hiResPlaybackEngine.duration - 0.05)
                    )
                    try self.hiResPlaybackEngine.seek(to: safeResumeTime)
                    try self.hiResPlaybackEngine.play()
                    try await self.hiResPlaybackEngine.waitForPlaybackProgress()

                    guard PlaybackTransportPolicy.requestIsCurrent(
                        pauseToken: pauseIntentToken, currentPauseToken: self.userPauseIntentToken,
                        preparationToken: preparationToken, currentPreparationToken: self.playbackPreparationToken,
                        interrupted: self.isInterrupted, cancelled: Task.isCancelled
                    ) else { return }
                    self.audioRenderHealth = self.hiResPlaybackEngine.pollRenderHealth()
                    if self.hiResPlaybackEngine.hasReachedPlaybackEnd
                        || (self.hiResPlaybackEngine.isPlaying && !self.audioRenderHealth.isStalled) {
                        self.clearForcedPausedWindow()
                        self.isPlaying = true
                        self.isProcessing = false
                        self.isPlaybackStarting = false
                        self.unexpectedPlaybackRecoveryTask = nil
                        self.startTimer()
                        if self.hiResPlaybackEngine.hasReachedPlaybackEnd {
                            self.handleLocalPlaybackEnded()
                            return
                        }
                        self.refreshPlaybackState()
                        self.updateNowPlayingInfo(force: true)
                        PlaybackDebugLogger.event(
                            "audio.local.recovered reason=\(reason) attempt=\(index + 1)"
                        )
                        return
                    }
                } catch {
                    lastError = error
                    PlaybackDebugLogger.warning(
                        "audio.local.recovery_retry reason=\(reason) attempt=\(index + 1) error=\(error.localizedDescription)"
                    )
                }
            }

            guard !Task.isCancelled, !self.isInterrupted, self.playbackSource == .local,
                  self.hiResPlaybackEngine.currentAudioURL == expectedURL,
                  self.playbackPreparationToken == preparationToken,
                  self.userPauseIntentToken == pauseIntentToken else { return }

            // Retain the original request for a later foreground/route retry.
            // The token checks above prevent reviving a user pause or new track.
            self.wasPlayingBeforeSessionInterruption = true
            self.interruptedPlaybackSource = .local
            self.interruptionPauseIntentBaseline = pauseIntentToken
            self.interruptionPlaybackPreparationBaseline = preparationToken
            self.interruptionAllowsImmediateResume = false
            self.hiResPlaybackEngine.pause()
            self.unexpectedPlaybackRecoveryTask = nil
            self.isPlaybackStarting = false
            self.isProcessing = false
            self.isPlaying = false
            self.stopTimer()
            self.refreshPlaybackState()
            self.persistLibraryState()
            self.updateNowPlayingInfo(force: true)
            PlaybackDebugLogger.warning(
                "audio.local.recovery_failed reason=\(reason) error=\(lastError?.localizedDescription ?? "none")"
            )
        }
    }

    private func handleMediaServicesWereReset(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            // 音声サービスがリセットされた場合は、再生状態を同期し直す。
            // ローカル再生は保持が難しいため、必要に応じてユーザー操作で再開してもらう。
            if playbackSource == .system {
                ensureSystemPlayerConfigured()
                syncSystemPlaybackState()
            } else {
                if isPlaying && hiResPlaybackEngine.hasTrack {
                    scheduleUnexpectedLocalPlaybackRecovery(reason: "media_services_reset")
                } else {
                    refreshPlaybackState()
                }
            }
            updateNowPlayingInfo(force: true)
        }
    }

    private func handleLocalPlaybackEnded() {
        guard playbackSource == .local else { return }
        guard !isInterrupted, !isInForcedPausedWindow,
              interruptionResumeTask == nil, unexpectedPlaybackRecoveryTask == nil else { return }
        // Wall-clock debounce can swallow a second short track/repeat. Each
        // schedule owns exactly one queue transition, even after deferred EOF.
        let generation = hiResPlaybackEngine.playbackScheduleID
        guard lastLocalTrackEndGeneration != generation else { return }
        lastLocalTrackEndGeneration = generation

        PlaybackDebugLogger.event(
            "audio.local.ended current=\(String(format: "%.3f", hiResPlaybackEngine.currentTime())) duration=\(String(format: "%.3f", hiResPlaybackEngine.duration)) queueIndex=\(systemQueueIndex.map(String.init) ?? "none")"
        )
        
        if isInForcedPausedWindow {
            return
        }

        recordCurrentSystemSongAsCompleted()

        if repeatMode == .singleTrack {
            do {
                try hiResPlaybackEngine.seek(to: 0)
                try hiResPlaybackEngine.play()
                isPlaying = true
                startTimer()
                refreshPlaybackState()
                return
            } catch {
                errorMessage = L10n.tr("error.repeat_failed", error.localizedDescription)
            }
        }

        if hasNextTrackInQueue {
            playNextTrack()
            return
        }

        if repeatMode == .album,
           !systemQueue.isEmpty {
            playSystemQueue(systemQueue, startAt: 0, title: systemQueueTitle)
            return
        }

        hiResPlaybackEngine.pause()
        beginForcedPausedWindow(for: .local)
        isPlaying = false
        stopTimer()
        let finalDuration = hiResPlaybackEngine.duration
        progress = finalDuration > 0 ? 1.0 : 0
        currentTimeText = formatTime(finalDuration)
        durationText = formatTime(finalDuration)
        updateQueueCapabilities()
        
        // 再生終了時はセッションを解除
        PlaybackAudioSession.shared.deactivate()
        
        updateNowPlayingInfo(force: true)
        reinforceNowPlayingTransportState()
        persistLibraryState()
    }

    private func handleSystemPlaybackEnded() {
        guard !isInterrupted, !isInForcedPausedWindow, interruptionResumeTask == nil else { return }
        guard !shouldIgnoreDuplicateTrackEndEvent() else { return }

        recordCurrentSystemSongAsCompleted()

        if repeatMode == .singleTrack,
           let currentIndex = systemQueueIndex,
           !systemQueue.isEmpty {
            playSystemQueue(systemQueue, startAt: currentIndex, title: systemQueueTitle)
            return
        }

        if hasNextTrackInQueue {
            playNextTrack()
            return
        }

        if repeatMode == .album,
           !systemQueue.isEmpty {
            playSystemQueue(systemQueue, startAt: 0, title: systemQueueTitle)
            return
        }

        if isSystemPlayerConfigured {
            systemPlayer.pause()
        }
        isPlaying = false
        syncSystemPlaybackState()
        stopTimer()
        updateQueueCapabilities()
        
        // システムプレーヤー停止時もセッションを解除
        PlaybackAudioSession.shared.deactivate()
        
        reinforceNowPlayingTransportState()
        persistLibraryState()
    }

    // MARK: - Remote Command & Now Playing Info（ロック画面 / コントロールセンター）

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        let playTarget = commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in _ = self.handleRemotePlayCommand() }
            return .success
        }
        remoteCommandRegistrations.append((commandCenter.playCommand, playTarget))

        commandCenter.pauseCommand.isEnabled = true
        let pauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in _ = self.handleRemotePauseCommand(origin: "remote") }
            return .success
        }
        remoteCommandRegistrations.append((commandCenter.pauseCommand, pauseTarget))
        
        commandCenter.togglePlayPauseCommand.isEnabled = true
        let toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in self.togglePlayback(origin: "remote") }
            return .success
        }
        remoteCommandRegistrations.append((commandCenter.togglePlayPauseCommand, toggleTarget))

        let nextTarget = commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.canGoToNextTrack else { return .noSuchContent }
            Task { @MainActor [weak self] in
                self?.playNextTrack()
            }
            return .success
        }
        remoteCommandRegistrations.append((commandCenter.nextTrackCommand, nextTarget))

        let previousTarget = commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.canGoToPreviousTrack else { return .noSuchContent }
            Task { @MainActor [weak self] in
                self?.playPreviousTrack()
            }
            return .success
        }
        remoteCommandRegistrations.append((commandCenter.previousTrackCommand, previousTarget))

        commandCenter.changePlaybackPositionCommand.isEnabled = true
        let positionTarget = commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let positionEvent = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            guard let self else { return .commandFailed }
            let snapshot = self.makeNowPlayingSnapshot()
            guard snapshot.duration > 0 else { return .noSuchContent }
            let position = min(max(0, positionEvent.positionTime), snapshot.duration)
            Task { @MainActor [weak self] in
                self?.seek(to: position / snapshot.duration)
            }
            return .success
        }
        remoteCommandRegistrations.append((commandCenter.changePlaybackPositionCommand, positionTarget))
        updateQueueCapabilities()
    }

    private func handleRemotePlayCommand() -> MPRemoteCommandHandlerStatus {
        lastExplicitRemoteTransportCommandAt = CFAbsoluteTimeGetCurrent()
        if isInterrupted {
            PlaybackDebugLogger.event("audio.transport.play retry_interrupted_session=true source=\(playbackSource)")
        }
        guard systemTransportStartTask == nil, sessionActivationRetryTask == nil else { return .success }
        let wasInterrupted = isInterrupted
        cancelInterruptionResume()
        isInterrupted = PlaybackTransportPolicy.interruptionRemainsActive(after: .explicitPlay)
        clearForcedPausedWindow()
        if playbackSource == .system {
            return startRemotePlaybackAfterActivation()
        }
        // A native-ready engine already owns an active session. Do not enqueue
        // another media-service activation before scheduling its first samples.
        if !wasInterrupted, hasInitializedHiResPlaybackEngine, !audioRenderHealth.isStalled,
           hiResPlaybackEngine.isEngineRunning, hiResPlaybackEngine.hasTrack {
            return startRemotePlaybackAfterActivation()
        }
        let pauseToken = userPauseIntentToken
        let preparationToken = playbackPreparationToken
        let generation = interruptionGeneration
        let requestID = UUID()
        sessionActivationRequestID = requestID
        isPlaybackStarting = true
        sessionActivationRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var handedOff = false
            defer {
                self.finishSessionActivationRequest(requestID, pauseToken: pauseToken,
                    preparationToken: preparationToken, handedOff: handedOff)
            }
            let lease = PlaybackRecoveryBackgroundLease()
            defer { lease.end() }
            do {
                try await PlaybackAudioSession.shared.activate()
                guard PlaybackTransportPolicy.requestIsCurrent(
                    pauseToken: pauseToken, currentPauseToken: self.userPauseIntentToken,
                    preparationToken: preparationToken, currentPreparationToken: self.playbackPreparationToken,
                    interrupted: self.isInterrupted, cancelled: Task.isCancelled
                ), self.interruptionGeneration == generation else { return }
                self.sessionActivationRetryTask = nil
                self.isPlaybackStarting = false
                guard !lease.expired else { return }
                handedOff = true
                _ = self.startRemotePlaybackAfterActivation()
            } catch is CancellationError {
                return
            } catch {
                guard PlaybackTransportPolicy.requestIsCurrent(
                    pauseToken: pauseToken, currentPauseToken: self.userPauseIntentToken,
                    preparationToken: preparationToken, currentPreparationToken: self.playbackPreparationToken,
                    interrupted: self.isInterrupted, cancelled: Task.isCancelled
                ), self.interruptionGeneration == generation else { return }
                PlaybackDebugLogger.warning("audio.session.activation_deferred error=\(error.localizedDescription)")
                self.scheduleRemoteSessionActivationRetry()
            }
        }
        return .success
    }

    private func startRemotePlaybackAfterActivation() -> MPRemoteCommandHandlerStatus {
        if !hasTrack {
            if resumePlaybackFromAnyKnownContext() {
                return .success
            }
            reinforceNowPlayingTransportState()
            return .commandFailed
        }
        switch playbackSource {
        case .local:
            guard hiResPlaybackEngine.hasTrack else {
                if resumePlaybackFromAnyKnownContext() {
                    return .success
                }
                reinforceNowPlayingTransportState()
                return .commandFailed
            }
            guard !PlaybackTransportPolicy.isPlaying(
                nodePlaying: hiResPlaybackEngine.isPlaying && !audioRenderHealth.isStalled,
                engineRunning: hiResPlaybackEngine.isEngineRunning,
                interrupted: isInterrupted, explicitlyPaused: isInForcedPausedWindow
            ) else {
                startTimer()
                refreshPlaybackState()
                updateNowPlayingInfo()
                return .success
            }
            do {
                if audioRenderHealth.isStalled {
                    try hiResPlaybackEngine.seek(to: hiResPlaybackEngine.currentTime())
                }
                try hiResPlaybackEngine.play()
                clearForcedPausedWindow()
                startTimer()
                refreshPlaybackState()
                resumeAutomaticQualityUpgradeIfNeeded()
                if let index = systemQueueIndex { scheduleNextTrackPreload(after: index) }
                return .success
            } catch {
                errorMessage = L10n.tr("error.playback_start_failed", error.localizedDescription)
                return .commandFailed
            }
        case .system:
            ensureSystemPlayerConfigured()
            guard isSystemPlayerConfigured else { return .commandFailed }
            guard systemPlayer.playbackState != .playing else {
                syncSystemPlaybackState()
                startTimer()
                updateNowPlayingInfo()
                return .success
            }
            
            guard systemTransportStartTask == nil else { return .success }
            isPlaying = false
            isProcessing = true
            isPlaybackStarting = true
            clearForcedPausedWindow()
            let pauseToken = userPauseIntentToken
            let preparationToken = playbackPreparationToken
            let generation = interruptionGeneration
            systemPlayer.play()
            updateNowPlayingInfo(force: true)

            systemTransportStartTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.userPauseIntentToken == pauseToken,
                       self.playbackPreparationToken == preparationToken,
                       self.interruptionGeneration == generation {
                        self.systemTransportStartTask = nil
                    }
                }
                let lease = PlaybackRecoveryBackgroundLease()
                defer { lease.end() }
                for poll in 0..<8 {
                    do { try await Task.sleep(nanoseconds: 250_000_000) }
                    catch { return }
                    guard PlaybackTransportPolicy.requestIsCurrent(
                        pauseToken: pauseToken, currentPauseToken: self.userPauseIntentToken,
                        preparationToken: preparationToken, currentPreparationToken: self.playbackPreparationToken,
                        interrupted: self.isInterrupted, cancelled: Task.isCancelled
                    ), self.interruptionGeneration == generation, self.playbackSource == .system else { return }

                    if self.systemPlayer.playbackState == .playing {
                        self.isPlaybackStarting = false
                        self.isProcessing = false
                        self.errorMessage = nil
                        self.syncSystemPlaybackState()
                        self.startTimer()
                        self.startSystemAssetRecoveryIfNeeded()
                        self.reinforceNowPlayingTransportState()
                        return
                    }
                    if poll == 2 || poll == 5 { self.systemPlayer.play() }
                }
                // Continue observing this request; do not replace the queue
                // from an obsolete asynchronous play command.
                self.monitorPlaybackStart(for: .system)
            }
            persistLibraryState()
            return .success
        }
    }

    private func finishSessionActivationRequest(_ requestID: UUID, pauseToken: UInt64,
                                                preparationToken: UInt64, handedOff: Bool) {
        // An old task's defer must never clear its replacement or a new load.
        guard sessionActivationRequestID == requestID else { return }
        sessionActivationRequestID = nil
        sessionActivationRetryTask = nil
        if !handedOff, userPauseIntentToken == pauseToken,
           playbackPreparationToken == preparationToken {
            isPlaybackStarting = false
        }
    }

    private func scheduleRemoteSessionActivationRetry() {
        sessionActivationRetryTask?.cancel()
        let pauseToken = userPauseIntentToken
        let preparationToken = playbackPreparationToken
        let requestID = UUID()
        sessionActivationRequestID = requestID
        isPlaybackStarting = true

        let backgroundLease = PlaybackRecoveryBackgroundLease()
        sessionActivationRetryTask = Task { @MainActor [weak self] in
            defer { backgroundLease.end() }
            guard let self else { return }
            defer {
                self.finishSessionActivationRequest(requestID, pauseToken: pauseToken,
                    preparationToken: preparationToken, handedOff: false)
            }
            let retryDelays: [UInt64] = [
                150_000_000,
                350_000_000,
                700_000_000,
                1_200_000_000,
                2_000_000_000
            ]
            var lastError: Error?

            for (attempt, delay) in retryDelays.enumerated() {
                do {
                    try await Task.sleep(nanoseconds: delay)
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      self.userPauseIntentToken == pauseToken,
                      self.playbackPreparationToken == preparationToken,
                      !self.isInterrupted,
                      !self.isInForcedPausedWindow else {
                    return
                }

                do {
                    try await PlaybackAudioSession.shared.activate()
                    guard PlaybackTransportPolicy.requestIsCurrent(
                        pauseToken: pauseToken, currentPauseToken: self.userPauseIntentToken,
                        preparationToken: preparationToken, currentPreparationToken: self.playbackPreparationToken,
                        interrupted: self.isInterrupted, cancelled: Task.isCancelled
                    ), !self.isInForcedPausedWindow else { return }

                    if backgroundLease.expired { break }
                    let didStart: Bool
                    switch self.playbackSource {
                    case .local:
                        guard self.hasInitializedHiResPlaybackEngine,
                              self.hiResPlaybackEngine.hasTrack else {
                            didStart = self.resumePlaybackFromAnyKnownContext()
                            break
                        }
                        try self.hiResPlaybackEngine.play()
                        try await Task.sleep(nanoseconds: 160_000_000)
                        didStart = self.hiResPlaybackEngine.isPlaying
                            && self.hiResPlaybackEngine.isEngineRunning
                    case .system:
                        self.ensureSystemPlayerConfigured()
                        self.systemPlayer.play()
                        try await Task.sleep(nanoseconds: 220_000_000)
                        didStart = self.systemPlayer.playbackState == .playing
                    }

                    guard PlaybackTransportPolicy.requestIsCurrent(
                        pauseToken: pauseToken, currentPauseToken: self.userPauseIntentToken,
                        preparationToken: preparationToken, currentPreparationToken: self.playbackPreparationToken,
                        interrupted: self.isInterrupted, cancelled: Task.isCancelled
                    ) else { return }
                    if didStart {
                        self.clearForcedPausedWindow()
                        self.isPlaying = true
                        self.isProcessing = false
                        self.isPlaybackStarting = false
                        self.errorMessage = nil
                        self.sessionActivationRetryTask = nil
                        self.startTimer()
                        self.refreshPlaybackState()
                        self.updateNowPlayingInfo(force: true)
                        PlaybackDebugLogger.event(
                            "audio.session.activation_recovered attempt=\(attempt + 1)"
                        )
                        return
                    }
                } catch {
                    lastError = error
                    PlaybackDebugLogger.warning(
                        "audio.session.activation_retry attempt=\(attempt + 1) error=\(error.localizedDescription)"
                    )
                }
            }

            let playbackRecovered = self.actualPlaybackState == .playing
            guard !Task.isCancelled, self.sessionActivationRequestID == requestID,
                  !playbackRecovered,
                  self.userPauseIntentToken == pauseToken,
                  self.playbackPreparationToken == preparationToken else {
                return
            }
            self.errorMessage = L10n.tr(
                "error.playback_session_failed",
                lastError?.localizedDescription ?? "Session activation failed"
            )
        }
    }

    private func handleRemotePauseCommand(origin: String = "app") -> MPRemoteCommandHandlerStatus {
        let elapsed = playbackSource == .local
            ? hiResPlaybackEngine.currentTime() : systemPlayer.currentPlaybackTime
        PlaybackDebugLogger.event("audio.transport.pause origin=\(origin) source=\(playbackSource) time=\(elapsed) generation=\(playbackPreparationToken)")
        lastExplicitRemoteTransportCommandAt = CFAbsoluteTimeGetCurrent()
        recordUserPauseIntent()
        switch playbackSource {
        case .local:
            guard hiResPlaybackEngine.hasTrack else { return .commandFailed }
            
            hiResPlaybackEngine.pause()
            isPlaying = false
            stopTimer()
            beginForcedPausedWindow(for: .local)
            forcedWriteNowPlayingPaused()
            reinforceNowPlayingTransportState()
            persistLibraryState()
            return .success
            
        case .system:
            ensureSystemPlayerConfigured()
            guard isSystemPlayerConfigured else { return .commandFailed }

            systemPlayer.pause()

            isPlaying = false
            stopTimer()
            beginForcedPausedWindow(for: .system, duration: 1.0)
            
            syncSystemPlaybackState()
            forcedWriteNowPlayingPaused()
            reinforceNowPlayingTransportState()
            persistLibraryState()
            return .success
        }
    }

    private func recordUserPauseIntent() {
        userPauseIntentToken &+= 1
        cancelSystemAssetRecovery()
        preloadTrackTask?.cancel()
        isSystemPlayerStarting = false
        localPlaybackLoadTask?.cancel()
        localPlaybackLoadTask = nil
        unexpectedPlaybackRecoveryTask?.cancel()
        unexpectedPlaybackRecoveryTask = nil
        cancelInterruptionResume()
        systemTransportStartTask?.cancel()
        systemTransportStartTask = nil
        playbackStartMonitorTask?.cancel()
        playbackStartMonitorTask = nil
        isPlaybackStarting = false
        isProcessing = false
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
    }

    /// 【必須】ウィジェット状態の強制上書き
    /// stop() や pause() の直後に呼ぶ。既存の辞書を書き換えるのではなく、
    /// 「再生レート 0.0」が刻まれた純粋な辞書を新しく生成してセットすることで、
    /// システム側の古いキャッシュや予測ロジックによる「再生中」への回帰を回避します。
    private func forcedWriteNowPlayingPaused(item: MPMediaItem? = nil, elapsed: TimeInterval = 0) {
        guard playbackSource == .local else { return }
        let title: String
        let subtitle: String
        let duration: TimeInterval
        let artwork: UIImage?
        let elapsedTime: TimeInterval

        if let item {
            title = item.title ?? trackTitle
            subtitle = queueAwareSubtitle(
                artist: item.artist ?? L10n.unknownArtist(),
                album: item.albumTitle ?? L10n.unknownAlbum(),
                queueTitle: systemQueueTitle
            )
            let raw = item.playbackDuration
            duration = (raw.isFinite && raw > 0) ? raw : 0
            artwork = item.artwork?.image(at: CGSize(width: 600, height: 600)) ?? nowPlayingArtwork
            elapsedTime = duration > 0 ? min(max(0, elapsed), duration) : max(0, elapsed)
        } else {
            // fallback: snapshotから取得
            let snapshot = makeNowPlayingSnapshot()
            guard snapshot.hasTrack else { return }
            title = snapshot.title
            subtitle = snapshot.subtitle
            duration = snapshot.duration
            artwork = snapshot.artwork
            elapsedTime = snapshot.elapsed
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: subtitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsedTime,
            MPNowPlayingInfoPropertyPlaybackRate: 0.0,
        ]
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        
        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = info
    }

    private struct NowPlayingSnapshot {
        let hasTrack: Bool
        let trackKey: String?
        let title: String
        let subtitle: String
        let duration: TimeInterval
        let elapsed: TimeInterval
        let artwork: UIImage?
    }

    private func makeNowPlayingSnapshot() -> NowPlayingSnapshot {
        switch playbackSource {
        case .local:
            guard hiResPlaybackEngine.hasTrack else {
                return NowPlayingSnapshot(
                    hasTrack: false,
                    trackKey: nil,
                    title: "",
                    subtitle: "",
                    duration: 0,
                    elapsed: 0,
                    artwork: nil
                )
            }
            let duration = max(0, hiResPlaybackEngine.duration)
            let elapsed = min(max(0, hiResPlaybackEngine.currentTime()), duration)
            let trackKey = "local-\(selectedSystemSongID ?? 0)-\(trackTitle)-\(trackSubtitle)-\(Int(duration.rounded()))"
            return NowPlayingSnapshot(
                hasTrack: true,
                trackKey: trackKey,
                title: trackTitle,
                subtitle: trackSubtitle,
                duration: duration,
                elapsed: elapsed,
                artwork: nowPlayingArtwork
            )

        case .system:
            let item = isSystemPlayerConfigured ? systemPlayer.nowPlayingItem : nil
            let hasTrack = item != nil || selectedSystemSongID != nil
            guard hasTrack else {
                return NowPlayingSnapshot(
                    hasTrack: false,
                    trackKey: nil,
                    title: "",
                    subtitle: "",
                    duration: 0,
                    elapsed: 0,
                    artwork: nil
                )
            }

            let title = item?.title ?? trackTitle
            let subtitle: String
            if let item {
                subtitle = queueAwareSubtitle(
                    artist: item.artist ?? L10n.unknownArtist(),
                    album: item.albumTitle ?? L10n.unknownAlbum(),
                    queueTitle: systemQueueTitle
                )
            } else {
                subtitle = trackSubtitle
            }

            let rawDuration = item?.playbackDuration ?? 0
            let duration = (rawDuration.isFinite && rawDuration > 0) ? rawDuration : 0
            let rawElapsed = isSystemPlayerConfigured ? systemPlayer.currentPlaybackTime : 0
            let elapsed = duration > 0
                ? min(max(0, rawElapsed), duration)
                : max(0, rawElapsed)
            let artwork = item?.artwork?.image(at: CGSize(width: 600, height: 600)) ?? nowPlayingArtwork
            let resolvedID = selectedSystemSongID ?? UInt64(item?.persistentID ?? 0)
            let trackKey = "system-\(resolvedID)-\(title)-\(subtitle)-\(Int(duration.rounded()))"
            return NowPlayingSnapshot(
                hasTrack: true,
                trackKey: trackKey,
                title: title,
                subtitle: subtitle,
                duration: duration,
                elapsed: elapsed,
                artwork: artwork
            )
        }
    }

    private func updateNowPlayingInfo(force: Bool = false) {
        let currentState = actualPlaybackState
        if isPlaying && currentState != .playing {
            let engineState = hasInitializedHiResPlaybackEngine
                ? "engineRunning=\(hiResPlaybackEngine.isEngineRunning) enginePlaying=\(hiResPlaybackEngine.isPlaying) time=\(hiResPlaybackEngine.currentTime())"
                : "engine=uninitialized"
            PlaybackDebugLogger.warning("audio.transport.observed_stop source=\(playbackSource) interrupted=\(isInterrupted) forcedPause=\(isInForcedPausedWindow) \(engineState)")
        }
        isPlaying = currentState == .playing
        // The system player already publishes its own lock-screen session.
        // Do not compete with it by advertising our inactive local engine.
        guard playbackSource == .local else { return }

        let snapshot = makeNowPlayingSnapshot()
        
        guard snapshot.hasTrack else {
            if lastNowPlayingTrackKey != nil {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            }
            lastNowPlayingTrackKey = nil
            lastNowPlayingState = .unknown
            lastNowPlayingElapsed = 0
            return
        }

        // iOS advances elapsed time from the published rate. Replacing the
        // metadata/artwork dictionary on every 250 ms tick needlessly rebuilds
        // MediaRemote handlers; update only for transport/track changes or drift.
        guard PlaybackTransportPolicy.shouldPublishNowPlaying(
            systemSource: false, force: force,
            trackChanged: snapshot.trackKey != lastNowPlayingTrackKey,
            stateChanged: currentState != lastNowPlayingState,
            elapsedDelta: snapshot.elapsed - lastNowPlayingElapsed
        ) else { return }

        // Rebuild the dictionary for every track/state update. Reusing the
        // previous dictionary can leave stale artwork or metadata on the lock screen.
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.subtitle,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: currentState == .playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]

        if let artwork = snapshot.artwork {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in
                artwork
            }
        }

        let center = MPNowPlayingInfoCenter.default()
        center.nowPlayingInfo = nowPlayingInfo

        lastNowPlayingTrackKey = snapshot.trackKey
        lastNowPlayingState = currentState
        lastNowPlayingElapsed = snapshot.elapsed
    }

    private func stopCurrentPlaybackForTransition(pauseSystemPlayback: Bool = false) {
        systemAssetRecoveryFailure = nil
        cancelSystemAssetRecovery()
        isSystemPlayerStarting = false
        cancelInterruptionResume()
        systemTransportStartTask?.cancel()
        systemTransportStartTask = nil
        unexpectedPlaybackRecoveryTask?.cancel()
        unexpectedPlaybackRecoveryTask = nil
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
        localPlaybackLoadTask?.cancel()
        localPlaybackLoadTask = nil
        precisionUpgradeTask?.cancel()
        preloadTrackTask?.cancel()
        playbackStartMonitorTask?.cancel()
        playbackStartMonitorTask = nil
        playbackPreparationToken &+= 1
        switch playbackSource {
        case .local:
            PlaybackDebugLogger.event(
                "audio.transition.stop_local \(HiResPlaybackEngine.processMemoryDiagnostic)"
            )
            hiResPlaybackEngine.cancelBackgroundPreparation()
            hiResPlaybackEngine.stop()
            remotePlaybackFile = nil
            musicPlaybackSnapshot = nil
            localPlaybackFormatDescription = L10n.playbackFormatUnavailable()
        case .system:
            if pauseSystemPlayback && isSystemPlayerConfigured {
                systemPlayer.pause()
            }
            // システムプレーヤーからシステムプレーヤー（別の曲）への遷移時は、
            // setQueue が自動的に現在の再生を停止・置換するため、明示的な stop() は不要。
            // 逆に stop() を呼ぶとデーモン側の状態が不安定になり no target descriptor を誘発する可能性がある。
            print("[Playback] System source transition - skipping explicit systemPlayer.stop().")
            break
        }

        stopTimer()
        clearForcedPausedWindow()
        isPlaying = false
        reinforceNowPlayingTransportState()
    }

    private func startProtectedSystemPlayback(with items: [MPMediaItem], autoplay: Bool = true) {
        guard let item = items.first else {
            isProcessing = false
            isPlaybackStarting = false
            errorMessage = L10n.tr("error.queue_not_found")
            return
        }

        stopCurrentPlaybackForTransition()
        playbackSource = .system
        // A local-session interruption is not the Music app's playback state.
        isInterrupted = false
        ensureSystemPlayerConfigured()
        let transitionToken = playbackPreparationToken
        let pauseToken = userPauseIntentToken
        let expectedSongID = UInt64(item.persistentID)
        selectedSystemSongID = expectedSongID
        systemRequestedSongID = expectedSongID
        systemRequestedStoreID = item.playbackStoreID
        lastObservedSystemPlaybackSongID = expectedSongID
        lastObservedSystemPlaybackProgress = 0
        systemPreparationState = .preparing
        isPlaying = false
        isProcessing = true
        isPlaybackStarting = true
        isSystemPlayerStarting = true
        errorMessage = nil
        localPlaybackFormatDescription = item.hasProtectedAsset
            ? L10n.playbackFormatProtected() : L10n.tr("playback.format.system")

        systemTransportStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let lease = PlaybackRecoveryBackgroundLease()
            defer {
                lease.end()
                if self.playbackPreparationToken == transitionToken,
                   self.userPauseIntentToken == pauseToken {
                    self.systemTransportStartTask = nil
                    self.isSystemPlayerStarting = false
                    self.isProcessing = false
                    self.isPlaybackStarting = false
                }
            }
            @MainActor func requestIsCurrent() -> Bool {
                !Task.isCancelled && self.playbackPreparationToken == transitionToken
                    && self.userPauseIntentToken == pauseToken
                    && self.playbackSource == .system
                    && self.selectedSystemSongID == expectedSongID
            }

            // Await local fade/drain before handing the session to Music.
            // Recheck intent after waiting so an old task cannot release a new session.
            do {
                guard requestIsCurrent() else { return }
                if self.hasInitializedHiResPlaybackEngine {
                    let generation = self.hiResPlaybackEngine.stop()
                    try await self.hiResPlaybackEngine.waitForStop(generation: generation)
                }
                guard requestIsCurrent() else { return }
                try await PlaybackAudioSession.shared.releaseForSystemPlayback()
            } catch {
                return
            }
            guard requestIsCurrent() else { return }
            if self.lastNowPlayingTrackKey != nil {
                MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
                self.lastNowPlayingTrackKey = nil
                self.lastNowPlayingState = .unknown
                self.lastNowPlayingElapsed = 0
            }
            self.logProtectedPlaybackDiagnostics("prepare_begin", queueItems: [item])
            self.systemPlayer.setQueue(with: MPMediaItemCollection(items: items))
            self.systemPlayer.prepareToPlay { [weak self] error in
                let message = error?.localizedDescription
                Task { @MainActor [weak self] in
                    guard let self,
                          self.playbackPreparationToken == transitionToken,
                          self.userPauseIntentToken == pauseToken,
                          self.playbackSource == .system else { return }
                    if let message {
                        self.systemPreparationState = .failed(message)
                        PlaybackDebugLogger.warning("audio.system.prepare_failed error=\(message)")
                    } else {
                        self.systemPreparationState = .ready
                        self.isProcessing = false
                        if !autoplay {
                            self.systemTransportStartTask?.cancel()
                            self.systemTransportStartTask = nil
                            self.isSystemPlayerStarting = false
                            self.isPlaybackStarting = false
                        }
                        self.logProtectedPlaybackDiagnostics("prepare_ready")
                    }
                }
            }

            // Polling is bounded even if Apple's completion/notifications never
            // arrive. Do not repeatedly replace a queue that is still preparing.
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            var issuedPlay = false
            var pollsAfterPlay = 0
            while requestIsCurrent() {
                let confirmed = PlaybackTransportPolicy.systemStartConfirmed(
                    expectedSongID: expectedSongID, observedSongID: self.resolvedSystemSongID,
                    playing: self.systemPlayer.playbackState == .playing,
                    interrupted: false, explicitlyPaused: self.isInForcedPausedWindow
                )
                let prepared: Bool
                let preparationError: String?
                switch self.systemPreparationState {
                case .ready: prepared = true; preparationError = nil
                case .failed(let message): prepared = false; preparationError = message
                case .idle, .preparing: prepared = false; preparationError = nil
                }
                if prepared && !autoplay {
                    self.isPlaying = false
                    self.isProcessing = false
                    self.isPlaybackStarting = false
                    self.isSystemPlayerStarting = false
                    self.updateQueueCapabilities()
                    return
                }
                let action = PlaybackTransportPolicy.systemStartupAction(
                    confirmed: confirmed, prepared: prepared,
                    preparationFailed: preparationError != nil, playIssued: issuedPlay,
                    deadlineReached: ContinuousClock.now >= deadline
                )
                switch action {
                case .complete:
                    self.syncSystemPlaybackState()
                    self.isProcessing = false
                    self.isPlaybackStarting = false
                    self.isSystemPlayerStarting = false
                    self.errorMessage = nil
                    self.startTimer()
                    self.persistLibraryState()
                    self.logProtectedPlaybackDiagnostics("start_confirmed")
                    self.startSystemAssetRecoveryIfNeeded()
                    if let index = self.systemQueueIndex { self.scheduleNextTrackPreload(after: index) }
                    return
                case .preparationFailed:
                    self.errorMessage = L10n.tr("error.playback_start_failed", preparationError ?? "")
                    self.logProtectedPlaybackDiagnostics("start_failed")
                    return
                case .play:
                    self.systemPlayer.play()
                    issuedPlay = true
                    self.logProtectedPlaybackDiagnostics("play_issued")
                case .wait:
                    if issuedPlay {
                        pollsAfterPlay += 1
                        // Retry play, not setQueue, and only for the intended item.
                        if (pollsAfterPlay == 8 || pollsAfterPlay == 20),
                           self.resolvedSystemSongID == expectedSongID,
                           self.systemPlayer.playbackState == .paused {
                            self.systemPlayer.play()
                        }
                    }
                case .timedOut:
                    self.logProtectedPlaybackDiagnostics("start_timeout")
                    self.errorMessage = L10n.tr("error.system_playback_timeout")
                    // A late start can still be observed; selection/retry is unblocked.
                    self.startTimer()
                    return
                }
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
            }
        }
    }

    private func resolveAlbum(from item: MPMediaItem) -> SystemAlbum? {
        let song = SystemSong(
            id: UInt64(item.persistentID), title: item.title ?? L10n.unknownTitle(),
            artist: item.artist ?? L10n.unknownArtist(), album: item.albumTitle ?? L10n.unknownAlbum(),
            artistID: item.artistPersistentID == 0 ? nil : UInt64(item.artistPersistentID),
            albumID: item.albumPersistentID == 0 ? nil : UInt64(item.albumPersistentID),
            discNumber: item.discNumber, trackNumber: item.albumTrackNumber,
            duration: item.playbackDuration, url: nil, albumArtist: item.albumArtist
        )
        return SystemLibraryIndex.album(for: song, in: systemAlbums)
    }

    private func refreshNowPlayingAlbum() {
        if let song = currentPlaybackSong {
            nowPlayingAlbum = SystemLibraryIndex.album(for: song, in: systemAlbums)
        } else if playbackSource == .system, isSystemPlayerConfigured,
                  let item = systemPlayer.nowPlayingItem {
            nowPlayingAlbum = resolveAlbum(from: item)
        } else if !hasTrack {
            nowPlayingAlbum = nil
        }
    }

    @discardableResult
    private func playHiResLocalOrSystemSong(
        song: SystemSong,
        mediaItem: MPMediaItem?,
        assetURL: URL,
        queueTitle: String?,
        autoplay: Bool,
        restoreUpsamplingMode: UpsamplingMode? = nil
    ) -> Bool {
        cancelLibraryWorkForPlayback(force: true)
        localPlaybackFormatDescription = L10n.tr("playback.preparing")
        stopCurrentPlaybackForTransition(pauseSystemPlayback: true)
        playbackSource = .local
        selectedSystemSongID = song.id
        trackTitle = song.title
        trackSubtitle = queueAwareSubtitle(artist: song.artist, album: song.album, queueTitle: queueTitle)
        
        if let mediaItem = mediaItem {
            nowPlayingArtwork = mediaItem.artwork?.image(at: CGSize(width: 600, height: 600))
            nowPlayingAlbum = resolveAlbum(from: mediaItem)
        } else {
            // ローカルファイルの場合は非同期で取得済みの可能性もあるが、ここで再確認
            nowPlayingAlbum = matchingAlbum(from: song)
            let artworkSongID = song.id
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let art = await LocalMediaManager.shared.fetchArtwork(from: assetURL) {
                    guard self.selectedSystemSongID == artworkSongID,
                          self.playbackSource == .local else { return }
                    self.nowPlayingArtwork = art
                }
            }
        }

        localPlaybackLoadTask?.cancel()
        let preparationToken = playbackPreparationToken
        localPlaybackLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let preparedAssetURL: URL
            do {
                let file = try await RemoteAudioCache.shared.playbackFile(for: assetURL)
                try Task.checkCancellation()
                guard self.playbackPreparationToken == preparationToken,
                      self.selectedSystemSongID == song.id else { throw CancellationError() }
                self.remotePlaybackFile = file
                preparedAssetURL = file.url
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      self.playbackPreparationToken == preparationToken,
                      self.selectedSystemSongID == song.id,
                      self.playbackSource == .local else { return }
                self.errorMessage = L10n.tr("error.playback_prepare_failed", error.localizedDescription)
                self.isPlaying = false
                self.isProcessing = false
                self.isPlaybackStarting = false
                self.localPlaybackLoadTask = nil
                return
            }

            do {
                try Task.checkCancellation()
                guard self.playbackPreparationToken == preparationToken,
                      self.selectedSystemSongID == song.id else {
                    throw CancellationError()
                }
                let preferredUpsampling = restoreUpsamplingMode
                    ?? self.memorySafetyMode.automaticUpsamplingMode
                let requestedUpsampling = self.safeUpsamplingMode(preferredUpsampling)
                self.upsamplingMode = requestedUpsampling
                let shouldUseTwoStageLoad = requestedUpsampling.isPrecisionSinc

                let snapshot = try await MusicAssetPreparation.loadForPlayback(
                    url: preparedAssetURL, protectedAsset: mediaItem?.hasProtectedAsset == true,
                    onReadFailure: { error in
                        PlaybackDebugLogger.warning("audio.asset.local_open_failed songID=\(song.id) \(AudioPreparationFailure.diagnostic(error, fallbackStage: .streamingOpen))")
                    }
                ) { candidateURL in
                    try Task.checkCancellation()
                    guard self.playbackPreparationToken == preparationToken,
                          self.selectedSystemSongID == song.id,
                          self.playbackSource == .local else { throw CancellationError() }
                    if candidateURL != preparedAssetURL {
                        PlaybackDebugLogger.event("audio.asset.local_snapshot_retry songID=\(song.id)")
                    }
                    try await self.hiResPlaybackEngine.load(
                        url: candidateURL,
                        effectSettings: self.playbackEffectSettings,
                        headphoneSpatialSettings: self.playbackSpatialSettings,
                        upsamplingMode: requestedUpsampling,
                        strategy: .immediateStreaming
                    )
                }
                try Task.checkCancellation()
                guard self.playbackPreparationToken == preparationToken,
                      self.selectedSystemSongID == song.id,
                      self.playbackSource == .local else {
                    throw CancellationError()
                }
                self.musicPlaybackSnapshot = snapshot
                let playbackAssetURL = snapshot?.url ?? preparedAssetURL
                if snapshot != nil {
                    PlaybackDebugLogger.event("audio.asset.local_snapshot_ready songID=\(song.id)")
                }
                self.localPlaybackFormatDescription = self.hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                // Native scheduling is ready. Background quality must not own
                // the foreground loading state or keep transport disabled.
                self.localPlaybackLoadTask = nil
                self.isProcessing = false
                self.isPlaybackStarting = false
                if autoplay && !self.isInterrupted {
                    try self.hiResPlaybackEngine.play()
                    self.clearForcedPausedWindow()
                    self.isPlaying = true
                    self.startTimer()
                } else {
                    self.beginForcedPausedWindow(for: .local)
                    self.isPlaying = false
                }
                self.refreshPlaybackState()
                self.resumePendingInterruptionIfNeeded()
                if shouldUseTwoStageLoad && self.isBackgroundQualityUpgradeEnabled {
                    self.startPrecisionSincUpgrade(
                        songID: song.id,
                        assetURL: playbackAssetURL,
                        targetUpsampling: requestedUpsampling
                    )
                }
                if self.playbackPreparationToken == preparationToken {
                    self.localPlaybackLoadTask = nil
                }
                return
            } catch is CancellationError {
                return
            } catch {
                // Music asset URLs are not guaranteed to remain readable by
                // AVAudioFile, even when hasProtectedAsset is false. Let Music
                // resolve its own asset instead of repeatedly decoding that URL.
                guard !Task.isCancelled,
                      self.playbackPreparationToken == preparationToken,
                      self.selectedSystemSongID == song.id,
                      self.playbackSource == .local else { return }
                PlaybackDebugLogger.warning(
                    "audio.prepare.failed songID=\(song.id) path=streaming requestedMode=\(self.upsamplingMode.rawValue) \(AudioPreparationFailure.diagnostic(error, fallbackStage: .streamingStart))")
                if let mediaItem {
                    PlaybackDebugLogger.warning("audio.asset.fallback songID=\(song.id) reason=local_prepare_failed")
                    // Detach this task before transition cleanup cancels local work.
                    self.localPlaybackLoadTask = nil
                    self.stopCurrentPlaybackForTransition(pauseSystemPlayback: true)
                    self.errorMessage = nil
                    self.isProcessing = false
                    self.isPlaybackStarting = false
                    self.prepareSystemPlaybackFallback(
                        song: song, mediaItem: mediaItem, queueTitle: queueTitle,
                        autoplay: autoplay && !self.isInterrupted
                    )
                    return
                }
                self.errorMessage = L10n.tr("error.playback_prepare_failed", error.localizedDescription)
            }

            guard !Task.isCancelled, self.playbackPreparationToken == preparationToken else { return }

            if mediaItem == nil {
                self.playbackSource = .local
                self.isPlaying = false
                self.stopTimer()
                self.localPlaybackFormatDescription = L10n.playbackFormatUnavailable()
                self.refreshPlaybackState()
            }

            if self.errorMessage == nil {
                self.errorMessage = L10n.tr("error.playback_prepare_failed", L10n.tr("error.upconvert_failed"))
            }
            self.localPlaybackLoadTask = nil
        }

        return true
    }

    private func prepareSystemPlaybackFallback(
        song: SystemSong,
        mediaItem: MPMediaItem,
        queueTitle: String?,
        autoplay: Bool
    ) {
        playbackSource = .system
        ensureSystemPlayerConfigured()
        systemPlayer.repeatMode = .none
        systemPlayer.shuffleMode = .off
        selectedSystemSongID = song.id
        trackTitle = song.title
        trackSubtitle = queueAwareSubtitle(artist: song.artist, album: song.album, queueTitle: queueTitle)
        nowPlayingArtwork = mediaItem.artwork?.image(at: CGSize(width: 600, height: 600))
        nowPlayingAlbum = resolveAlbum(from: mediaItem)
        localPlaybackFormatDescription = mediaItem.hasProtectedAsset
            ? L10n.playbackFormatProtected() : L10n.tr("playback.format.system")

        startProtectedSystemPlayback(with: [mediaItem], autoplay: autoplay)
        if !autoplay {
            isPlaying = false
            progress = 0
            currentTimeText = "00:00"
            durationText = formatTime(mediaItem.playbackDuration)
            updateQueueCapabilities()
            updateNowPlayingInfo(force: true)
        }
    }

    private func currentPlaybackSnapshot() -> PlaybackSnapshot? {
        guard let selectedSystemSongID, let queueIndex = systemQueueIndex else { return nil }
        return PlaybackSnapshot(
            selectedSongID: selectedSystemSongID,
            queueSongIDs: systemQueue.map(\.id),
            queueIndex: queueIndex,
            queueTitle: systemQueueTitle
        )
    }

    @discardableResult
    private func resumePlaybackFromSnapshotIfPossible() -> Bool {
        guard let snapshot = currentPlaybackSnapshot() else { return false }
        let queueSongs = snapshot.queueSongs(from: systemSongs)
        guard queueSongs.indices.contains(snapshot.queueIndex) else { return false }
        playSystemQueue(queueSongs, startAt: snapshot.queueIndex, title: snapshot.queueTitle)
        return true
    }

    @discardableResult
    private func resumePlaybackFromAnyKnownContext() -> Bool {
        if resumePlaybackFromSnapshotIfPossible() {
            return true
        }

        if let pending = pendingPlaybackSnapshot {
            let queueSongs = pending.queueSongs(from: systemSongs)
            if queueSongs.indices.contains(pending.queueIndex) {
                playSystemQueue(queueSongs, startAt: pending.queueIndex, title: pending.queueTitle)
                return true
            }
        }

        if let selectedSystemSongID {
            if let queueIndex = systemQueue.firstIndex(where: { $0.id == selectedSystemSongID }), !systemQueue.isEmpty {
                playSystemQueue(systemQueue, startAt: queueIndex, title: systemQueueTitle)
                return true
            }

            if let selectedSong = systemSongs.first(where: { $0.id == selectedSystemSongID }) {
                playSystemQueue([selectedSong], startAt: 0, title: nil)
                return true
            }

            if let item = systemMediaLibrary.mediaItem(for: selectedSystemSongID) {
                let fallbackSong = SystemSong(
                    id: selectedSystemSongID,
                    title: item.title ?? L10n.unknownTitle(),
                    artist: item.artist ?? L10n.unknownArtist(),
                    album: item.albumTitle ?? L10n.unknownAlbum(),
                    artistID: item.albumArtistPersistentID == 0 ? nil : UInt64(item.albumArtistPersistentID),
                    albumID: item.albumPersistentID == 0 ? nil : UInt64(item.albumPersistentID),
                    discNumber: item.discNumber > 0 ? item.discNumber : nil,
                    trackNumber: item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
                    duration: item.playbackDuration,
                    url: nil
                )
                playSystemQueue([fallbackSong], startAt: 0, title: nil)
                return true
            }
        }

        if isSystemPlayerConfigured, let item = systemPlayer.nowPlayingItem {
            let songID = UInt64(item.persistentID)
            let fallbackSong = SystemSong(
                id: songID,
                title: item.title ?? L10n.unknownTitle(),
                artist: item.artist ?? L10n.unknownArtist(),
                album: item.albumTitle ?? L10n.unknownAlbum(),
                artistID: item.albumArtistPersistentID == 0 ? nil : UInt64(item.albumArtistPersistentID),
                albumID: item.albumPersistentID == 0 ? nil : UInt64(item.albumPersistentID),
                discNumber: item.discNumber > 0 ? item.discNumber : nil,
                trackNumber: item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
                duration: item.playbackDuration,
                url: nil
            )
            playSystemQueue([fallbackSong], startAt: 0, title: nil)
            return true
        }

        return false
    }

    private func restorePlaybackIfNeeded() {
        guard let snapshot = pendingPlaybackSnapshot else { return }
        // ライブラリ更新は再生中にも発生し得るため、既存の再生を再構築しない。
        // 復元は起動直後など、まだトラックがない場合だけ許可する。
        guard !hasTrack, !isProcessing else { return }
        guard !systemSongs.isEmpty else { return }

        let restoredQueue = snapshot.queueSongs(from: systemSongs)
        guard !restoredQueue.isEmpty else {
            pendingPlaybackSnapshot = nil
            return
        }

        let restoredIndex = min(max(0, snapshot.queueIndex), restoredQueue.count - 1)
        let selectedSong = restoredQueue[restoredIndex]
        systemQueue = restoredQueue
        systemQueueIndex = restoredIndex
        systemQueueTitle = snapshot.queueTitle
        selectedSystemSongID = selectedSong.id

        // Restoration must use the same DRM/availability routing as explicit playback.
        let (playbackURL, currentItem) = resolvePlayableAsset(for: selectedSong)

        if let assetURL = playbackURL {
            let hiResRestored = playHiResLocalOrSystemSong(
                song: selectedSong,
                mediaItem: currentItem,
                assetURL: assetURL,
                queueTitle: snapshot.queueTitle,
                autoplay: false,
                restoreUpsamplingMode: .avAudioConverter
            )
            if !hiResRestored {
                if let item = currentItem {
                    prepareSystemPlaybackFallback(
                        song: selectedSong,
                        mediaItem: item,
                        queueTitle: snapshot.queueTitle,
                        autoplay: false
                    )
                }
            }
        } else if let item = currentItem {
            prepareSystemPlaybackFallback(song: selectedSong, mediaItem: item,
                queueTitle: snapshot.queueTitle, autoplay: false)
        }

        
        updateQueueCapabilities()
        updateNowPlayingInfo()
        pendingPlaybackSnapshot = nil
    }

    private func currentStoredEffectSettings() -> [StoredEffectSetting] {
        effectSettings.map { setting in
            StoredEffectSetting(
                kind: setting.kind.rawValue,
                isEnabled: setting.isEnabled,
                parameters: setting.parameters
            )
        }
    }

    private func restoreEffectSettingsIfNeeded() {
        guard !pendingEffectSettings.isEmpty else { return }

        var restoredSettings = AudioEffectModuleRegistry.makeDefaultSettings()
        for stored in pendingEffectSettings {
            guard let kind = RealtimeAudioEffectKind(rawValue: stored.kind),
                  let index = restoredSettings.firstIndex(where: { $0.kind == kind }) else {
                continue
            }

            restoredSettings[index].isEnabled = stored.isEnabled

            let validKeys = Set(kind.parameterDefinitions.map(\.key))
            for (key, value) in stored.parameters where validKeys.contains(key) {
                restoredSettings[index].parameters[key] = min(max(value, 0.0), 1.0)
            }
        }

        effectSettings = restoredSettings
        pendingEffectSettings.removeAll()
    }

    private func scheduleHeadphoneSpatialSettingsApply() {
        isSpatialProcessing = true
        headphoneSpatialApplyTimer?.invalidate()
        headphoneSpatialApplyTimer = Timer.scheduledTimer(
            timeInterval: 0.22,
            target: self,
            selector: #selector(handleHeadphoneSpatialApplyTimer),
            userInfo: nil,
            repeats: false
        )
    }

    private func scheduleHeadphoneSpatialPresetApply() {
        isSpatialProcessing = true
        headphoneSpatialApplyTimer?.invalidate()
        headphoneSpatialApplyTimer = Timer.scheduledTimer(
            timeInterval: 0.05,
            target: self,
            selector: #selector(handleHeadphoneSpatialApplyTimer),
            userInfo: nil,
            repeats: false
        )
    }

    @objc private func handleHeadphoneSpatialApplyTimer() {
        applyHeadphoneSpatialSettingsIfNeeded(immediately: true)
        persistLibraryState()
    }

    @objc private func handleHeadphoneSpatialToggleTimer() {
        applyHeadphoneSpatialSettingsIfNeeded(immediately: true)
        persistLibraryState()
    }

    private func applyHeadphoneSpatialSettingsIfNeeded(immediately: Bool) {
        if immediately {
            headphoneSpatialApplyTimer?.invalidate()
            headphoneSpatialApplyTimer = nil
        }
        guard playbackSource == .local, hiResPlaybackEngine.hasTrack else {
            isSpatialProcessing = false
            return
        }
        let requestID = UUID()
        spatialRequestID = requestID
        let preparationToken = playbackPreparationToken
        hiResPlaybackEngine.updateHeadphoneSpatialSettings(playbackSpatialSettings, effectSettings: playbackEffectSettings) { [weak self] error in
            guard let self, self.spatialRequestID == requestID,
                  self.playbackPreparationToken == preparationToken else { return }
            self.isSpatialProcessing = false
            if let error {
                self.errorMessage = L10n.tr("error.playback_prepare_failed", error.localizedDescription)
                return
            }
            self.refreshPlaybackState()
            self.resumeAutomaticQualityUpgradeIfNeeded()
        }
    }

    private func reloadCurrentLocalTrackForUpsamplingModeChange() async {
        guard playbackSource == .local,
              let currentURL = hiResPlaybackEngine.currentAudioURL else { return }

        let resumeTime = hiResPlaybackEngine.currentTime()
        let shouldResume = hiResPlaybackEngine.isPlaying
        
        // メインスレッドでのUI更新（Pickerの選択変更）を完了させるために一旦譲る
        await Task.yield()
        
        // ここから処理中フラグを立てる (この時点でPickerがDisabledになる)
        isChangingUpsamplingMode = true
        isProcessing = true

        do {
            try await hiResPlaybackEngine.reloadCurrentTrack(
                url: currentURL,
                effectSettings: playbackEffectSettings,
                headphoneSpatialSettings: playbackSpatialSettings,
                upsamplingMode: safeUpsamplingMode(upsamplingMode),
                resumeTime: resumeTime,
                shouldResume: shouldResume
            )
            
            // 処理完了後のUI復旧
            isProcessing = false
            isChangingUpsamplingMode = false
            
            if hiResPlaybackEngine.isPlaying {
                clearForcedPausedWindow()
                isPlaying = true
                startTimer()
            } else {
                beginForcedPausedWindow(for: .local)
                isPlaying = false
                stopTimer()
            }
            localPlaybackFormatDescription = hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
            refreshPlaybackState()
            
        } catch is CancellationError {
            // キャンセルされた場合は何もしない（次のタスクに委ねる）
            print("[ViewModel] Upsampling reload cancelled.")
        } catch {
            isProcessing = false
            isChangingUpsamplingMode = false
            let requestedMode = safeUpsamplingMode(upsamplingMode)
            guard requestedMode != .avAudioConverter else {
                errorMessage = L10n.tr("error.playback_prepare_failed", error.localizedDescription)
                return
            }

            // Precision Sinc is an optional quality upgrade. If its offline
            // buffer cannot be allocated, keep the current track alive with
            // the streaming converter instead of surfacing a fatal-looking
            // preparation error.
            do {
                enterMemoryOptimizedMode(
                    .constrained,
                    reason: "upsampling_reload_fallback"
                )
                try await hiResPlaybackEngine.reloadCurrentTrack(
                    url: currentURL,
                    effectSettings: playbackEffectSettings,
                    headphoneSpatialSettings: playbackSpatialSettings,
                    upsamplingMode: .avAudioConverter,
                    resumeTime: resumeTime,
                    shouldResume: shouldResume
                )
                upsamplingMode = .avAudioConverter
                localPlaybackFormatDescription = hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                refreshPlaybackState()
                errorMessage = nil
            } catch is CancellationError {
                print("[ViewModel] Converter fallback cancelled.")
            } catch {
                errorMessage = L10n.tr("error.playback_prepare_failed", error.localizedDescription)
            }
        }
    }

    private func resolvePlayableAsset(for song: SystemSong) -> (url: URL?, item: MPMediaItem?) {
        if song.source != .systemMusic, let localURL = song.url {
            return (localURL, nil)
        }
        guard let item = systemMediaLibrary.mediaItem(for: song.id) else { return (nil, nil) }
        let url = item.assetURL
        let useSystem = PlaybackTransportPolicy.requiresSystemPlayer(
            protectedAsset: item.hasProtectedAsset, hasAssetURL: url != nil
        )
        PlaybackDebugLogger.event("audio.asset.route songID=\(song.id) protected=\(item.hasProtectedAsset) source=\(useSystem ? "system" : "local")")
        return (useSystem ? nil : url, item)
    }

    private func cancelSystemAssetRecovery() {
        systemAssetRecoveryTask?.cancel()
        systemAssetRecoveryTask = nil
        systemAssetRecoveryGate.reset()
        if let owner = systemHandoffEngineOwner {
            systemHandoffEngineOwner = nil
            hiResPlaybackEngine.stop(afterDrain: {
                PlaybackAudioSession.shared.cancelMixedHandoff(owner)
            })
        }
    }

    /// Music owns playback while a readable, unprotected snapshot is prepared.
    /// Never export DRM; keep Music audible through file I/O, graph preparation
    /// and the replacement's first render before transferring playback ownership.
    private func startSystemAssetRecoveryIfNeeded() {
        guard playbackSource == .system, isSystemPlayerConfigured, isApplicationActive,
              systemPlayer.playbackState == .playing, !isInterrupted,
              systemAssetRecoveryTask == nil,
              let song = currentPlaybackSong, resolvedSystemSongID == song.id,
              systemAssetRecoveryGate.begin(songID: song.id, generation: playbackPreparationToken) else { return }
        systemAssetRecoveryFailure = nil
        // The live item may expose the downloaded asset before a library query
        // catches up. It is already matched to the requested song above.
        let liveItem = systemPlayer.nowPlayingItem
        let libraryItem = systemMediaLibrary.mediaItem(for: song.id)
        guard liveItem?.hasProtectedAsset != true, libraryItem?.hasProtectedAsset != true else {
            PlaybackDebugLogger.event("audio.asset.recovery_skipped songID=\(song.id) reason=protected")
            return
        }
        guard let sourceURL = liveItem?.assetURL ?? libraryItem?.assetURL else {
            systemAssetRecoveryFailure = L10n.tr("effects.availability.source_unavailable")
            PlaybackDebugLogger.warning("audio.asset.recovery_skipped songID=\(song.id) reason=no_asset_url")
            return
        }
        PlaybackDebugLogger.event("audio.asset.recovery_begin songID=\(song.id)")
        preloadTrackTask?.cancel()
        let requestID = UUID()
        systemAssetRecoveryID = requestID
        let token = playbackPreparationToken
        let pauseToken = userPauseIntentToken
        systemAssetRecoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var completedAttempt = false
            defer {
                if self.systemHandoffEngineOwner == requestID {
                    self.systemHandoffEngineOwner = nil
                    self.hiResPlaybackEngine.stop(afterDrain: {
                        PlaybackAudioSession.shared.cancelMixedHandoff(requestID)
                    })
                }
                if self.systemAssetRecoveryID == requestID {
                    self.systemAssetRecoveryTask = nil
                    // A transient pause/obsolete observation is not a failed
                    // preparation. The next confirmed play may try again.
                    if !completedAttempt { self.systemAssetRecoveryGate.reset() }
                }
            }
            do {
                let snapshot = try await MusicAssetPreparation.playableSnapshot(url: sourceURL)
                let opened = try await StreamingAudioFilePreparation.open(url: snapshot.url)
                try Task.checkCancellation()
                guard self.playbackPreparationToken == token,
                      self.userPauseIntentToken == pauseToken,
                      self.selectedSystemSongID == song.id,
                      self.resolvedSystemSongID == song.id,
                      self.playbackSource == .system,
                      self.systemPlayer.playbackState == .playing,
                      !self.isInterrupted else { return }
                // Activate a temporary mixable session and build the graph
                // while Music continues. Do not change its rate/buffer or stop
                // its source while waiting for session IPC/Audio Unit startup.
                self.systemHandoffEngineOwner = requestID
                try await self.hiResPlaybackEngine.loadOpenedFile(url: sourceURL, opened: opened,
                    effectSettings: self.playbackEffectSettings,
                    headphoneSpatialSettings: self.playbackSpatialSettings,
                    mixedHandoff: requestID)
                try Task.checkCancellation()
                guard self.playbackPreparationToken == token,
                      self.userPauseIntentToken == pauseToken,
                      self.selectedSystemSongID == song.id, self.resolvedSystemSongID == song.id,
                      self.playbackSource == .system, self.systemPlayer.playbackState == .playing,
                      !self.isInterrupted else { return }
                // Sample the playhead AFTER graph/session preparation. The old
                // implementation replayed a stale position after a silent gap.
                let position = self.systemPlayer.currentPlaybackTime
                let duration = Double(opened.file.length) / opened.file.processingFormat.sampleRate
                guard position.isFinite, position >= 0, duration.isFinite else { return }
                guard position + 1 < duration else { completedAttempt = true; return }
                self.hiResPlaybackEngine.apply(effectSettings: self.playbackEffectSettings)
                do {
                    try self.hiResPlaybackEngine.seek(to: position)
                    try self.hiResPlaybackEngine.play(fadeInDuration: 0.012)
                    try await self.hiResPlaybackEngine.waitForSystemHandoffRender()
                } catch { throw AudioPreparationFailure.tagging(error, stage: .streamingStart) }
                try Task.checkCancellation()
                guard self.playbackPreparationToken == token,
                      self.userPauseIntentToken == pauseToken,
                      self.selectedSystemSongID == song.id, self.resolvedSystemSongID == song.id,
                      self.playbackSource == .system, self.systemPlayer.playbackState == .playing,
                      !self.isInterrupted else { return }
                completedAttempt = true
                PlaybackDebugLogger.event("audio.asset.recovery_render_ready songID=\(song.id) position=\(position)")
                // The replacement is now rendering. Transfer ownership without
                // stopping/rescheduling its node or fading the whole output down.
                self.systemHandoffEngineOwner = nil
                self.systemAssetRecoveryTask = nil
                self.stopCurrentPlaybackForTransition(pauseSystemPlayback: true)
                self.playbackSource = .local
                self.musicPlaybackSnapshot = snapshot
                self.isPlaying = true
                self.isProcessing = false
                self.isPlaybackStarting = false
                self.errorMessage = nil
                let commitToken = self.playbackPreparationToken
                self.localPlaybackFormatDescription = self.hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                self.startTimer()
                self.refreshPlaybackState()
                self.updateNowPlayingInfo(force: true)
                do { try await PlaybackAudioSession.shared.finishMixedHandoff(requestID) }
                catch { PlaybackDebugLogger.warning("audio.asset.handoff_session_restore error=\(error.localizedDescription)") }
                guard !Task.isCancelled, self.playbackPreparationToken == commitToken,
                      self.selectedSystemSongID == song.id, self.playbackSource == .local else { return }
                self.startPrecisionSincUpgrade(songID: song.id, assetURL: sourceURL,
                    targetUpsampling: self.memorySafetyMode.automaticUpsamplingMode)
                if let index = self.systemQueueIndex { self.scheduleNextTrackPreload(after: index) }
                PlaybackDebugLogger.event("audio.asset.recovered songID=\(song.id)")
            } catch is CancellationError { }
            catch {
                // Native playback keeps running if export/opening is unavailable.
                guard !Task.isCancelled, self.systemAssetRecoveryID == requestID,
                      self.playbackPreparationToken == token, self.selectedSystemSongID == song.id else { return }
                completedAttempt = true
                self.systemAssetRecoveryFailure = L10n.tr("effects.availability.preparation_failed")
                PlaybackDebugLogger.warning("audio.asset.recovery_unavailable songID=\(song.id) \(AudioPreparationFailure.diagnostic(error, fallbackStage: .assetSnapshot))")
            }
        }
    }

    private func scheduleNextTrackPreload(after currentIndex: Int) {
        guard systemAssetRecoveryTask == nil, systemQueue.indices.contains(currentIndex) else { return }
        let nextIndex = currentIndex + 1
        guard systemQueue.indices.contains(nextIndex) else { return }
        let nextSong = systemQueue[nextIndex]
        let (nextURL, _) = resolvePlayableAsset(for: nextSong)
        guard let nextURL else { return }

        preloadTrackTask?.cancel()
        let currentSongID = systemQueue[currentIndex].id

        let spatialSettings = playbackSpatialSettings
        let preloadMode = memorySafetyMode.automaticUpsamplingMode
        let currentUpgradeTask = precisionUpgradeTask
        preloadTrackTask = Task { @MainActor [weak self] in
            // Finish the current song's quality work first. Only one following
            // song is converted; no next-track PCM stays in the engine.
            if let currentUpgradeTask { await currentUpgradeTask.value }
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled,
                  self.selectedSystemSongID == currentSongID,
                  self.systemQueueIndex == currentIndex,
                  self.isPlaying, self.memorySafetyMode == .normal,
                  ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue,
                  preloadMode.isPrecisionSinc else { return }
            do {
                let file = try await RemoteAudioCache.shared.playbackFile(for: nextURL)
                defer { withExtendedLifetime(file) {} }
                try Task.checkCancellation()
                try await HiResPlaybackEngine.prepareDiskCache(url: file.url,
                    headphoneSpatialSettings: spatialSettings, upsamplingMode: preloadMode)
                PlaybackDebugLogger.event("audio.quality_cache.prepared songID=\(nextSong.id)")
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                PlaybackDebugLogger.warning("audio.quality_cache.deferred songID=\(nextSong.id) mode=\(preloadMode.rawValue) \(AudioPreparationFailure.diagnostic(error, fallbackStage: .cachePreparation))")
            }
        }
    }

    private func startPrecisionSincUpgrade(songID: UInt64, assetURL: URL, targetUpsampling: UpsamplingMode) {
        guard memorySafetyMode == .normal,
              ProcessInfo.processInfo.thermalState.rawValue < ProcessInfo.ThermalState.serious.rawValue else { return }
        precisionUpgradeTask?.cancel()
        let tokenAtStart = playbackPreparationToken
        let requestID = UUID()
        qualityUpgradeRequestID = requestID
        precisionUpgradeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.qualityUpgradeRequestID == requestID { self.precisionUpgradeTask = nil } }
            // Defer expensive background rebuild to keep first-load snappiness.
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            guard self.playbackPreparationToken == tokenAtStart else { return }
            guard self.playbackSource == .local else { return }
            guard self.selectedSystemSongID == songID else { return }
            guard self.hiResPlaybackEngine.currentAudioURL == assetURL else { return }
            guard self.hiResPlaybackEngine.isPlaying else { return }

            // Prepare only unprotected assets: passthrough where readable,
            // otherwise PCM decoding without lossy re-encoding. Retain the
            // snapshot until conversion/handoff has completed.
            let snapshot: MusicAssetPreparation.Snapshot?
            do {
                if let retained = self.musicPlaybackSnapshot { snapshot = retained }
                else { snapshot = assetURL.isFileURL ? nil : try await MusicAssetPreparation.playableSnapshot(url: assetURL) }
            } catch {
                guard !Task.isCancelled else { return }
                PlaybackDebugLogger.warning("audio.quality_snapshot.skipped songID=\(songID) mode=\(targetUpsampling.rawValue) \(AudioPreparationFailure.diagnostic(error, fallbackStage: .assetSnapshot))")
                return
            }
            let preparationURL = snapshot?.url ?? assetURL
            guard !Task.isCancelled, self.playbackPreparationToken == tokenAtStart,
                  self.selectedSystemSongID == songID, self.memorySafetyMode == .normal else { return }
            do {
                try HiResPlaybackEngine.validateOfflinePreparation(url: preparationURL, upsamplingMode: targetUpsampling)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                PlaybackDebugLogger.warning(
                    "audio.quality_upgrade.deferred songID=\(songID) mode=\(targetUpsampling.rawValue) \(AudioPreparationFailure.diagnostic(error, fallbackStage: .offlinePreflight))")
                return
            }
            defer { withExtendedLifetime(snapshot) {} }

            PlaybackDebugLogger.event(
                "audio.quality_upgrade.begin songID=\(songID) mode=\(targetUpsampling.rawValue) \(HiResPlaybackEngine.processMemoryDiagnostic)"
            )
            let shouldResume = self.hiResPlaybackEngine.isPlaying
            do {
                try await self.hiResPlaybackEngine.seamlessUpgrade(
                    url: assetURL,
                    preparationURL: preparationURL,
                    latestEffectSettings: { [weak self] in self?.playbackEffectSettings ?? [] },
                    effectSettings: self.playbackEffectSettings,
                    headphoneSpatialSettings: self.playbackSpatialSettings,
                    upsamplingMode: self.safeUpsamplingMode(targetUpsampling),
                    shouldResume: shouldResume
                )
                guard self.playbackPreparationToken == tokenAtStart,
                      self.selectedSystemSongID == songID,
                      self.hiResPlaybackEngine.currentAudioURL == assetURL else { return }
                self.localPlaybackFormatDescription = self.hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                self.refreshPlaybackState()
            } catch is CancellationError {
                return
            } catch {
                // Keep playback on the fast path if upgrade fails.
                guard !Task.isCancelled, self.playbackPreparationToken == tokenAtStart,
                      self.selectedSystemSongID == songID else { return }
                PlaybackDebugLogger.warning(
                    "audio.quality_upgrade.failed songID=\(songID) mode=\(targetUpsampling.rawValue) \(AudioPreparationFailure.diagnostic(error, fallbackStage: .qualityHandoff))")
            }
        }
    }

    /// A memory recovery can complete while the current track is paused. In
    /// that case the desired mode is already normal, so the periodic recovery
    /// monitor has nothing left to transition. Resume the deferred quality
    /// upgrade when audible playback starts again.
    private func resumeAutomaticQualityUpgradeIfNeeded() {
        guard isBackgroundQualityUpgradeEnabled, precisionUpgradeTask == nil,
              memorySafetyMode == .normal,
              playbackSource == .local,
              hiResPlaybackEngine.hasTrack,
              hiResPlaybackEngine.isPlaying,
              hiResPlaybackEngine.activeUpsamplingMode != memorySafetyMode.automaticUpsamplingMode,
              let songID = selectedSystemSongID,
              let currentURL = hiResPlaybackEngine.currentAudioURL else {
            return
        }

        startPrecisionSincUpgrade(
            songID: songID,
            assetURL: currentURL,
            targetUpsampling: memorySafetyMode.automaticUpsamplingMode
        )
    }

    private func waitUntilLocalPlaybackStarts() async -> Bool {
        // Keep the loading state until local playback is actually running,
        // but never block the UI for too long.
        let maxPolls = 80
        for _ in 0..<maxPolls {
            guard playbackSource == .local else { return false }
            if hiResPlaybackEngine.isPlaying {
                let t = hiResPlaybackEngine.currentTime()
                // Do not use the output meter here: it can still contain the
                // previous track's value and end the loading state too early.
                if t > 0.02 {
                    return true
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return hiResPlaybackEngine.isPlaying
    }

    private func monitorPlaybackStart(for source: PlaybackSource) {
        playbackStartMonitorTask?.cancel()
        let preparationToken = playbackPreparationToken
        let pauseToken = userPauseIntentToken
        let songID = selectedSystemSongID
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        playbackStartMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep the loading state alive until playback is actually
            // confirmed. Large offline conversions and protected media can
            // take longer than the old fixed timeout; ending this monitor
            // early made the spinner stop while audio was still preparing.
            while !Task.isCancelled {
                guard PlaybackTransportPolicy.requestIsCurrent(
                    pauseToken: pauseToken, currentPauseToken: self.userPauseIntentToken,
                    preparationToken: preparationToken, currentPreparationToken: self.playbackPreparationToken,
                    interrupted: self.isInterrupted, cancelled: Task.isCancelled
                ), self.playbackSource == source, self.selectedSystemSongID == songID else { return }
                let didStart: Bool
                switch source {
                case .local:
                    didStart = self.playbackSource == .local
                        && self.hiResPlaybackEngine.isPlaying
                        && self.hiResPlaybackEngine.currentTime() > 0.02
                case .system:
                    didStart = PlaybackTransportPolicy.systemStartConfirmed(
                        expectedSongID: songID,
                        observedSongID: self.resolvedSystemSongID,
                        playing: self.systemPlayer.playbackState == .playing,
                        interrupted: self.isInterrupted, explicitlyPaused: self.isInForcedPausedWindow
                    )
                }

                if didStart {
                    self.isPlaybackStarting = false
                    self.isProcessing = false
                    self.errorMessage = nil
                    self.playbackStartMonitorTask = nil
                    self.refreshPlaybackState()
                    return
                }
                if source == .system, ContinuousClock.now >= deadline {
                    self.logProtectedPlaybackDiagnostics("resume_timeout")
                    self.isPlaybackStarting = false
                    self.isProcessing = false
                    self.errorMessage = L10n.tr("error.system_playback_timeout")
                    self.playbackStartMonitorTask = nil
                    return
                }
                if self.errorMessage != nil, self.localPlaybackLoadTask == nil,
                   self.systemTransportStartTask == nil {
                    self.isPlaybackStarting = false
                    self.isProcessing = false
                    self.playbackStartMonitorTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func queueAwareSubtitle(artist: String, album: String, queueTitle: String?) -> String {
        // ユーザーの要望により、アーティスト名とアルバム名のみを表示するように変更。
        // （以前はプレイリスト名などの queueTitle を付与していましたが、重複や冗長さを避けるためシンプルにします）
        return L10n.joinedMetadata([artist, album])
    }

    private func shouldIgnoreDuplicateTrackEndEvent() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastTrackEndHandledAt < 0.35 {
            return true
        }
        lastTrackEndHandledAt = now
        return false
    }

    private func albumQueue(for song: SystemSong) -> [SystemSong]? {
        let songs = songs(for: matchingAlbum(from: song))
        return songs.isEmpty ? nil : songs
    }

    private func matchingAlbum(from song: SystemSong) -> SystemAlbum {
        SystemLibraryIndex.album(for: song, in: systemAlbums)
    }

    private func makeShuffledQueue(from songs: [SystemSong], currentSong: SystemSong) -> [SystemSong] {
        guard !songs.isEmpty else { return [] }

        let remaining = songs.filter { $0.id != currentSong.id }.shuffled()
        return [currentSong] + remaining
    }

    private func ensureSystemPlayerConfigured() {
        guard !isSystemPlayerConfigured else { return }

        systemPlayer.repeatMode = .none
        systemPlayer.shuffleMode = .off
        systemPlayer.beginGeneratingPlaybackNotifications()
        NotificationCenter.default.publisher(for: .MPMusicPlayerControllerNowPlayingItemDidChange, object: systemPlayer)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleSystemNowPlayingChanged() }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .MPMusicPlayerControllerPlaybackStateDidChange, object: systemPlayer)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.handleSystemPlaybackChanged() }
            .store(in: &cancellables)
        isSystemPlayerConfigured = true
    }

    nonisolated private static func searchScore(for query: String, itemFields: [String]) -> Int? {
        let normalizedQuery = normalizeSearchText(query)
        guard !normalizedQuery.isEmpty else { return nil }

        let tokens = normalizedQuery
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }

        let combinedField = itemFields.joined(separator: " ")

        var bestScore: Int?
        for field in itemFields {
            guard !field.isEmpty else { continue }

            var score = 0
            if field == normalizedQuery {
                score += 180
            }
            if field.hasPrefix(normalizedQuery) {
                score += 130
            } else if field.contains(normalizedQuery) {
                score += 72
            }

            for token in tokens {
                if field.hasPrefix(token) {
                    score += 32
                } else if field.contains(token) {
                    score += 18
                }
            }

            if let firstToken = tokens.first, field.split(separator: " ").contains(where: { $0.hasPrefix(firstToken) }) {
                score += 18
            }

            if score > 0 {
                bestScore = max(bestScore ?? 0, score)
            }
        }

        if !tokens.isEmpty, tokens.allSatisfy({ combinedField.contains($0) }) {
            bestScore = max(bestScore ?? 0, 90 + (tokens.count * 14))
        }

        if itemFields.count > 1 {
            let compactCombined = combinedField.replacingOccurrences(of: " ", with: "")
            let compactQuery = normalizedQuery.replacingOccurrences(of: " ", with: "")
            if compactCombined.contains(compactQuery) {
                bestScore = max(bestScore ?? 0, 88)
            }
        }

        return bestScore
    }

    nonisolated private static func normalizeSearchText(_ text: String) -> String {
        let halfWidthText = text.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? text
        return halfWidthText
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .replacingOccurrences(of: "・", with: " ")
            .replacingOccurrences(of: "•", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .components(separatedBy: .punctuationCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated private static func normalizedSystemSongs(_ songs: [SystemSong]) throws -> [SystemSong] {
        try songs.map { song in
            try Task.checkCancellation()
            var normalizedSong = song
            normalizedSong.normalizedSearchTerms = [
                normalizeSearchText(song.title),
                normalizeSearchText(song.artist),
                normalizeSearchText(song.album),
                normalizeSearchText("\(song.artist) \(song.title)"),
                normalizeSearchText("\(song.album) \(song.title)")
            ]
            return normalizedSong
        }
    }

    nonisolated private static func buildFastSystemLibrarySnapshot(using library: SystemMediaLibrary) throws -> SystemLibrarySnapshot {
        try Task.checkCancellation()
        let songs = try normalizedSystemSongs(library.fetchSongs())
        try Task.checkCancellation()
        let snapshot = SystemLibrarySnapshot(songs: songs)
        try Task.checkCancellation()
        return snapshot
    }

    nonisolated private static func mergedSystemLibrarySnapshot(
        base: SystemLibrarySnapshot,
        with localTracks: [LocalTrackMetadata]
    ) -> SystemLibrarySnapshot {
        var songs = base.songs

        for track in localTracks {
            let localID = UInt64(bitPattern: Int64(track.url.path.hashValue)) | 0x8000000000000000

            let newSong = SystemSong(
                id: localID,
                title: track.title,
                artist: track.artist,
                album: track.album,
                artistID: nil,
                albumID: nil,
                discNumber: track.discNumber,
                trackNumber: track.trackNumber,
                duration: track.duration,
                url: track.url,
                normalizedSearchTerms: [
                    normalizeSearchText(track.title),
                    normalizeSearchText(track.artist),
                    normalizeSearchText(track.album)
                ],
                albumArtist: track.albumArtist
            )

            if !songs.contains(where: { $0.id == localID }) {
                songs.append(newSong)
            }
        }

        return SystemLibrarySnapshot(songs: songs)
    }

    private func applySystemLibrarySnapshot(
        _ snapshot: SystemLibrarySnapshot,
        restorePlayback: Bool,
        isFinal: Bool
    ) {
        let effectiveSnapshot = snapshotIncludingLocalLibrary(snapshot)

        // Library publishing is intentionally independent from the audio
        // pipeline. Avoid a large array publish during an active transition or
        // render; apply the latest snapshot on the next idle tick instead.
        if isPlaybackBusyForLibraryWork
            && !(systemSongs.isEmpty && isApplicationActive && !isProcessing && !isPlaybackStarting) {
            deferredLibrarySnapshot = effectiveSnapshot
            if isFinal {
                isLibraryBootstrapInProgress = false
            }
            return
        }

        applyLibrarySnapshotToPublishedState(effectiveSnapshot)
        if isFinal {
            isLibraryBootstrapInProgress = false
        }

        if restorePlayback {
            restorePlaybackIfNeeded()
        }
    }

    private func applyLibrarySnapshotToPublishedState(_ snapshot: SystemLibrarySnapshot) {
        deferredLibrarySnapshot = nil
        librarySnapshotRevision &+= 1
        systemSongs = snapshot.songs
        systemArtists = snapshot.artists
        systemAlbums = snapshot.albums
        refreshNowPlayingAlbum()
        performSearch(refreshCatalog: false)
    }

    private func flushDeferredLibrarySnapshotIfPlaybackIsIdle(allowWhilePlaying: Bool = false) {
        guard !isProcessing, !isPlaybackStarting,
              (!isPlaybackBusyForLibraryWork || (allowWhilePlaying && isApplicationActive)),
              let snapshot = deferredLibrarySnapshot else { return }
        deferredLibrarySnapshot = nil
        applyLibrarySnapshotToPublishedState(snapshotIncludingLocalLibrary(snapshot))
    }

    private func snapshotIncludingLocalLibrary(
        _ snapshot: SystemLibrarySnapshot
    ) -> SystemLibrarySnapshot {
        if localLibraryTracks.isEmpty, snapshot.songs.allSatisfy({ $0.url == nil }) {
            return snapshot
        }
        let systemOnly = SystemLibrarySnapshot(
            songs: snapshot.songs.filter { $0.url == nil }
        )
        return Self.mergedSystemLibrarySnapshot(base: systemOnly, with: localLibraryTracks)
    }

    /// Stops nonessential library I/O as soon as audible playback begins.
    /// Incrementing the generation also prevents a detached query that was
    /// already running from publishing its stale result after cancellation.
    private func cancelLibraryWorkForPlayback(force: Bool = false) {
        guard force
                || isPlaying
                || (hasInitializedHiResPlaybackEngine && hiResPlaybackEngine.isPlaying)
                || (isSystemPlayerConfigured && systemPlayer.playbackState == .playing) else {
            return
        }

        if systemLibraryFeedback == .working {
            systemLibraryFeedback = .notice(L10n.tr("settings.library_feedback.interrupted"))
        }
        if localLibraryFeedback == .working {
            localLibraryFeedback = .notice(L10n.tr("settings.library_feedback.interrupted"))
        }
        if systemLibraryRefreshTask != nil {
            systemLibraryRefreshGeneration &+= 1
            systemLibraryRefreshTask?.cancel()
            systemLibraryRefreshTask = nil
        }
        if localLibraryScanTask != nil {
            localLibraryScanGeneration &+= 1
            localLibraryScanTask?.cancel()
            localLibraryScanTask = nil
        }
        librarySnapshotPersistenceTask?.cancel()
        librarySnapshotPersistenceTask = nil

        isLibraryBootstrapInProgress = false
        isInitialLibraryLoading = false
        isScanningLocalLibrary = false
        libraryLoadingMessage = nil
    }
}

private extension PlaybackSnapshot {
    func queueSongs(from songs: [SystemSong]) -> [SystemSong] {
        let songMap = Dictionary(uniqueKeysWithValues: songs.map { ($0.id, $0) })
        return queueSongIDs.compactMap { songMap[$0] }
    }
}
