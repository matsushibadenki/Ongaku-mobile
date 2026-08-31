//
//  AppLibraryModels.swift
//  audio
//
//  2026/04/04.
//

import Foundation

nonisolated struct PlaybackSnapshot: Codable, Hashable, Sendable {
    var selectedSongID: UInt64
    var queueSongIDs: [UInt64]
    var queueIndex: Int
    var queueTitle: String?
}

nonisolated struct AppLibraryState: Codable, Sendable {
    var playback: PlaybackSnapshot?
    var effectSettings: [StoredEffectSetting]
    var headphoneSpatialSettings: HeadphoneSpatialSettings
    var upsamplingMode: UpsamplingMode
    var automaticDSPStrength: Double
    var automaticDSPVoicing: AutomaticDSPVoicing

    static let empty = AppLibraryState(
        playback: nil,
        effectSettings: [],
        headphoneSpatialSettings: .default,
        upsamplingMode: .avAudioConverter,
        automaticDSPStrength: 1.0,
        automaticDSPVoicing: .natural
    )

    init(
        playback: PlaybackSnapshot?,
        effectSettings: [StoredEffectSetting],
        headphoneSpatialSettings: HeadphoneSpatialSettings,
        upsamplingMode: UpsamplingMode,
        automaticDSPStrength: Double,
        automaticDSPVoicing: AutomaticDSPVoicing = .natural
    ) {
        self.playback = playback
        self.effectSettings = effectSettings
        self.headphoneSpatialSettings = headphoneSpatialSettings
        self.upsamplingMode = upsamplingMode
        self.automaticDSPStrength = automaticDSPStrength
        self.automaticDSPVoicing = automaticDSPVoicing
    }

    private enum CodingKeys: String, CodingKey {
        case playback
        case effectSettings
        case headphoneSpatialSettings
        case upsamplingMode
        case automaticDSPStrength
        case automaticDSPVoicing
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        playback = try container.decodeIfPresent(PlaybackSnapshot.self, forKey: .playback)
        effectSettings = try container.decodeIfPresent([StoredEffectSetting].self, forKey: .effectSettings) ?? []
        headphoneSpatialSettings = try container.decodeIfPresent(HeadphoneSpatialSettings.self, forKey: .headphoneSpatialSettings) ?? .default
        upsamplingMode = try container.decodeIfPresent(UpsamplingMode.self, forKey: .upsamplingMode) ?? .avAudioConverter
        automaticDSPStrength = min(max(try container.decodeIfPresent(Double.self, forKey: .automaticDSPStrength) ?? 1.0, 0.0), 1.5)
        automaticDSPVoicing = try container.decodeIfPresent(AutomaticDSPVoicing.self, forKey: .automaticDSPVoicing) ?? .natural
    }
}

nonisolated enum AutomaticDSPVoicing: String, Codable, CaseIterable, Hashable, Sendable {
    case natural
    case reference
    case immersive
    case safe
}

nonisolated enum UpsamplingMode: String, Codable, CaseIterable, Hashable, Sendable {
    case avAudioConverter
    case precisionSincLinearEco
    case precisionSincLinear
    case precisionSincLinearMaster
    case precisionSincMinimumPhaseEco
    case precisionSincMinimumPhase
    case precisionSincMinimumPhaseMaster
    case precisionSincApodizingEco
    case precisionSincApodizing
    case precisionSincApodizingMaster

    // Legacy value kept for older saved library state. It is decoded as
    // precisionSincApodizing and intentionally hidden from allCases.
    case precisionSinc

    static var allCases: [UpsamplingMode] {
        [
            .avAudioConverter,
            .precisionSincLinearEco,
            .precisionSincLinear,
            .precisionSincLinearMaster,
            .precisionSincMinimumPhaseEco,
            .precisionSincMinimumPhase,
            .precisionSincMinimumPhaseMaster,
            .precisionSincApodizingEco,
            .precisionSincApodizing,
            .precisionSincApodizingMaster
        ]
    }

    nonisolated var isPrecisionSinc: Bool {
        self != .avAudioConverter
    }

    nonisolated var precisionSincPhaseMode: PrecisionSincPhaseMode? {
        switch self {
        case .avAudioConverter:
            return nil
        case .precisionSincLinearEco, .precisionSincLinear, .precisionSincLinearMaster:
            return .linear
        case .precisionSincMinimumPhaseEco, .precisionSincMinimumPhase, .precisionSincMinimumPhaseMaster:
            return .minimumPhase
        case .precisionSincApodizingEco, .precisionSincApodizing, .precisionSincApodizingMaster, .precisionSinc:
            return .apodizing
        }
    }

    nonisolated var precisionSincQualityMode: PrecisionSincQualityMode? {
        switch self {
        case .avAudioConverter:
            return nil
        case .precisionSincLinearEco, .precisionSincMinimumPhaseEco, .precisionSincApodizingEco:
            return .eco
        case .precisionSincLinear, .precisionSincMinimumPhase, .precisionSincApodizing, .precisionSinc:
            return .standard
        case .precisionSincLinearMaster, .precisionSincMinimumPhaseMaster, .precisionSincApodizingMaster:
            return .master
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.avAudioConverter.rawValue:
            self = .avAudioConverter
        case Self.precisionSincLinearEco.rawValue:
            self = .precisionSincLinearEco
        case Self.precisionSincLinear.rawValue:
            self = .precisionSincLinear
        case Self.precisionSincLinearMaster.rawValue:
            self = .precisionSincLinearMaster
        case Self.precisionSincMinimumPhaseEco.rawValue:
            self = .precisionSincMinimumPhaseEco
        case Self.precisionSincMinimumPhase.rawValue:
            self = .precisionSincMinimumPhase
        case Self.precisionSincMinimumPhaseMaster.rawValue:
            self = .precisionSincMinimumPhaseMaster
        case Self.precisionSincApodizingEco.rawValue:
            self = .precisionSincApodizingEco
        case Self.precisionSincApodizing.rawValue, Self.precisionSinc.rawValue:
            self = .precisionSincApodizing
        case Self.precisionSincApodizingMaster.rawValue:
            self = .precisionSincApodizingMaster
        default:
            self = .avAudioConverter
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

nonisolated enum PrecisionSincPhaseMode: String, Hashable, Sendable {
    case linear
    case minimumPhase
    case apodizing
}

nonisolated enum PrecisionSincQualityMode: String, Hashable, Sendable {
    case eco
    case standard
    case master
}

nonisolated struct StoredEffectSetting: Codable, Hashable, Sendable {
    var kind: String
    var isEnabled: Bool
    var parameters: [String: Double]
}

nonisolated enum LibraryTrackSource: String, Codable, Hashable, Sendable {
    case systemMusic
    case ongakuManaged

    var localizedName: String {
        switch self {
        case .systemMusic:
            return L10n.tr("library.source.music")
        case .ongakuManaged:
            return L10n.tr("library.source.ongaku")
        }
    }

    var systemImageName: String {
        switch self {
        case .systemMusic:
            return "music.note"
        case .ongakuManaged:
            return "waveform.badge.plus"
        }
    }
}

nonisolated enum LibraryTrackCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case browse
    case play
    case addToPlaylist
    case metadataOverlay
    case editEmbeddedMetadata
    case exportAudio
    case deleteAudio
    case syncWithMac

    var localizedName: String {
        L10n.tr("library.capability.\(rawValue)")
    }

    var systemImageName: String {
        switch self {
        case .browse: return "rectangle.grid.1x2"
        case .play: return "play.fill"
        case .addToPlaylist: return "text.badge.plus"
        case .metadataOverlay: return "tag"
        case .editEmbeddedMetadata: return "pencil"
        case .exportAudio: return "square.and.arrow.up"
        case .deleteAudio: return "trash"
        case .syncWithMac: return "laptopcomputer.and.iphone"
        }
    }
}

nonisolated struct LibraryTrackOverlay: Codable, Hashable, Sendable {
    let trackKey: String
    var isFavorite: Bool
    var rating: Int
    var playCount: Int
    var skipCount: Int
    var lastPlayedAt: Date?
    var displayTags: [String]
    var updatedAt: Date

    static func empty(for song: SystemSong) -> LibraryTrackOverlay {
        LibraryTrackOverlay(
            trackKey: song.overlayKey,
            isFavorite: false,
            rating: 0,
            playCount: 0,
            skipCount: 0,
            lastPlayedAt: nil,
            displayTags: [],
            updatedAt: .now
        )
    }

    mutating func normalize() {
        rating = min(max(rating, 0), 5)
        playCount = max(playCount, 0)
        skipCount = max(skipCount, 0)
        var seen: Set<String> = []
        displayTags = displayTags.compactMap { value in
            let tag = String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(24))
            guard !tag.isEmpty else { return nil }
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard seen.insert(key).inserted else { return nil }
            return tag
        }
        displayTags = Array(displayTags.prefix(12))
    }

    private enum CodingKeys: String, CodingKey {
        case trackKey, isFavorite, rating, playCount, skipCount, lastPlayedAt, displayTags, updatedAt
    }

    init(
        trackKey: String,
        isFavorite: Bool,
        rating: Int,
        playCount: Int,
        skipCount: Int,
        lastPlayedAt: Date?,
        displayTags: [String],
        updatedAt: Date
    ) {
        self.trackKey = trackKey
        self.isFavorite = isFavorite
        self.rating = rating
        self.playCount = playCount
        self.skipCount = skipCount
        self.lastPlayedAt = lastPlayedAt
        self.displayTags = displayTags
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackKey = try container.decode(String.self, forKey: .trackKey)
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        rating = try container.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        playCount = try container.decodeIfPresent(Int.self, forKey: .playCount) ?? 0
        skipCount = try container.decodeIfPresent(Int.self, forKey: .skipCount) ?? 0
        lastPlayedAt = try container.decodeIfPresent(Date.self, forKey: .lastPlayedAt)
        displayTags = try container.decodeIfPresent([String].self, forKey: .displayTags) ?? []
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
        normalize()
    }
}

nonisolated struct OngakuPlaylist: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var trackKeys: [String]
    var createdAt: Date
    var updatedAt: Date

    mutating func normalize() {
        name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        var seen: Set<String> = []
        trackKeys = trackKeys.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

nonisolated enum HeadphoneHRTFPreset: String, Codable, CaseIterable, Hashable, Sendable {
    case natural
    case frontal
    case wide
    case studio
}

nonisolated struct HeadphoneSpatialSettings: Codable, Hashable, Sendable {
    var isEnabled: Bool
    var preset: HeadphoneHRTFPreset
    var spatial: Double
    var crossfeed: Double

    static let `default` = HeadphoneSpatialSettings(isEnabled: true, preset: .natural, spatial: 0.94, crossfeed: 0.80)

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case preset
        case spatial
        case crossfeed
    }

    init(isEnabled: Bool, preset: HeadphoneHRTFPreset, spatial: Double, crossfeed: Double) {
        self.isEnabled = isEnabled
        self.preset = preset
        self.spatial = spatial
        self.crossfeed = crossfeed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? Self.default.isEnabled
        preset = try container.decodeIfPresent(HeadphoneHRTFPreset.self, forKey: .preset) ?? Self.default.preset
        spatial = try container.decodeIfPresent(Double.self, forKey: .spatial) ?? Self.default.spatial
        crossfeed = try container.decodeIfPresent(Double.self, forKey: .crossfeed) ?? Self.default.crossfeed
    }
}

nonisolated struct SystemSong: Identifiable, Hashable, Codable, Sendable {
    let id: UInt64
    let title: String
    let artist: String
    let album: String
    let artistID: UInt64?
    let albumID: UInt64?
    let discNumber: Int?
    let trackNumber: Int?
    let duration: TimeInterval
    let url: URL? // ローカルファイルの場合にパスを保持
    var normalizedSearchTerms: [String] = []
    nonisolated func getNormalizedSearchTerms() -> [String] { normalizedSearchTerms }

    var source: LibraryTrackSource {
        url == nil ? .systemMusic : .ongakuManaged
    }

    var overlayKey: String {
        "\(source.rawValue):\(id)"
    }

    var capabilities: Set<LibraryTrackCapability> {
        switch source {
        case .systemMusic:
            return [.browse, .play, .addToPlaylist, .metadataOverlay]
        case .ongakuManaged:
            return Set(LibraryTrackCapability.allCases)
        }
    }

    func supports(_ capability: LibraryTrackCapability) -> Bool {
        capabilities.contains(capability)
    }
}

nonisolated struct SystemArtist: Identifiable, Hashable, Codable, Sendable {
    let id: UInt64
    let name: String
    let albumCount: Int
    let songCount: Int
    var normalizedSearchTerms: [String] = []
    nonisolated func getNormalizedSearchTerms() -> [String] { normalizedSearchTerms }
}

nonisolated struct SystemAlbum: Identifiable, Hashable, Codable, Sendable {
    let id: UInt64
    let title: String
    let artist: String
    let songCount: Int
    var normalizedSearchTerms: [String] = []
    nonisolated func getNormalizedSearchTerms() -> [String] { normalizedSearchTerms }
}

struct SystemPlaylist: Identifiable, Hashable, Codable, Sendable {
    let id: UInt64
    let name: String
    let songCount: Int
    var normalizedSearchTerms: [String] = []
    nonisolated func getNormalizedSearchTerms() -> [String] { normalizedSearchTerms }
}

struct AppleMusicCatalogSongResult: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artistName: String
    let artworkURL: URL?
}

struct AppleMusicCatalogAlbumResult: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artistName: String
    let trackCount: Int?
    let artworkURL: URL?
}

protocol SearchableItem: Sendable {
    nonisolated func getNormalizedSearchTerms() -> [String]
}

extension SystemSong: SearchableItem {}
extension SystemArtist: SearchableItem {}
extension SystemAlbum: SearchableItem {}
extension SystemPlaylist: SearchableItem {}

enum MediaLibraryAccessState: String {
    case notDetermined
    case denied
    case restricted
    case authorized

    var description: String {
        switch self {
        case .notDetermined:
            return L10n.tr("media_access.not_determined")
        case .denied:
            return L10n.tr("media_access.denied")
        case .restricted:
            return L10n.tr("media_access.restricted")
        case .authorized:
            return L10n.tr("media_access.authorized")
        }
    }
}
