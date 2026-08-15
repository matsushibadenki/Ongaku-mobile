//
//  AudioPlayerViewModel.swift
//  audio
//
//  2026/04/02.
//

import AVFoundation
import Combine
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

@MainActor
final class AudioPlayerViewModel: NSObject, ObservableObject {
    private struct SystemLibrarySnapshot {
        let songs: [SystemSong]
        let artists: [SystemArtist]
        let albums: [SystemAlbum]
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
    @Published var searchText = ""
    @Published var effectSettings = AudioEffectModuleRegistry.makeDefaultSettings()
    @Published private(set) var selectedEffectPageTab: AudioEffectPageTab = .basic
    @Published var headphoneSpatialSettings = HeadphoneSpatialSettings.default
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
    @Published private(set) var isRequestingSystemLibraryAccess = false
    @Published private(set) var isRequestingAppleMusicAccess = false

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
    private var appleMusicSearchTask: Task<Void, Never>?
    private var playbackSource: PlaybackSource = .local
    private var systemQueue: [SystemSong] = []
    private var systemQueueIndex: Int?
    private var systemQueueTitle: String?
    private var pendingPlaybackSnapshot: PlaybackSnapshot?
    private var pendingEffectSettings: [StoredEffectSetting] = []
    private var isSystemPlayerConfigured = false
    private var isSystemPlayerStarting = false
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
        engine.setSystemOutputVolume(AVAudioSession.sharedInstance().outputVolume)
        engine.refreshLoudnessCompensationRoute()
        engine.setAutomaticDSPStrength(Float(automaticDSPStrength), effectSettings: playbackEffectSettings)
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

    /// MediaPlayer assets are served by a system daemon. Decoding the same
    /// ipod-library URL concurrently for realtime playback and an offline
    /// full-track upgrade can starve or invalidate the audible stream.
    private func automaticUpsamplingMode(
        for assetURL: URL,
        preferred: UpsamplingMode
    ) -> UpsamplingMode {
        guard assetURL.isFileURL else { return .avAudioConverter }
        return safeUpsamplingMode(preferred)
    }

    private var forcedPausedSource: PlaybackSource?
    private var lastNowPlayingTrackKey: String?
    private var lastNowPlayingState: MPNowPlayingPlaybackState = .unknown
    private var lastNowPlayingElapsed: TimeInterval = 0
    private var effectAuditRefreshTimer: Timer?
    private var isEffectAuditRefreshPrimed = false
    private var isEffectScreenActive = false
    private var hasAppliedInitialEffectScreenNoiseMask = false
    private var hasPrewarmedEffectsInterface = false
    private var headphoneSpatialApplyTimer: Timer?
    private var effectApplyTimer: Timer?
    private var reinforceTaskID = 0
    private var upsamplingReloadTask: Task<Void, Never>?
    private var localPlaybackLoadTask: Task<Void, Never>?
    private var cacheMaintenanceTask: Task<Void, Never>?
    private var precisionUpgradeTask: Task<Void, Never>?
    private var precisionUpgradeSkippedSongID: UInt64?
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
    // Full-track 96 kHz PCM preloading duplicates hundreds of MB while the
    // current song is still resident. Keep the implementation available, but
    // disable it until it can be backed by a bounded streaming cache.
    private let isNextTrackMemoryPreloadEnabled = false
    private var lastPublishedSpectrum: [Float] = []
    private var syntheticVisualizationPhase: Double = 0
    private let vuBallistics = BallisticSimulator()
    private var vuTransitionTask: Task<Void, Never>?
    private var outputVolumeObservation: NSKeyValueObservation?
    private var hasStartedInitialBootstrap = false
    private var initialBootstrapTask: Task<Void, Never>?
    private var systemLibraryRefreshTask: Task<Void, Never>?
    private var localLibraryScanTask: Task<Void, Never>?
    private var librarySnapshotPersistenceTask: Task<Void, Never>?
    private var systemLibraryRefreshGeneration: UInt64 = 0
    private var deferredLibrarySnapshot: SystemLibrarySnapshot?

    private var isPlaybackBusyForLibraryWork: Bool {
        if isPlaying || isProcessing || isPlaybackStarting { return true }
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
        isProcessing || isPlaybackStarting || isChangingUpsamplingMode || isEffectProcessing || isSpatialProcessing
            || (isInitialLibraryLoading && !hasTrack)
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

    var accentColor: Color {
        upsamplingMode.isPrecisionSinc ? Theme.precisionSincAccent : Theme.accent
    }

    var canChangeUpsamplingMode: Bool {
        !isChangingUpsamplingMode
    }

    var realtimeEffectsStatusText: String {
        if supportsRealtimeEffects {
            return L10n.tr("effects.status.active")
        }
        return L10n.tr("effects.status.inactive")
    }

    var realtimeEffectsAvailabilityDetail: String {
        if supportsRealtimeEffects {
            return L10n.tr("effects.availability.active")
        }

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

    private var isCurrentTrackProtectedSystemPlayback: Bool {
        guard playbackSource == .system,
              let currentPlaybackSong,
              currentPlaybackSong.url == nil else {
            return false
        }
        return systemMediaLibrary.mediaItem(for: currentPlaybackSong.id)?.assetURL == nil
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
        if playbackSource == .local && hiResPlaybackEngine.hasTrack {
            count += 1
        }
        return count
    }

    /// 再生信号経路のサマリーテキスト
    /// 例: "192kHz / 24bit ・ DSP: 3"
    var playbackSignalSummary: String? {
        guard playbackSource == .local && hiResPlaybackEngine.hasTrack else { return nil }
        
        // フォーマット情報 (例: "192kHz / 24bit")
        let format = hiResPlaybackEngine.currentFormat?.description ?? ""
        let dspCount = totalDSPCount
        
        if format.isEmpty && dspCount == 0 { return nil }
        
        let dspLabel = String(format: L10n.tr("effects.badge.multiple"), dspCount)
        if format.isEmpty { return dspLabel }
        
        return "\(format) \(L10n.tr("separator.dot")) \(dspLabel)"
    }

    private var currentPlaybackSong: SystemSong? {
        if let selectedSystemSongID,
           let selectedSong = systemSongs.first(where: { $0.id == selectedSystemSongID }) {
            return selectedSong
        }
        if let systemQueueIndex, systemQueue.indices.contains(systemQueueIndex) {
            return systemQueue[systemQueueIndex]
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

    private func performSearch() {
        searchTask?.cancel()
        appleMusicSearchTask?.cancel()
        
        let query = searchText
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
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
        let tracks = systemSongs
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
                self.filteredSystemArtists = artists
                self.filteredSystemAlbums = albums
                self.filteredSystemSongs = songs
                self.filteredSystemPlaylists = playlists
            }
        }

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
        mediaLibraryAccess = systemMediaLibrary.currentAccessState()
        cloudServiceAccessStatus = systemMediaLibrary.currentCloudServiceAuthorizationStatus()
        appleMusicAccessStatus = systemMediaLibrary.currentCloudServiceAuthorizationStatus()
        configureAudioSessionObservers()
        configureRemoteCommands()
        setupSearchDebounce()
        setupAppLifecycleObservers()
        configureOutputVolumeObservation()
    }

    deinit {
        initialBootstrapTask?.cancel()
        systemLibraryRefreshTask?.cancel()
        localLibraryScanTask?.cancel()
        librarySnapshotPersistenceTask?.cancel()
        searchTask?.cancel()
        appleMusicSearchTask?.cancel()
        upsamplingReloadTask?.cancel()
        localPlaybackLoadTask?.cancel()
        cacheMaintenanceTask?.cancel()
        precisionUpgradeTask?.cancel()
        preloadTrackTask?.cancel()
        vuTransitionTask?.cancel()
        updateTimer?.invalidate()
        visualizationTimer?.invalidate()
        effectAuditRefreshTimer?.invalidate()
        effectApplyTimer?.invalidate()
        headphoneSpatialApplyTimer?.invalidate()
        outputVolumeObservation?.invalidate()
        interruptionResumeTask?.cancel()
        sessionActivationRetryTask?.cancel()
        playbackStartMonitorTask?.cancel()
        unexpectedPlaybackRecoveryTask?.cancel()
        print("[Playback] vm.lifecycle.deinit instance=\(ObjectIdentifier(self))")
        for registration in remoteCommandRegistrations {
            registration.command.removeTarget(registration.target)
        }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesWereReset(_:)),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: session
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioRouteChange(_:)),
            name: AVAudioSession.routeChangeNotification,
            object: session
        )
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

    @objc private func handleAudioRouteChange(_ notification: Notification) {
        guard hasInitializedHiResPlaybackEngine else { return }
        hiResPlaybackEngine.refreshLoudnessCompensationRoute()
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
        // アプリが前面に戻った際は、システム（ウィジェット）との乖離を防ぐため強制的に同期します。
        refreshPlaybackState()
        if hasInitializedHiResPlaybackEngine {
            hiResPlaybackEngine.setRealtimeAnalysisEnabled(true)
        }
        if isPlaying {
            startVisualizationTimer()
        }
        updateNowPlayingInfo(force: true)
        resumeAutomaticQualityUpgradeIfNeeded()
    }

    @objc private func handleAppWillResignActive() {
        guard isApplicationActive else { return }
        isApplicationActive = false
        stopVisualizationTimer()
        stopEffectAuditRefreshTimer()
        if hasInitializedHiResPlaybackEngine {
            hiResPlaybackEngine.setRealtimeAnalysisEnabled(false)
        }
        cancelOptionalQualityWork(reason: "application_inactive")
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

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            PlaybackDebugLogger.event(
                "app.background.enter playback=local enginePlaying=\(hiResPlaybackEngine.isPlaying) sessionActive=true \(HiResPlaybackEngine.processMemoryDiagnostic)"
            )
        } catch {
            PlaybackDebugLogger.failure(
                "app.background.session_failed error=\(error.localizedDescription)"
            )
        }
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
        deferredLibrarySnapshot = nil

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
           let currentURL = hiResPlaybackEngine.currentAudioURL,
           !HiResPlaybackEngine.canPrepareOffline(
               url: currentURL,
               upsamplingMode: recoveryMode.automaticUpsamplingMode
           ) {
            // General headroom has recovered, but this particular track still
            // cannot fit with the required reserve. Re-evaluate later without
            // interrupting its AVAudioConverter playback.
            memoryRecoveryNotBefore = CFAbsoluteTimeGetCurrent() + 30
            PlaybackDebugLogger.event(
                "memory.safety.recovery_deferred reason=track_allocation_budget"
            )
            return
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
        applyRealtimeEffects(skipAutoPeakAdjustment: true)

        isSpatialProcessing = true
        applyHeadphoneSpatialSettingsIfNeeded(immediately: true)
    }

    func setEffectParameter(_ value: Double, key: String, for kind: RealtimeAudioEffectKind) {
        guard let index = effectSettings.firstIndex(where: { $0.kind == kind }) else { return }
        
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
        let clamped = min(max(value, 0.0), 1.5)
        guard abs(clamped - automaticDSPStrength) >= 0.001 else { return }
        automaticDSPStrength = clamped
        hiResPlaybackEngine.setAutomaticDSPStrength(Float(clamped), effectSettings: playbackEffectSettings)
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
            isABReferenceMode ? 0 : Float(automaticDSPStrength),
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
            let statistics = await HiResPlaybackEngine.preparedAudioCacheStatistics()
            guard let self, !Task.isCancelled else { return }
            self.preparedAudioCacheStatistics = statistics
            self.cacheMaintenanceTask = nil
        }
    }

    func clearPreparedAudioCache() {
        guard !isClearingPreparedAudioCache else { return }
        cacheMaintenanceTask?.cancel()
        isClearingPreparedAudioCache = true
        if hasInitializedHiResPlaybackEngine {
            hiResPlaybackEngine.releasePreloadedResources()
        }
        cacheMaintenanceTask = Task { @MainActor [weak self] in
            await HiResPlaybackEngine.clearPreparedAudioDiskCache()
            guard let self, !Task.isCancelled else { return }
            self.preparedAudioCacheStatistics = await HiResPlaybackEngine.preparedAudioCacheStatistics()
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
            }
        }
    }

    func reloadSystemLibrary() {
        guard mediaLibraryAccess == .authorized else {
            requestSystemLibraryAccess()
            return
        }
        refreshSystemLibrary()
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

    func refreshSystemLibrary(showLoadingState: Bool = true) {
        let isLocalPlaybackActive = playbackSource == .local && isPlaying && hasInitializedHiResPlaybackEngine
        let isSystemPlaybackActive = playbackSource == .system && isSystemPlayerConfigured && systemPlayer.playbackState == .playing

        // MPMediaQuery and metadata expansion can consume enough CPU/memory to
        // starve the realtime renderer. Library refresh is never urgent enough
        // to compete with playback or its startup transition.
        if isPlaybackBusyForLibraryWork || isLocalPlaybackActive || hasResidentLocalPlaybackTrack || isSystemPlaybackActive {
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
                return
            }

            guard let self else { return }
            guard !Task.isCancelled else { return }
            guard generation == self.systemLibraryRefreshGeneration else { return }

            self.applySystemLibrarySnapshot(fastSnapshot, restorePlayback: shouldRestorePlayback, isFinal: true)
            self.persistCachedSystemLibrarySnapshot(fastSnapshot)

            // Initial restoration can create a resident audio track while the
            // refresh task is still between phases. Do not start a second set
            // of MPMediaQuery expansions after that boundary.
            guard !self.isPlaybackBusyForLibraryWork,
                  !self.hasResidentLocalPlaybackTrack else { return }

            let detailedWorker = Task.detached(priority: .background) {
                try Self.buildDetailedSystemLibrarySnapshot(using: library, songs: fastSnapshot.songs)
            }
            let detailedSnapshot: SystemLibrarySnapshot
            do {
                detailedSnapshot = try await withTaskCancellationHandler {
                    try await detailedWorker.value
                } onCancel: {
                    detailedWorker.cancel()
                }
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard generation == self.systemLibraryRefreshGeneration else { return }

            self.applySystemLibrarySnapshot(detailedSnapshot, restorePlayback: false, isFinal: false)
            self.persistCachedSystemLibrarySnapshot(detailedSnapshot)
            self.systemLibraryRefreshTask = nil
        }
    }

    func scanLocalLibrary() {
        guard !isPlaybackBusyForLibraryWork,
              !isScanningLocalLibrary,
              systemLibraryRefreshTask == nil else { return }

        isScanningLocalLibrary = true
        libraryLoadingMessage = L10n.tr("settings.local_library_scanning")
        localLibraryScanTask?.cancel()
        localLibraryScanTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isScanningLocalLibrary = false
                self.localLibraryScanTask = nil
                self.libraryLoadingMessage = nil
            }

            let localWorker = Task.detached(priority: .background) {
                await LocalMediaManager.shared.scanLocalFiles()
            }
            let localTracks = await withTaskCancellationHandler {
                await localWorker.value
            } onCancel: {
                localWorker.cancel()
            }
            guard !Task.isCancelled else { return }

            let baseSnapshot = SystemLibrarySnapshot(
                songs: self.systemSongs.filter { $0.url == nil },
                artists: self.systemArtists.filter { !$0.isLocalLibraryIdentifier },
                albums: self.systemAlbums.filter { !$0.isLocalLibraryIdentifier }
            )
            let mergedSnapshot = Self.mergedSystemLibrarySnapshot(base: baseSnapshot, with: localTracks)
            self.applySystemLibrarySnapshot(mergedSnapshot, restorePlayback: false, isFinal: false)
            self.persistCachedSystemLibrarySnapshot(mergedSnapshot)
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
        queueCount=\(queueItems.count) \
        queueIDs=[\(queueIDs)]
        """)
    }

    func setEffectScreenActive(_ isActive: Bool) {
        isEffectScreenActive = isActive
        if isActive {
            // 初回の不必要なマスクを抑制し、ノイズ対策をより洗練させる
            if !hasAppliedInitialEffectScreenNoiseMask, playbackSource == .local, hiResPlaybackEngine.isPlaying {
                // hasPrewarmedEffectsInterface が true の場合は既に裏で準備ができているため、アグレッシブなマスクは不要
                hasAppliedInitialEffectScreenNoiseMask = true
                hiResPlaybackEngine.maskTransitionNoiseIfNeeded(aggressive: false) 
            }
            scheduleEffectAuditRefresh(after: 0.8)
        } else {
            stopEffectAuditRefreshTimer()
        }
    }

    func markEffectsInterfacePrewarmed() {
        hasPrewarmedEffectsInterface = true
    }

    func songs(for artist: SystemArtist) -> [SystemSong] {
        systemSongs.filter { song in
            if let artistID = song.artistID {
                return artistID == artist.id
            }
            return song.artist == artist.name
        }
    }

    func findArtist(for album: SystemAlbum) -> SystemArtist? {
        // アルバムに紐づく曲を1つ探し、そのアーティストIDまたは名前からアーティストを特定します
        let albumSongs = songs(for: album)
        if let firstSong = albumSongs.first {
            if let artistID = firstSong.artistID {
                return systemArtists.first(where: { $0.id == artistID })
            }
        }
        return systemArtists.first(where: { $0.name == album.artist })
    }

    func albums(for artist: SystemArtist) -> [SystemAlbum] {
        let artistSongs = songs(for: artist)
        let albumIDs = Set(artistSongs.compactMap(\.albumID))

        return systemAlbums.filter { album in
            if !albumIDs.isEmpty {
                return albumIDs.contains(album.id)
            }
            return album.artist == artist.name
        }
    }

    func songs(for album: SystemAlbum) -> [SystemSong] {
        let albumSongs = systemSongs.filter { song in
            if let albumID = song.albumID {
                return albumID == album.id
            }
            return song.album == album.title && song.artist == album.artist
        }

        let hasTrackMetadata = albumSongs.contains { song in
            (song.discNumber ?? 0) > 0 || (song.trackNumber ?? 0) > 0
        }

        guard hasTrackMetadata else { return albumSongs }

        return albumSongs.sorted { lhs, rhs in
            let lhsDisc = lhs.discNumber ?? 1
            let rhsDisc = rhs.discNumber ?? 1
            if lhsDisc != rhsDisc { return lhsDisc < rhsDisc }

            let lhsTrack = lhs.trackNumber ?? Int.max
            let rhsTrack = rhs.trackNumber ?? Int.max
            if lhsTrack != rhsTrack { return lhsTrack < rhsTrack }

            let titleOrder = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }

            return lhs.id < rhs.id
        }
    }

    func songs(in playlist: SystemPlaylist) -> [SystemSong] {
        systemMediaLibrary.songs(in: playlist)
    }

    func albumArtwork(for album: SystemAlbum, size: CGSize = CGSize(width: 280, height: 280)) -> UIImage? {
        systemMediaLibrary.artwork(for: album, size: size)
    }

    func songArtwork(for song: SystemSong, size: CGSize = CGSize(width: 80, height: 80)) -> UIImage? {
        systemMediaLibrary.artwork(for: song.id, size: size)
    }

    func artistArtwork(for artist: SystemArtist, size: CGSize = CGSize(width: 120, height: 120)) -> UIImage? {
        systemMediaLibrary.artworkForArtist(id: artist.id, name: artist.name, size: size)
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
        nowPlayingAlbum = systemAlbums.first(where: { $0.title == song.album && $0.artist == song.artist })

        let shouldOptimisticallyShowPlaying = !isPlaying
        if shouldOptimisticallyShowPlaying {
            isPlaying = true
        }
        playbackPreparationToken &+= 1
        let prepareToken = playbackPreparationToken
        precisionUpgradeTask?.cancel()
        preloadTrackTask?.cancel()
        localPlaybackFormatDescription = L10n.tr("playback.preparing")

        Task {
            // UIが現在の「isProcessing = true」を描画する猶予を作る
            try? await Task.sleep(nanoseconds: 30_000_000)
            guard prepareToken == playbackPreparationToken,
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
                    nowPlayingAlbum = systemAlbums.first(where: { $0.title == song.album && $0.artist == song.artist })
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

            guard currentItem != nil else {
                isProcessing = false
                isPlaybackStarting = false
                isPlaying = false
                errorMessage = L10n.tr("error.song_not_found")
                return
            }
            let cloudServiceAuthorized = await ensureCloudServiceAuthorizationForProtectedPlayback(promptIfNeeded: true)
            guard prepareToken == playbackPreparationToken,
                  selectedSystemSongID == song.id else { return }
            logProtectedPlaybackDiagnostics("authorization_checked")
            guard cloudServiceAuthorized else {
                isProcessing = false
                isPlaybackStarting = false
                if shouldOptimisticallyShowPlaying {
                    isPlaying = false
                }
                errorMessage = L10n.tr("error.apple_music_access_required")
                return
            }

            stopLocalPlayback(clearTrackSelection: false)
            playbackSource = .system
            ensureSystemPlayerConfigured()
            systemPlayer.repeatMode = .none
            systemPlayer.shuffleMode = .off

            let items = songs.compactMap { systemMediaLibrary.mediaItem(for: $0.id) }
            guard !items.isEmpty, items.indices.contains(index) else {
                isProcessing = false
                isPlaybackStarting = false
                if shouldOptimisticallyShowPlaying {
                    isPlaying = false
                }
                errorMessage = L10n.tr("error.queue_not_found")
                return
            }

            let targetItems = Array(items[index...])
            startProtectedSystemPlayback(with: targetItems)
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

    func togglePlayback() {
        switch playbackSource {
        case .local:
            // The UI still represents the preserved play intent while an
            // unexpected-stop recovery is running. A tap during that window
            // therefore means pause, not another restart request.
            if unexpectedPlaybackRecoveryTask != nil {
                recordUserPauseIntent()
                unexpectedPlaybackRecoveryTask?.cancel()
                unexpectedPlaybackRecoveryTask = nil
                isPlaybackStarting = false
                isProcessing = false
                isPlaying = false
                stopTimer()
                beginForcedPausedWindow(for: .local)
                reinforceNowPlayingTransportState()
                persistLibraryState()
                return
            }
            guard hiResPlaybackEngine.hasTrack else {
                _ = resumePlaybackFromAnyKnownContext()
                return
            }
            if hiResPlaybackEngine.isPlaying {
                recordUserPauseIntent()
                hiResPlaybackEngine.pause()
                isPlaying = false
                stopTimer()
                beginForcedPausedWindow(for: .local)
                forcedWriteNowPlayingPaused()
                reinforceNowPlayingTransportState()
            } else {
                do {
                    try hiResPlaybackEngine.play()
                } catch {
                    errorMessage = L10n.tr("error.playback_start_failed", error.localizedDescription)
                    return
                }
                clearForcedPausedWindow()
                isPlaying = true
                startTimer()
                resumeAutomaticQualityUpgradeIfNeeded()
                reinforceNowPlayingTransportState()
            }
            persistLibraryState()
        case .system:
            ensureSystemPlayerConfigured()
            if systemPlayer.playbackState == .playing {
                recordUserPauseIntent()
                systemPlayer.pause()
                isPlaying = false
                stopTimer()
                beginForcedPausedWindow(for: .system, duration: 1.0)
                forcedWriteNowPlayingPaused()
                reinforceNowPlayingTransportState()
            } else {
                // UIへの即時フィードバック：再生開始を信じてフラグを立てる
                isPlaying = true
                isProcessing = true
                clearForcedPausedWindow()

                print("[SystemPlayer] togglePlayback: Triggering play()")
                systemPlayer.play()
                
                // DRM曲などの再生開始遅延に対応するため非同期で監視を行う
                Task { @MainActor in
                    var confirmed = false
                    // 最大8回（約2秒）ポーリングして再生開始を確認する
                    for i in 0..<8 {
                        try? await Task.sleep(nanoseconds: 250_000_000)
                        if systemPlayer.playbackState == .playing {
                            print("[SystemPlayer] togglePlayback: Playback confirmed at poll \(i)")
                            confirmed = true
                            break
                        }
                        // DRM曲の場合、セッションが不安定なら再度play()を呼ぶことで活性化することがある
                        systemPlayer.play()
                    }
                    
                    if !confirmed {
                        // 一定時間経過しても再生されない場合は、キューの再セットを含む堅牢な再生ロジックへフォールバック
                        print("[SystemPlayer] togglePlayback: Fallback to robust resume")
                        _ = resumePlaybackFromAnyKnownContext()
                        // DRMの準備が遅れているだけの場合があるため、ここで
                        // ローディングを終了せず、実再生の確認まで監視を継続する。
                        monitorPlaybackStart(for: .system)
                    } else {
                        // 正常に開始された場合は状態を同期
                        syncSystemPlaybackState()
                        if isPlaying {
                            startTimer()
                        }
                        reinforceNowPlayingTransportState()
                        isPlaybackStarting = false
                        isProcessing = false
                        errorMessage = nil
                    }
                }
            }
            persistLibraryState()
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
        let cached = await Task.detached(priority: .utility) {
            AppLibraryStore().loadCachedSystemLibrarySnapshot()
        }.value
        guard let cached, systemSongs.isEmpty else { return false }
        let snapshot = SystemLibrarySnapshot(
            songs: cached.songs.filter { $0.url == nil },
            artists: cached.artists.filter { !$0.isLocalLibraryIdentifier },
            albums: cached.albums.filter { !$0.isLocalLibraryIdentifier }
        )

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
            if isInForcedPausedWindow {
                isPlaying = false
            } else {
                isPlaying = hiResPlaybackEngine.isPlaying
            }
            
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
            return hiResPlaybackEngine.isPlaying ? .playing : .paused
        case .system:
            guard isSystemPlayerConfigured else { return .paused }
            let state: MPNowPlayingPlaybackState = systemPlayer.playbackState == .playing ? .playing : .paused
            return state
        }
    }

    private var actualPlaybackRate: Double {
        actualPlaybackState == .playing ? 1.0 : 0.0
    }

    private func reinforceNowPlayingTransportState() {
        // 【重要】ウィジェット同期の補強
        // iOSのメディア通信は非同期かつ不安定なため、停止直後に複数回の再送を行い、
        // システム側の「再生中」への予測復帰 (Prediction) を強力に抑え込みます。
        reinforceTaskID += 1
        let taskID = reinforceTaskID
        updateNowPlayingInfo(force: true)

        let delays: [TimeInterval] = [0.15, 0.45, 1.2]
        for delay in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.reinforceTaskID == taskID, !self.isInterrupted else { return }
                // forcedPausedWindowが終了していても、停止状態の場合は明示的に書き込む
                if !self.isPlaying {
                    self.forcedWriteNowPlayingPaused()
                } else {
                    self.updateNowPlayingInfo(force: true)
                }
                
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
        guard !isPlaying, !isSystemPlayerStarting else { return false }

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
        guard isSystemPlayerConfigured else {
            isPlaying = false
            updateQueueCapabilities()
            return
        }

        guard let item = systemPlayer.nowPlayingItem else {
            progress = 0
            currentTimeText = "00:00"
            isPlaying = false
            updateQueueCapabilities()
            return
        }

        selectedSystemSongID = UInt64(item.persistentID)
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
        currentTimeText = formatTime(current)
        durationText = formatTime(duration)
        nowPlayingArtwork = item.artwork?.image(at: CGSize(width: 600, height: 600))
        nowPlayingAlbum = resolveAlbum(from: item)
        if isInForcedPausedWindow {
            isPlaying = false
        } else {
            isPlaying = systemPlayer.playbackState == .playing
        }
        updateQueueCapabilities()
    }

    private var isSystemPlaybackAtTrackEnd: Bool {
        guard let item = systemPlayer.nowPlayingItem else { return false }
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
        updateTimer = Timer.scheduledTimer(
            timeInterval: 0.25,
            target: self,
            selector: #selector(handleTimerTick),
            userInfo: nil,
            repeats: true
        )
        startVisualizationTimer()
    }

    private func stopTimer(animateMeter: Bool = true) {
        updateTimer?.invalidate()
        updateTimer = nil
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
        visualizationTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 30.0, // UI負荷を抑えるため30fpsに制限
            target: self,
            selector: #selector(handleVisualizationTimerTick),
            userInfo: nil,
            repeats: true
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
        updateVUMeterValue(rmsDBFS: levels.rmsDBFS, date: Date())

        // 微小変化の連続Publishを抑えてメインスレッドの再描画負荷を下げる
        if abs(levels.rmsDBFS - currentOutputRMS) > 0.2 {
            currentOutputRMS = levels.rmsDBFS
        }
        if abs(levels.peakDBFS - currentOutputPeak) > 0.2 {
            currentOutputPeak = levels.peakDBFS
        }

        // Spectrumは更新コストが高いため、差分があるときだけ30fps相当で反映
        if visualizationTickCount % 2 == 0, !levels.spectrum.isEmpty {
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
            resetVisualizationMeters(resetSpectrum: visualizationTickCount % 2 == 0)
            return
        }

        guard supportsRealtimeEffects else {
            // DRM/system playback cannot expose audio samples. Keep visualization meters at rest;
            // the UI locks these tracks to album artwork.
            resetVisualizationMeters(resetSpectrum: visualizationTickCount % 2 == 0)
            return
        }

        syntheticVisualizationPhase += 0.08
        let t = syntheticVisualizationPhase

        let rms = -24.0 + Float((sin(t * 1.3) + sin(t * 0.47) * 0.6) * 5.5)
        let peak = rms + 5.0 + Float((sin(t * 2.4) + 1.0) * 1.8)
        currentOutputRMS = min(-6, max(-40, rms))
        currentOutputPeak = min(-1, max(-30, peak))
        updateVUMeterValue(rmsDBFS: currentOutputRMS, date: Date())

        if visualizationTickCount % 2 != 0 { return }

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

    private func updateVUMeterValue(rmsDBFS: Float, date: Date) {
        let target = normalizedVUTarget(rmsDBFS: rmsDBFS)
        let nextValue = vuBallistics.update(target: target, date: date)
        if abs(nextValue - currentVUValue) > 0.003 {
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
        hiResPlaybackEngine.stop()
        localPlaybackFormatDescription = L10n.playbackFormatUnavailable()
        isPlaying = false
        stopTimer()
        stopVisualizationTimer()
        beginForcedPausedWindow(for: .local)
        if clearTrackSelection {
            selectedSystemSongID = nil
        }
        
        // 停止時はセッションを非アクティブにしてシステムに通知する
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        reinforceNowPlayingTransportState()
    }

    private func formatTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite else { return "00:00" }
        let totalSeconds = Int(interval.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    @objc private func handleTimerTick() {
        memorySafetyTickCount &+= 1
        if memorySafetyTickCount % 8 == 0 {
            applyProactiveMemorySafetyIfNeeded()
        }

        // Fallback end detection: some devices/routes don't always emit reliable completion transitions.
        switch playbackSource {
        case .local:
            audioRenderHealth = hiResPlaybackEngine.pollRenderHealth()
            let hasTrack = hiResPlaybackEngine.hasTrack
            let duration = hiResPlaybackEngine.duration
            let current = hiResPlaybackEngine.currentTime()
            let isEnginePlaying = hiResPlaybackEngine.isPlaying
            let reachedEnd = hasTrack && duration > 0 && current >= max(0, duration - 0.03)

            if isPlaying && !isEnginePlaying {
                if isInForcedPausedWindow {
                    return
                }
                if reachedEnd {
                    handleLocalPlaybackEnded()
                } else {
                    // Route changes and transient media-service failures can
                    // stop the node while its track remains valid.
                    scheduleUnexpectedLocalPlaybackRecovery(reason: "render_node_stopped")
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
               !hasNextTrackInQueue,
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

    @objc private func handleSystemNowPlayingChanged() {
        guard playbackSource == .system else { return }
        syncSystemPlaybackState()
        updateNowPlayingInfo(force: true)
    }

    @objc private func handleSystemPlaybackChanged() {
        guard playbackSource == .system else { return }

        let state = systemPlayer.playbackState

        if state == .playing {
            clearForcedPausedWindow()
            startTimer()
            startVisualizationTimer()
        } else if state == .paused || state == .stopped {
            stopTimer()
        }

        syncSystemPlaybackState()
        updateNowPlayingInfo(force: true)

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

    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        // Capture transport state before hopping back onto MainActor. The
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
                self.interruptedPlaybackSource = sourceAtNotification
                self.interruptionPauseIntentBaseline = pauseIntentAtNotification
                self.interruptionPlaybackPreparationBaseline = preparationAtNotification
                self.isInterrupted = true
                self.isPlaying = false
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
                self.isInterrupted = false
                let rawOptions = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
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

    private func resumePlaybackAfterInterruption(
        source: PlaybackSource,
        generation: UInt64
    ) {
        interruptionResumeTask?.cancel()
        interruptionResumeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let retryDelays: [UInt64] = [0, 200_000_000, 500_000_000, 1_000_000_000, 1_500_000_000]
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
                      !Task.isCancelled else {
                    if self.interruptionGeneration == generation {
                        self.clearInterruptionResumeState()
                    }
                    return
                }

                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default, options: [])
                    try session.setActive(true)

                    let didResume: Bool
                    switch source {
                    case .local:
                        guard self.hasInitializedHiResPlaybackEngine,
                              self.hiResPlaybackEngine.hasTrack else {
                            self.clearInterruptionResumeState()
                            return
                        }
                        try self.hiResPlaybackEngine.play()
                        try? await Task.sleep(nanoseconds: 160_000_000)
                        didResume = self.hiResPlaybackEngine.isPlaying
                            && self.hiResPlaybackEngine.isEngineRunning
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
                        self.clearForcedPausedWindow()
                        self.isPlaying = true
                        self.isProcessing = false
                        self.isPlaybackStarting = false
                        self.startTimer()
                        if source == .local {
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

            guard self.interruptionGeneration == generation else { return }
            if let lastActivationError {
                self.errorMessage = L10n.tr(
                    "error.playback_session_failed",
                    lastActivationError.localizedDescription
                )
            }
            PlaybackDebugLogger.warning(
                "audio.interruption.resume ready=false source=\(String(describing: source))"
            )
            self.isPlaying = false
            self.stopTimer()
            self.refreshPlaybackState()
            self.updateNowPlayingInfo(force: true)
            self.clearInterruptionResumeState()
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

        unexpectedPlaybackRecoveryTask = Task { @MainActor [weak self] in
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
                      self.playbackSource == .local,
                      self.playbackPreparationToken == preparationToken,
                      self.userPauseIntentToken == pauseIntentToken,
                      self.selectedSystemSongID == expectedSongID,
                      self.hiResPlaybackEngine.currentAudioURL == expectedURL,
                      self.isPlaying,
                      !self.isInterrupted,
                      !self.isInForcedPausedWindow else {
                    self.unexpectedPlaybackRecoveryTask = nil
                    self.isPlaybackStarting = false
                    return
                }

                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default, options: [])
                    try session.setActive(true)

                    let safeResumeTime = min(
                        max(0, resumeTime),
                        max(0, self.hiResPlaybackEngine.duration - 0.05)
                    )
                    try self.hiResPlaybackEngine.seek(to: safeResumeTime)
                    try self.hiResPlaybackEngine.play()
                    try await Task.sleep(nanoseconds: 180_000_000)

                    guard !Task.isCancelled else { return }
                    if self.hiResPlaybackEngine.isPlaying {
                        self.clearForcedPausedWindow()
                        self.isPlaying = true
                        self.isProcessing = false
                        self.isPlaybackStarting = false
                        self.unexpectedPlaybackRecoveryTask = nil
                        self.startTimer()
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

            guard self.playbackPreparationToken == preparationToken,
                  self.userPauseIntentToken == pauseIntentToken else {
                self.unexpectedPlaybackRecoveryTask = nil
                return
            }

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

    @objc private func handleMediaServicesWereReset(_ notification: Notification) {
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
        guard !shouldIgnoreDuplicateTrackEndEvent() else { return }

        PlaybackDebugLogger.event(
            "audio.local.ended current=\(String(format: "%.3f", hiResPlaybackEngine.currentTime())) duration=\(String(format: "%.3f", hiResPlaybackEngine.duration)) queueIndex=\(systemQueueIndex.map(String.init) ?? "none")"
        )
        
        if isInForcedPausedWindow {
            return
        }

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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        updateNowPlayingInfo(force: true)
        reinforceNowPlayingTransportState()
        persistLibraryState()
    }

    private func handleSystemPlaybackEnded() {
        guard !shouldIgnoreDuplicateTrackEndEvent() else { return }

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
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        
        reinforceNowPlayingTransportState()
        persistLibraryState()
    }

    // MARK: - Remote Command & Now Playing Info（ロック画面 / コントロールセンター）

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        let playTarget = commandCenter.playCommand.addTarget { [weak self] _ in
            return self?.handleRemotePlayCommand() ?? .commandFailed
        }
        remoteCommandRegistrations.append((commandCenter.playCommand, playTarget))

        commandCenter.pauseCommand.isEnabled = true
        let pauseTarget = commandCenter.pauseCommand.addTarget { [weak self] _ in
            return self?.handleRemotePauseCommand() ?? .commandFailed
        }
        remoteCommandRegistrations.append((commandCenter.pauseCommand, pauseTarget))
        
        commandCenter.togglePlayPauseCommand.isEnabled = true
        let toggleTarget = commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            return self.actualPlaybackState == .playing
                ? self.handleRemotePauseCommand()
                : self.handleRemotePlayCommand()
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
        guard activatePlaybackSessionForRemoteStart() else {
            scheduleRemoteSessionActivationRetry()
            reinforceNowPlayingTransportState()
            // The command has been accepted. AVAudioSession commonly needs a
            // short settling period after another app or route owns the audio
            // stack, so complete it asynchronously instead of surfacing a
            // transient activation error.
            return .success
        }
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
            guard !hiResPlaybackEngine.isPlaying else {
                updateNowPlayingInfo()
                return .success
            }
            do {
                try hiResPlaybackEngine.play()
                clearForcedPausedWindow()
                startTimer()
                refreshPlaybackState()
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
                updateNowPlayingInfo()
                return .success
            }
            
            // リモートコマンド起動時も、UIと同様の即時レスポンスとポーリングによる安定化を行う
            isPlaying = true
            isProcessing = true
            isPlaybackStarting = true
            clearForcedPausedWindow()
            
            print("[SystemPlayer] handleRemotePlayCommand: Triggering play()")
            systemPlayer.play()
            
            Task { @MainActor in
                var confirmed = false
                // リモート時はコントロールセンター側のタイムアウトも考慮し、4回（約1秒）程度で判定
                for i in 0..<4 {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if systemPlayer.playbackState == .playing {
                        print("[SystemPlayer] handleRemotePlayCommand: Playback confirmed at poll \(i)")
                        confirmed = true
                        break
                    }
                    systemPlayer.play()
                }
                
                if !confirmed {
                    print("[SystemPlayer] handleRemotePlayCommand: Fallback to robust resume")
                    _ = resumePlaybackFromAnyKnownContext()
                    monitorPlaybackStart(for: .system)
                } else {
                    syncSystemPlaybackState()
                    if isPlaying {
                        startTimer()
                    }
                    reinforceNowPlayingTransportState()
                    isPlaybackStarting = false
                    isProcessing = false
                    errorMessage = nil
                }
            }
            persistLibraryState()
            return .success
        }
    }

    private func activatePlaybackSessionForRemoteStart() -> Bool {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            return true
        } catch {
            PlaybackDebugLogger.warning(
                "audio.session.activation_deferred error=\(error.localizedDescription)"
            )
            return false
        }
    }

    private func scheduleRemoteSessionActivationRetry() {
        sessionActivationRetryTask?.cancel()
        let pauseToken = userPauseIntentToken
        let preparationToken = playbackPreparationToken
        isPlaybackStarting = true

        sessionActivationRetryTask = Task { @MainActor [weak self] in
            guard let self else { return }
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
                    self.sessionActivationRetryTask = nil
                    self.isPlaybackStarting = false
                    return
                }

                do {
                    let session = AVAudioSession.sharedInstance()
                    try session.setCategory(.playback, mode: .default, options: [])
                    try session.setActive(true)

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

            self.sessionActivationRetryTask = nil
            self.isPlaybackStarting = false
            let playbackRecovered = self.actualPlaybackState == .playing
                || (self.hasInitializedHiResPlaybackEngine && self.hiResPlaybackEngine.isPlaying)
            guard !playbackRecovered,
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

    private func handleRemotePauseCommand() -> MPRemoteCommandHandlerStatus {
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
        sessionActivationRetryTask?.cancel()
        sessionActivationRetryTask = nil
    }

    /// 【必須】ウィジェット状態の強制上書き
    /// stop() や pause() の直後に呼ぶ。既存の辞書を書き換えるのではなく、
    /// 「再生レート 0.0」が刻まれた純粋な辞書を新しく生成してセットすることで、
    /// システム側の古いキャッシュや予測ロジックによる「再生中」への回帰を回避します。
    private func forcedWriteNowPlayingPaused(item: MPMediaItem? = nil, elapsed: TimeInterval = 0) {
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
        // system再生時は force / forcedPausedWindow / 実状態変化時に反映。
        // playbackState 直接設定は使わず、rate/elapsed中心で同期する。
        let currentState = actualPlaybackState
        let hasStateChanged = currentState != lastNowPlayingState
        let shouldUpdateForSystem = playbackSource == .system && (isInForcedPausedWindow || force || hasStateChanged)
        guard playbackSource == .local || shouldUpdateForSystem else { return }

        let snapshot = makeNowPlayingSnapshot()
        
        guard snapshot.hasTrack else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            lastNowPlayingTrackKey = nil
            lastNowPlayingState = .unknown
            lastNowPlayingElapsed = 0
            return
        }

        // Rebuild the dictionary for every track/state update. Reusing the
        // previous dictionary can leave stale artwork or metadata on the lock screen.
        var nowPlayingInfo: [String: Any] = [
            MPMediaItemPropertyTitle: snapshot.title,
            MPMediaItemPropertyArtist: snapshot.subtitle,
            MPMediaItemPropertyPlaybackDuration: snapshot.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: snapshot.elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: actualPlaybackRate,
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

    private func stopCurrentPlaybackForTransition() {
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
            localPlaybackFormatDescription = L10n.playbackFormatUnavailable()
        case .system:
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

    private func startProtectedSystemPlayback(with items: [MPMediaItem]) {
        guard let firstItem = items.first else {
            errorMessage = L10n.tr("error.queue_not_found")
            return
        }

        // 遷移処理の開始
        stopCurrentPlaybackForTransition()
        let transitionToken = playbackPreparationToken
        let expectedSongID = UInt64(firstItem.persistentID)
        playbackSource = .system
        ensureSystemPlayerConfigured()
        
        // 早期に再生中フラグを立てることで、UIを即座に再生画面の状態にする
        isPlaying = true
        isProcessing = true
        isPlaybackStarting = true

        // セッションカテゴリの確保。setActive(false) はデーモンとの接続を不安定にするため呼びません。
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            // すでにアクティブな場合も多いため、エラーは無視。
            try? session.setActive(true)
        } catch {
            print("[SystemPlayer] Failed to set session category: \(error)")
        }

        let targetID = firstItem.persistentID
        let storeID = firstItem.playbackStoreID
        print("[SystemPlayer] Attempting playback for ID: \(targetID), StoreID: \(storeID)")

        // 【Freshnessの保証】
        guard let freshItem = systemMediaLibrary.mediaItem(for: targetID) else {
            print("[SystemPlayer] Failed to re-fetch fresh item content.")
            isSystemPlayerStarting = false
            isProcessing = false
            isPlaybackStarting = false
            isPlaying = false
            errorMessage = L10n.tr("error.song_not_found")
            return
        }

        // systemMusicPlayer では MPMediaItemCollection ベースのほうが
        // ライブラリ内 DRM 曲の解決が安定しやすい。
        let queueItems: [MPMediaItem]
        if items.count > 1 {
            let refreshedItems = items.compactMap { item in
                systemMediaLibrary.mediaItem(for: UInt64(item.persistentID))
            }
            queueItems = refreshedItems.isEmpty ? [freshItem] : refreshedItems
        } else {
            queueItems = [freshItem]
        }
        let queueCollection = MPMediaItemCollection(items: queueItems)

        print("[SystemPlayer] Setting media item queue with \(queueItems.count) item(s)...")
        logProtectedPlaybackDiagnostics("before_start", queueItems: queueItems)
        isSystemPlayerStarting = true

        Task { @MainActor in
            let maxAttempts = 3
            let initialPropagationWait: UInt64 = 350_000_000
            let pollInterval: UInt64 = 250_000_000
            let maxPolls = 12
            var didStartPlaying = false

            for attempt in 1...maxAttempts {
                guard self.playbackPreparationToken == transitionToken,
                      self.selectedSystemSongID == expectedSongID,
                      self.playbackSource == .system else { return }
                print("[SystemPlayer] Applying media item queue (attempt \(attempt))...")
                self.systemPlayer.setQueue(with: queueCollection)
                try? await Task.sleep(nanoseconds: initialPropagationWait)
                guard self.playbackPreparationToken == transitionToken,
                      self.selectedSystemSongID == expectedSongID,
                      self.playbackSource == .system else { return }

                let hasItemAfterQueue = self.systemPlayer.nowPlayingItem != nil
                let stateAfterQueue = self.systemPlayer.playbackState
                print("[SystemPlayer] Queue applied (attempt \(attempt)): state=\(stateAfterQueue.rawValue), hasItem=\(hasItemAfterQueue)")
                self.logProtectedPlaybackDiagnostics("after_setQueue_attempt_\(attempt)", queueItems: queueItems)

                print("[SystemPlayer] Triggering play() (attempt \(attempt)).")
                self.systemPlayer.play()
                self.logProtectedPlaybackDiagnostics("after_play_attempt_\(attempt)", queueItems: queueItems)

                for poll in 0..<maxPolls {
                    guard self.playbackPreparationToken == transitionToken,
                          self.selectedSystemSongID == expectedSongID,
                          self.playbackSource == .system else { return }
                    let state = self.systemPlayer.playbackState
                    let itemExists = self.systemPlayer.nowPlayingItem != nil
                    if state == .playing {
                        print("[SystemPlayer] Playback confirmed at poll \(poll).")
                        self.syncSystemPlaybackState()
                        didStartPlaying = true
                        break
                    }
                    if itemExists && state == .paused {
                        print("[SystemPlayer] Queue is ready but paused at poll \(poll), retrying play().")
                        self.systemPlayer.play()
                    }
                    try? await Task.sleep(nanoseconds: pollInterval)
                }

                if didStartPlaying {
                    break
                }

                print("[SystemPlayer] Playback did not start on attempt \(attempt).")
            }

            self.isSystemPlayerStarting = false
            self.isProcessing = false

            if !didStartPlaying {
                print("[SystemPlayer] All specific attempts failed. Final play() attempt.")
                self.systemPlayer.play()
                self.logProtectedPlaybackDiagnostics("final_play_attempt", queueItems: queueItems)
            }

            self.syncSystemPlaybackState()
            self.startTimer()
            self.persistLibraryState()

            // 最終監視
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard self.playbackPreparationToken == transitionToken,
                  self.selectedSystemSongID == expectedSongID,
                  self.playbackSource == .system else { return }
            self.syncSystemPlaybackState()
            if self.playbackSource == .system && self.systemPlayer.playbackState != .playing {
                print("[SystemPlayer] Final fallback check failed. Forcing play() again.")
                self.systemPlayer.play()
                self.syncSystemPlaybackState()
            }

            self.isPlaybackStarting = self.playbackSource == .system
                && self.systemPlayer.playbackState != .playing
            if !self.isPlaybackStarting {
                self.isProcessing = false
            } else {
                self.monitorPlaybackStart(for: .system)
            }
            
            // 全ての準備が整い、音が鳴り始めた（または最終試行が終わった）段階で確実にフラグを折る
            self.isProcessing = false
        }
    }

    private func resolveAlbum(from item: MPMediaItem) -> SystemAlbum? {
        let albumID = UInt64(item.albumPersistentID)
        if albumID != 0, let matchedAlbum = systemAlbums.first(where: { $0.id == albumID }) {
            return matchedAlbum
        }

        let title = item.albumTitle ?? L10n.unknownAlbum()
        let artist = item.albumArtist ?? item.artist ?? L10n.unknownArtist()
        return systemAlbums.first(where: { $0.title == title && $0.artist == artist })
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
        if playbackSource == .system, isSystemPlayerConfigured {
            systemPlayer.pause()
        }
        localPlaybackFormatDescription = L10n.tr("playback.preparing")
        stopCurrentPlaybackForTransition()
        playbackSource = .local
        selectedSystemSongID = song.id
        trackTitle = song.title
        trackSubtitle = queueAwareSubtitle(artist: song.artist, album: song.album, queueTitle: queueTitle)
        
        if let mediaItem = mediaItem {
            nowPlayingArtwork = mediaItem.artwork?.image(at: CGSize(width: 600, height: 600))
            nowPlayingAlbum = resolveAlbum(from: mediaItem)
        } else {
            // ローカルファイルの場合は非同期で取得済みの可能性もあるが、ここで再確認
            nowPlayingAlbum = systemAlbums.first(where: { $0.title == song.album && $0.artist == song.artist })
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
            do {
                let preferredUpsampling = restoreUpsamplingMode
                    ?? self.memorySafetyMode.automaticUpsamplingMode
                let requestedUpsampling = self.automaticUpsamplingMode(
                    for: assetURL,
                    preferred: preferredUpsampling
                )
                self.upsamplingMode = requestedUpsampling
                if preferredUpsampling.isPrecisionSinc,
                   requestedUpsampling == .avAudioConverter,
                   !assetURL.isFileURL,
                   self.precisionUpgradeSkippedSongID != song.id {
                    self.precisionUpgradeSkippedSongID = song.id
                    PlaybackDebugLogger.warning(
                        "audio.quality_upgrade.skipped reason=media_library_concurrent_decode songID=\(song.id) scheme=\(assetURL.scheme ?? "unknown")"
                    )
                }
                let shouldUseTwoStageLoad = restoreUpsamplingMode == nil && requestedUpsampling.isPrecisionSinc

                try await self.hiResPlaybackEngine.load(
                    url: assetURL,
                    effectSettings: self.playbackEffectSettings,
                    headphoneSpatialSettings: self.playbackSpatialSettings,
                    upsamplingMode: requestedUpsampling,
                    strategy: .immediateStreaming
                )
                try Task.checkCancellation()
                guard self.playbackPreparationToken == preparationToken,
                      self.selectedSystemSongID == song.id,
                      self.playbackSource == .local else {
                    throw CancellationError()
                }
                self.localPlaybackFormatDescription = self.hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                if autoplay {
                    try self.hiResPlaybackEngine.play()
                    self.clearForcedPausedWindow()
                    self.isPlaying = true
                    self.startTimer()
                } else {
                    self.beginForcedPausedWindow(for: .local)
                    self.isPlaying = false
                }
                self.refreshPlaybackState()
                if shouldUseTwoStageLoad && self.isBackgroundQualityUpgradeEnabled {
                    self.startPrecisionSincUpgrade(
                        songID: song.id,
                        assetURL: assetURL,
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
                print("[HiResPlayback] load failed with \(restoreUpsamplingMode ?? self.upsamplingMode): \(error.localizedDescription)")
            }

            guard !Task.isCancelled, self.playbackPreparationToken == preparationToken else { return }
            do {
                    try await self.hiResPlaybackEngine.load(
                        url: assetURL,
                        effectSettings: self.playbackEffectSettings,
                        headphoneSpatialSettings: self.playbackSpatialSettings,
                        upsamplingMode: .avAudioConverter,
                        strategy: .preparedAVAudioConverter
                    )
                    try Task.checkCancellation()
                    guard self.playbackPreparationToken == preparationToken else { throw CancellationError() }
                    self.localPlaybackFormatDescription = self.hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                    if autoplay {
                        try self.hiResPlaybackEngine.play()
                        self.clearForcedPausedWindow()
                        self.isPlaying = true
                        self.startTimer()
                    } else {
                        self.beginForcedPausedWindow(for: .local)
                        self.isPlaying = false
                    }
                    self.playbackSource = .local
                    self.refreshPlaybackState()
                    self.errorMessage = nil
                    self.localPlaybackLoadTask = nil
                    return
                } catch is CancellationError {
                    return
                } catch {
                    print("[HiResPlayback] AVAudioConverter recovery failed: \(error.localizedDescription)")
                    // A failed high-quality attempt may have left large temporary
                    // allocations behind. Retry once after entering constrained
                    // mode before reporting a preparation failure.
                    self.enterMemoryOptimizedMode(
                        .constrained,
                        reason: "converter_recovery_retry"
                    )
                    do {
                        try await self.hiResPlaybackEngine.load(
                            url: assetURL,
                            effectSettings: self.playbackEffectSettings,
                            headphoneSpatialSettings: self.playbackSpatialSettings,
                            upsamplingMode: .avAudioConverter,
                            strategy: .preparedAVAudioConverter
                        )
                        try Task.checkCancellation()
                        guard self.playbackPreparationToken == preparationToken else { throw CancellationError() }
                        self.localPlaybackFormatDescription = self.hiResPlaybackEngine.currentFormat?.description ?? L10n.playbackFormatUnavailable()
                        if autoplay {
                            try self.hiResPlaybackEngine.play()
                            self.clearForcedPausedWindow()
                            self.isPlaying = true
                            self.startTimer()
                        }
                        self.playbackSource = .local
                        self.refreshPlaybackState()
                        self.errorMessage = nil
                        self.localPlaybackLoadTask = nil
                        return
                    } catch is CancellationError {
                        return
                    } catch {
                        self.errorMessage = L10n.tr("error.playback_prepare_failed", error.localizedDescription)
                    }
            }

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
        localPlaybackFormatDescription = L10n.playbackFormatProtected()

        if autoplay {
            startProtectedSystemPlayback(with: [mediaItem])
        } else {
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

        // ローカルファイルまたはシステムライブラリ（assetURL取得可能）の判定
        let playbackURL: URL?
        let currentItem: MPMediaItem?
        
        if let localURL = selectedSong.url {
            playbackURL = localURL
            currentItem = nil
        } else if let item = systemMediaLibrary.mediaItem(for: selectedSong.id), let assetURL = item.assetURL {
            playbackURL = assetURL
            currentItem = item
        } else {
            playbackURL = nil
            currentItem = systemMediaLibrary.mediaItem(for: selectedSong.id)
        }

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
            playbackSource = .system
            trackTitle = selectedSong.title
            trackSubtitle = queueAwareSubtitle(
                artist: selectedSong.artist,
                album: selectedSong.album,
                queueTitle: snapshot.queueTitle
            )
            durationText = formatTime(selectedSong.duration)
            currentTimeText = "00:00"
            progress = 0
            nowPlayingArtwork = item.artwork?.image(at: CGSize(width: 600, height: 600))
            nowPlayingAlbum = resolveAlbum(from: item)
            localPlaybackFormatDescription = L10n.playbackFormatProtected()
            isPlaying = false
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
        hiResPlaybackEngine.updateHeadphoneSpatialSettings(playbackSpatialSettings, effectSettings: playbackEffectSettings) { [weak self] error in
            guard let self else { return }
            self.isSpatialProcessing = false
            if let error {
                self.errorMessage = L10n.tr("error.playback_prepare_failed", error.localizedDescription)
                return
            }
            self.refreshPlaybackState()
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
            
            if shouldResume {
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
        if let localURL = song.url {
            return (localURL, nil)
        }
        if let item = systemMediaLibrary.mediaItem(for: song.id), let assetURL = item.assetURL {
            return (assetURL, item)
        }
        return (nil, systemMediaLibrary.mediaItem(for: song.id))
    }

    private func scheduleNextTrackPreload(after currentIndex: Int) {
        guard isNextTrackMemoryPreloadEnabled else {
            PlaybackDebugLogger.event(
                "audio.preload.skipped reason=full_track_memory_isolation"
            )
            return
        }
        guard systemQueue.indices.contains(currentIndex) else { return }
        let nextIndex = currentIndex + 1
        guard systemQueue.indices.contains(nextIndex) else { return }
        let nextSong = systemQueue[nextIndex]
        let (nextURL, _) = resolvePlayableAsset(for: nextSong)
        guard let nextURL else { return }

        preloadTrackTask?.cancel()
        let spatialSettings = playbackSpatialSettings
        let preloadMode = memorySafetyMode.automaticUpsamplingMode
        // Streaming AVAudioConverter playback already starts immediately and
        // does not benefit from retaining another full-track PCM buffer.
        guard preloadMode.isPrecisionSinc else { return }
        let currentSongID = systemQueue[currentIndex].id
        let currentUpgradeTask = precisionUpgradeTask
        preloadTrackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Current-track quality has priority. Only use spare time and
            // memory for the following track after that upgrade completes.
            if let currentUpgradeTask {
                await currentUpgradeTask.value
            }
            guard !Task.isCancelled,
                  self.selectedSystemSongID == currentSongID,
                  self.systemQueueIndex == currentIndex else { return }
            guard HiResPlaybackEngine.canPrepareOffline(
                url: nextURL,
                upsamplingMode: preloadMode
            ) else { return }
            self.hiResPlaybackEngine.preloadTrack(
                url: nextURL,
                headphoneSpatialSettings: spatialSettings,
                upsamplingMode: preloadMode
            )
        }
    }

    private func startPrecisionSincUpgrade(songID: UInt64, assetURL: URL, targetUpsampling: UpsamplingMode) {
        guard memorySafetyMode == .normal else { return }
        guard assetURL.isFileURL else {
            if precisionUpgradeSkippedSongID != songID {
                precisionUpgradeSkippedSongID = songID
                PlaybackDebugLogger.warning(
                    "audio.quality_upgrade.skipped reason=media_library_concurrent_decode songID=\(songID) scheme=\(assetURL.scheme ?? "unknown")"
                )
            }
            upsamplingMode = .avAudioConverter
            return
        }
        precisionUpgradeSkippedSongID = nil
        precisionUpgradeTask?.cancel()
        let tokenAtStart = playbackPreparationToken
        precisionUpgradeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Defer expensive background rebuild to keep first-load snappiness.
            try? await Task.sleep(nanoseconds: 2_800_000_000)
            guard !Task.isCancelled else { return }
            guard self.playbackPreparationToken == tokenAtStart else { return }
            guard self.playbackSource == .local else { return }
            guard self.selectedSystemSongID == songID else { return }
            guard self.hiResPlaybackEngine.currentAudioURL == assetURL else { return }
            guard self.hiResPlaybackEngine.isPlaying else { return }

            // If user just interacted (skip/seek/tap), don't compete with UI responsiveness.
            let now = CFAbsoluteTimeGetCurrent()
            if now - self.lastUserPlaybackInteractionAt < 2.0 { return }

            // The live process allowance can be much smaller than physical
            // device RAM. Do not begin a full-track Precision Sinc allocation
            // unless the complete peak plus a system reserve fits now.
            guard HiResPlaybackEngine.canPrepareOffline(
                url: assetURL,
                upsamplingMode: targetUpsampling
            ) else {
                self.enterMemoryOptimizedMode(
                    .reduced,
                    reason: "precision_allocation_budget",
                    cancelCurrentQualityUpgrade: false
                )
                return
            }

            PlaybackDebugLogger.event(
                "audio.quality_upgrade.begin \(HiResPlaybackEngine.processMemoryDiagnostic)"
            )
            let shouldResume = self.hiResPlaybackEngine.isPlaying
            do {
                try await self.hiResPlaybackEngine.seamlessUpgrade(
                    url: assetURL,
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
                print("[HiResPlayback] background quality upgrade failed: \(error.localizedDescription)")
            }
        }
    }

    /// A memory recovery can complete while the current track is paused. In
    /// that case the desired mode is already normal, so the periodic recovery
    /// monitor has nothing left to transition. Resume the deferred quality
    /// upgrade when audible playback starts again.
    private func resumeAutomaticQualityUpgradeIfNeeded() {
        guard isBackgroundQualityUpgradeEnabled,
              memorySafetyMode == .normal,
              playbackSource == .local,
              hiResPlaybackEngine.hasTrack,
              hiResPlaybackEngine.isPlaying,
              hiResPlaybackEngine.activeUpsamplingMode != memorySafetyMode.automaticUpsamplingMode,
              let songID = selectedSystemSongID,
              let currentURL = hiResPlaybackEngine.currentAudioURL,
              currentURL.isFileURL else {
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
        playbackStartMonitorTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // Keep the loading state alive until playback is actually
            // confirmed. Large offline conversions and protected media can
            // take longer than the old fixed timeout; ending this monitor
            // early made the spinner stop while audio was still preparing.
            while !Task.isCancelled {
                guard !Task.isCancelled else { return }
                let didStart: Bool
                switch source {
                case .local:
                    didStart = self.playbackSource == .local
                        && self.hiResPlaybackEngine.isPlaying
                        && self.hiResPlaybackEngine.currentTime() > 0.02
                case .system:
                    didStart = self.playbackSource == .system
                        && self.systemPlayer.playbackState == .playing
                }

                if didStart {
                    self.isPlaybackStarting = false
                    self.isProcessing = false
                    self.errorMessage = nil
                    self.playbackStartMonitorTask = nil
                    self.refreshPlaybackState()
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
        if let albumID = song.albumID,
           let album = systemAlbums.first(where: { $0.id == albumID }) {
            return album
        }

        return SystemAlbum(
            id: song.albumID ?? UInt64(bitPattern: Int64(song.album.hashValue)),
            title: song.album,
            artist: song.artist,
            songCount: songs(forFallbackAlbumTitle: song.album, artist: song.artist).count
        )
    }

    private func songs(forFallbackAlbumTitle title: String, artist: String) -> [SystemSong] {
        systemSongs.filter { $0.album == title && $0.artist == artist }
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
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemNowPlayingChanged),
            name: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: systemPlayer
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleSystemPlaybackChanged),
            name: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: systemPlayer
        )
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
        let artistGroups = Dictionary(grouping: songs) { song in
            song.artistID.map(String.init) ?? "name:\(song.artist)"
        }
        let artists = artistGroups.values.compactMap { group -> SystemArtist? in
            guard !Task.isCancelled else { return nil }
            guard let first = group.first else { return nil }
            let artistID = first.artistID ?? UInt64(bitPattern: Int64(first.artist.hashValue))
            let albumCount = Set(group.map { $0.albumID ?? UInt64(bitPattern: Int64("\($0.artist)\($0.album)".hashValue)) }).count
            return SystemArtist(
                id: artistID,
                name: first.artist,
                albumCount: albumCount,
                songCount: group.count,
                normalizedSearchTerms: [normalizeSearchText(first.artist)]
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let albumGroups = Dictionary(grouping: songs) { song in
            "\(song.albumID.map(String.init) ?? "name:\(song.artist):\(song.album)")"
        }
        let albums = albumGroups.values.compactMap { group -> SystemAlbum? in
            guard !Task.isCancelled else { return nil }
            guard let first = group.first else { return nil }
            let albumID = first.albumID ?? UInt64(bitPattern: Int64("\(first.artist)\(first.album)".hashValue))
            return SystemAlbum(
                id: albumID,
                title: first.album,
                artist: first.artist,
                songCount: group.count,
                normalizedSearchTerms: [
                    normalizeSearchText(first.album),
                    normalizeSearchText(first.artist),
                    normalizeSearchText("\(first.artist) \(first.album)")
                ]
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        try Task.checkCancellation()
        return SystemLibrarySnapshot(songs: songs, artists: artists, albums: albums)
    }

    nonisolated private static func buildDetailedSystemLibrarySnapshot(
        using library: SystemMediaLibrary,
        songs: [SystemSong]
    ) throws -> SystemLibrarySnapshot {
        try Task.checkCancellation()
        let artists = library.fetchArtists().map { artist in
            var normalizedArtist = artist
            normalizedArtist.normalizedSearchTerms = [normalizeSearchText(artist.name)]
            return normalizedArtist
        }

        try Task.checkCancellation()
        let albums = library.fetchAlbums().map { album in
            var normalizedAlbum = album
            normalizedAlbum.normalizedSearchTerms = [
                normalizeSearchText(album.title),
                normalizeSearchText(album.artist),
                normalizeSearchText("\(album.artist) \(album.title)")
            ]
            return normalizedAlbum
        }

        try Task.checkCancellation()
        return SystemLibrarySnapshot(songs: songs, artists: artists, albums: albums)
    }

    nonisolated private static func mergedSystemLibrarySnapshot(
        base: SystemLibrarySnapshot,
        with localTracks: [LocalTrackMetadata]
    ) -> SystemLibrarySnapshot {
        var songs = base.songs
        var artists = base.artists
        var albums = base.albums

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
                ]
            )

            if !songs.contains(where: { $0.id == localID }) {
                songs.append(newSong)
            }

            if !artists.contains(where: { $0.name == track.artist }) {
                let artistID = UInt64(bitPattern: Int64(track.artist.hashValue)) | 0x8000000000000000
                artists.append(
                    SystemArtist(
                        id: artistID,
                        name: track.artist,
                        albumCount: 1,
                        songCount: 1,
                        normalizedSearchTerms: [normalizeSearchText(track.artist)]
                    )
                )
            }

            if !albums.contains(where: { $0.title == track.album && $0.artist == track.artist }) {
                let albumID = UInt64(bitPattern: Int64("\(track.artist)\(track.album)".hashValue)) | 0x8000000000000000
                albums.append(
                    SystemAlbum(
                        id: albumID,
                        title: track.album,
                        artist: track.artist,
                        songCount: 1,
                        normalizedSearchTerms: [normalizeSearchText(track.album), normalizeSearchText(track.artist)]
                    )
                )
            }
        }

        return SystemLibrarySnapshot(songs: songs, artists: artists, albums: albums)
    }

    private func applySystemLibrarySnapshot(
        _ snapshot: SystemLibrarySnapshot,
        restorePlayback: Bool,
        isFinal: Bool
    ) {
        // Library publishing is intentionally independent from the audio
        // pipeline. Avoid a large array publish during an active transition or
        // render; apply the latest snapshot on the next idle tick instead.
        if isPlaybackBusyForLibraryWork || hasResidentLocalPlaybackTrack {
            deferredLibrarySnapshot = snapshot
            if isFinal {
                isLibraryBootstrapInProgress = false
            }
            return
        }

        applyLibrarySnapshotToPublishedState(snapshot)
        if isFinal {
            isLibraryBootstrapInProgress = false
        }

        if restorePlayback {
            restorePlaybackIfNeeded()
        }
    }

    private func applyLibrarySnapshotToPublishedState(_ snapshot: SystemLibrarySnapshot) {
        systemSongs = snapshot.songs
        systemArtists = snapshot.artists
        systemAlbums = snapshot.albums
        filteredSystemSongs = snapshot.songs
        filteredSystemArtists = snapshot.artists
        filteredSystemAlbums = snapshot.albums
    }

    private func flushDeferredLibrarySnapshotIfPlaybackIsIdle() {
        guard !isPlaybackBusyForLibraryWork,
              !hasResidentLocalPlaybackTrack,
              let snapshot = deferredLibrarySnapshot else { return }
        deferredLibrarySnapshot = nil
        applyLibrarySnapshotToPublishedState(snapshot)
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

        if systemLibraryRefreshTask != nil {
            systemLibraryRefreshGeneration &+= 1
            systemLibraryRefreshTask?.cancel()
            systemLibraryRefreshTask = nil
        }
        if localLibraryScanTask != nil {
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

private extension SystemArtist {
    var isLocalLibraryIdentifier: Bool {
        (id & (UInt64(1) << 63)) != 0
    }
}

private extension SystemAlbum {
    var isLocalLibraryIdentifier: Bool {
        (id & (UInt64(1) << 63)) != 0
    }
}
