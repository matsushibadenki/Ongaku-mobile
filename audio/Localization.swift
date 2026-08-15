//
//  Localization.swift
//  audio
//
//  2026/04/08.
//

import Foundation

enum L10n {
    nonisolated static func tr(_ key: String) -> String {
        NSLocalizedString(key, comment: "")
    }

    nonisolated static func tr(_ key: String, _ arguments: CVarArg...) -> String {
        let format = NSLocalizedString(key, comment: "")
        return String(format: format, locale: Locale.current, arguments: arguments)
    }

    nonisolated static func songCount(_ count: Int) -> String {
        tr("count.songs", count)
    }

    nonisolated static func albumCount(_ count: Int) -> String {
        tr("count.albums", count)
    }

    nonisolated static func albumAndSongCount(albums: Int, songs: Int) -> String {
        tr("count.albums_songs", albums, songs)
    }

    nonisolated static func dspBadgeSingle(_ name: String) -> String {
        tr("effects.badge.single", name)
    }

    nonisolated static func dspBadgeMultiple(_ count: Int) -> String {
        tr("effects.badge.multiple", count)
    }

    nonisolated static func headphoneSpatialName() -> String {
        tr("effects.headphone_spatial.name")
    }

    nonisolated static func searchSummary(total: Int, playlists: Int, artists: Int, albums: Int, songs: Int) -> String {
        tr("search.summary.results", total, playlists, artists, albums, songs)
    }

    nonisolated static func queueShuffleTitle(_ album: String) -> String {
        tr("queue.shuffle.album", album)
    }

    nonisolated static func playbackFormatUnavailable() -> String {
        tr("playback.format.unavailable")
    }

    nonisolated static func playbackFormatProtected() -> String {
        tr("playback.format.protected")
    }

    nonisolated static func upsamplingModeTitle(_ mode: UpsamplingMode) -> String {
        switch mode {
        case .avAudioConverter:
            return tr("upsampling.mode.avconverter")
        case .precisionSincLinearEco:
            return tr("upsampling.mode.sinc.linear.eco")
        case .precisionSincLinear:
            return tr("upsampling.mode.sinc.linear")
        case .precisionSincLinearMaster:
            return tr("upsampling.mode.sinc.linear.master")
        case .precisionSincMinimumPhaseEco:
            return tr("upsampling.mode.sinc.minimum.eco")
        case .precisionSincMinimumPhase:
            return tr("upsampling.mode.sinc.minimum")
        case .precisionSincMinimumPhaseMaster:
            return tr("upsampling.mode.sinc.minimum.master")
        case .precisionSincApodizingEco:
            return tr("upsampling.mode.sinc.apodizing.eco")
        case .precisionSincApodizing, .precisionSinc:
            return tr("upsampling.mode.sinc.apodizing")
        case .precisionSincApodizingMaster:
            return tr("upsampling.mode.sinc.apodizing.master")
        }
    }

    nonisolated static func unknownTitle() -> String {
        tr("media.unknown_title")
    }

    nonisolated static func unknownArtist() -> String {
        tr("media.unknown_artist")
    }

    nonisolated static func unknownAlbum() -> String {
        tr("media.unknown_album")
    }

    nonisolated static func untitledPlaylist() -> String {
        tr("media.untitled_playlist")
    }

    nonisolated static func joinedMetadata(_ parts: [String]) -> String {
        parts.filter { !$0.isEmpty }.joined(separator: tr("separator.dot"))
    }
}
