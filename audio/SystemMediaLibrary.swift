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

    nonisolated func fetchSongs() -> [SystemSong] {
        let query = MPMediaQuery.songs()
        let items = query.items ?? []

        return items.compactMap { item in
            guard !Task.isCancelled else { return nil }
            return SystemSong(
                id: UInt64(item.persistentID),
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
        }
    }

    nonisolated func fetchArtists() -> [SystemArtist] {
        let query = MPMediaQuery.artists()
        let collections = query.collections ?? []
        struct ArtistAccumulator {
            var id: UInt64
            var name: String
            var albumIDs: Set<UInt64>
            var songCount: Int
        }

        var groupedArtists: [String: ArtistAccumulator] = [:]
        var orderedKeys: [String] = []

        for collection in collections {
            guard !Task.isCancelled else { break }
            guard let representative = collection.representativeItem else { continue }

            let artistName = representative.albumArtist ?? representative.artist ?? L10n.unknownArtist()
            let artistID = representative.albumArtistPersistentID != 0
                ? UInt64(representative.albumArtistPersistentID)
                : UInt64(representative.artistPersistentID)
            let groupingKey = artistID == 0
                ? "name:\(artistName.lowercased())"
                : "id:\(artistID)"
            let albumIDs = Set(
                collection.items.compactMap { item in
                    item.albumPersistentID == 0 ? nil : UInt64(item.albumPersistentID)
                }
            )

            if var existing = groupedArtists[groupingKey] {
                existing.albumIDs.formUnion(albumIDs)
                existing.songCount += collection.count
                groupedArtists[groupingKey] = existing
            } else {
                orderedKeys.append(groupingKey)
                groupedArtists[groupingKey] = ArtistAccumulator(
                    id: artistID == 0 ? UInt64(bitPattern: Int64(artistName.hashValue)) : artistID,
                    name: artistName,
                    albumIDs: albumIDs,
                    songCount: collection.count
                )
            }
        }

        return orderedKeys.compactMap { key in
            guard !Task.isCancelled else { return nil }
            guard let artist = groupedArtists[key] else { return nil }
            return SystemArtist(
                id: artist.id,
                name: artist.name,
                albumCount: artist.albumIDs.count,
                songCount: artist.songCount
            )
        }
    }

    nonisolated func fetchAlbums() -> [SystemAlbum] {
        let query = MPMediaQuery.albums()
        let collections = query.collections ?? []

        return collections.compactMap { collection in
            guard !Task.isCancelled else { return nil }
            guard let representative = collection.representativeItem else { return nil }
            return SystemAlbum(
                id: UInt64(representative.albumPersistentID),
                title: representative.albumTitle ?? L10n.unknownAlbum(),
                artist: representative.albumArtist ?? representative.artist ?? L10n.unknownArtist(),
                songCount: collection.count
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
                artistID: item.albumArtistPersistentID == 0 ? nil : UInt64(item.albumArtistPersistentID),
                albumID: item.albumPersistentID == 0 ? nil : UInt64(item.albumPersistentID),
                discNumber: item.discNumber > 0 ? item.discNumber : nil,
                trackNumber: item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
                duration: item.playbackDuration,
                url: nil
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
        songIDs.compactMap { mediaItem(for: $0) }
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
        
        if let item = query.items?.first, let artwork = item.artwork {
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
