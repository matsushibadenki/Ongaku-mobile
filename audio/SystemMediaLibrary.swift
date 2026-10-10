//
//  SystemMediaLibrary.swift
//  audio
//
//  2026/04/04.
//

import Foundation
import MediaPlayer
import MusicKit
import UIKit

struct SystemMediaLibrary {
    func currentAccessState() -> MediaLibraryAccessState {
        switch MPMediaLibrary.authorizationStatus() {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorized:
            return .authorized
        @unknown default:
            return .restricted
        }
    }

    func requestAccess() async -> MediaLibraryAccessState {
        let status = await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        switch status {
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .authorized:
            return .authorized
        @unknown default:
            return .restricted
        }
    }

    func currentCloudServiceAuthorizationStatus() -> MusicAuthorization.Status {
        MusicAuthorization.currentStatus
    }

    func requestCloudServiceAuthorization() async -> MusicAuthorization.Status {
        await MusicAuthorization.request()
    }

    nonisolated func fetchSongs() throws -> [SystemSong] {
        let query = MPMediaQuery.songs()
        guard let items = query.items else {
            throw NSError(domain: "Ongaku.MediaLibrary", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Music library query unavailable"])
        }

        return items.compactMap { item in
            guard !Task.isCancelled else { return nil }
            return SystemSong(
                id: UInt64(item.persistentID),
                title: item.title ?? L10n.unknownTitle(),
                artist: item.artist ?? L10n.unknownArtist(),
                album: item.albumTitle ?? L10n.unknownAlbum(),
                artistID: item.artistPersistentID == 0 ? nil : UInt64(item.artistPersistentID),
                albumID: item.albumPersistentID == 0 ? nil : UInt64(item.albumPersistentID),
                discNumber: item.discNumber > 0 ? item.discNumber : nil,
                trackNumber: item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
                duration: item.playbackDuration,
                url: nil,
                albumArtist: item.albumArtist
            )
        }
    }

    func fetchPlaylists() -> [SystemPlaylist] {
        let query = MPMediaQuery.playlists()
        let collections = query.collections ?? []

        return collections.compactMap { collection in
            guard let playlist = collection as? MPMediaPlaylist else { return nil }
            return SystemPlaylist(
                id: UInt64(playlist.persistentID),
                name: playlist.name ?? L10n.untitledPlaylist(),
                songCount: playlist.count
            )
        }
    }

    func songs(in playlist: SystemPlaylist) -> [SystemSong] {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: playlist.id),
            forProperty: MPMediaPlaylistPropertyPersistentID
        )
        let query = MPMediaQuery.playlists()
        query.addFilterPredicate(predicate)
        let items = query.collections?.first?.items ?? []

        return items.map { item in
            SystemSong(
                id: UInt64(item.persistentID),
                title: item.title ?? L10n.unknownTitle(),
                artist: item.artist ?? L10n.unknownArtist(),
                album: item.albumTitle ?? L10n.unknownAlbum(),
                artistID: item.artistPersistentID == 0 ? nil : UInt64(item.artistPersistentID),
                albumID: item.albumPersistentID == 0 ? nil : UInt64(item.albumPersistentID),
                discNumber: item.discNumber > 0 ? item.discNumber : nil,
                trackNumber: item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
                duration: item.playbackDuration,
                url: nil,
                albumArtist: item.albumArtist
            )
        }
    }

    func mediaItem(for songID: UInt64) -> MPMediaItem? {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: songID),
            forProperty: MPMediaItemPropertyPersistentID
        )
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(predicate)
        return query.items?.first
    }

    func mediaItems(for songIDs: [UInt64]) -> [MPMediaItem] {
        guard !songIDs.isEmpty else { return [] }
        // One library query, not one synchronous daemon round-trip per song.
        let requested = Set(songIDs)
        let items = MPMediaQuery.songs().items ?? []
        var byID: [UInt64: MPMediaItem] = [:]
        for item in items where requested.contains(UInt64(item.persistentID)) {
            byID[UInt64(item.persistentID)] = item
        }
        return songIDs.compactMap { byID[$0] }
    }

    func artwork(for album: SystemAlbum, size: CGSize) -> UIImage? {
        let predicate = MPMediaPropertyPredicate(
            value: NSNumber(value: album.id),
            forProperty: MPMediaItemPropertyAlbumPersistentID
        )
        let query = MPMediaQuery.albums()
        query.addFilterPredicate(predicate)
        return query.items?.first?.artwork?.image(at: size)
    }
    
    func artwork(for songID: UInt64, size: CGSize) -> UIImage? {
        return mediaItem(for: songID)?.artwork?.image(at: size)
    }
    
    func artworkForArtist(id: UInt64, name: String, size: CGSize) -> UIImage? {
        // アーティストIDまたは名前から検索
        let idPredicate = MPMediaPropertyPredicate(
            value: NSNumber(value: id),
            forProperty: MPMediaItemPropertyArtistPersistentID
        )
        let query = MPMediaQuery.artists()
        query.addFilterPredicate(idPredicate)
        
        if let item = query.items?.first, item.artist == name, let artwork = item.artwork {
            return artwork.image(at: size)
        }
        
        // IDで見つからない場合は名前で試行
        let namePredicate = MPMediaPropertyPredicate(
            value: name,
            forProperty: MPMediaItemPropertyArtist,
            comparisonType: .equalTo
        )
        let nameQuery = MPMediaQuery.artists()
        nameQuery.addFilterPredicate(namePredicate)
        return nameQuery.items?.first?.artwork?.image(at: size)
    }
}
