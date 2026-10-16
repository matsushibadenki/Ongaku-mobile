import Foundation

/// Derive navigation from the songs themselves. Apple persistent IDs occupy
/// the entire UInt64 range; no bit can identify an Ongaku-owned item.
nonisolated struct SystemLibraryIndex {
    let artists: [SystemArtist]
    let albums: [SystemAlbum]

    init(songs: [SystemSong], normalize: (String) -> String = { $0 }) {
        let artistGroups = Dictionary(grouping: songs, by: \.artist)
        var usedArtistIDs = Set<UInt64>()
        // Legacy caches used album-artist IDs for track artists, so two names
        // can share an ID. Keep both names and allocate a distinct row identity.
        let reservedIDs = Set(songs.compactMap(\.artistID))
        artists = artistGroups.keys.sorted().compactMap { name in
            guard let group = artistGroups[name] else { return nil }
            let persistentID = group.compactMap(\.artistID).min()
            var id = persistentID ?? Self.stableID("artist:" + name)
            if usedArtistIDs.contains(id) || (persistentID == nil && reservedIDs.contains(id)) {
                id = Self.stableID("artist:" + name)
                while usedArtistIDs.contains(id) || reservedIDs.contains(id) { id &+= 1 }
            }
            usedArtistIDs.insert(id)
            return SystemArtist(
                id: id, name: name,
                albumCount: Set(group.map(Self.albumKey)).count,
                songCount: group.count,
                normalizedSearchTerms: [normalize(name)]
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let albumGroups = Dictionary(grouping: songs, by: Self.albumKey)
        var usedAlbumIDs = Set(songs.compactMap(\.albumID))
        albums = albumGroups.keys.sorted().compactMap { key in
            guard let group = albumGroups[key], let first = group.first else { return nil }
            let id: UInt64
            if let albumID = first.albumID {
                id = albumID
            } else {
                var generated = Self.stableID(key)
                while usedAlbumIDs.contains(generated) { generated &+= 1 }
                usedAlbumIDs.insert(generated)
                id = generated
            }
            let albumArtists = Set(group.compactMap(\.albumArtist).filter { !$0.isEmpty })
            let performers = Set(group.map(\.artist))
            let artist = albumArtists.count == 1 ? albumArtists.first! :
                (performers.count == 1 ? first.artist : L10n.tr("library.various_artists"))
            return SystemAlbum(
                id: id, title: first.album, artist: artist, songCount: group.count,
                localIdentity: first.url?.isFileURL == true ? key : nil,
                normalizedSearchTerms: [normalize(first.album), normalize(artist), normalize("\(artist) \(first.album)")]
            )
        }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func contains(_ song: SystemSong, artist: SystemArtist) -> Bool {
        // Names and IDs must describe the same entity. This also repairs
        // navigation for caches written with albumArtistPersistentID.
        song.artist == artist.name
    }

    static func contains(_ song: SystemSong, album: SystemAlbum) -> Bool {
        if let identity = album.localIdentity { return albumKey(song) == identity }
        if let id = song.albumID { return id == album.id }
        if song.url?.isFileURL == true { return stableID(albumKey(song)) == album.id }
        return song.album == album.title && (song.albumArtist ?? song.artist) == album.artist
    }

    /// Keep album navigation available while a library refresh is deferred.
    /// The fallback uses the same identity and album artist as the index.
    static func album(for song: SystemSong, in albums: [SystemAlbum]) -> SystemAlbum {
        if let match = albums.first(where: { contains(song, album: $0) }) { return match }
        return SystemAlbum(
            id: song.albumID ?? stableID(albumKey(song)),
            title: song.album, artist: song.albumArtist ?? song.artist, songCount: 1,
            localIdentity: song.url?.isFileURL == true ? albumKey(song) : nil
        )
    }

    static func acceptsSearchResult(query: String, currentQuery: String,
                                    revision: UInt64, currentRevision: UInt64,
                                    request: UInt64, currentRequest: UInt64) -> Bool {
        query == currentQuery && revision == currentRevision && request == currentRequest
    }

    private static func albumKey(_ song: SystemSong) -> String {
        if let id = song.albumID { return "id:\(id)" }
        if let url = song.url, url.isFileURL {
            let folder = LocalAlbumFiles.albumDirectory(for: url).path
            return "local:\(folder.utf8.count):\(folder):\(song.album)"
        }
        let artist = song.albumArtist ?? song.artist
        return "name:\(artist.utf8.count):\(artist):\(song.album)"
    }

    private static func stableID(_ value: String) -> UInt64 {
        value.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    }

    static func orderedAlbumSongs(_ songs: [SystemSong]) -> [SystemSong] {
        guard songs.contains(where: { $0.url?.isFileURL == true || ($0.trackNumber ?? 0) > 0 || ($0.discNumber ?? 0) > 0 }) else { return songs }
        return songs.sorted { lhs, rhs in
            let ld = (lhs.discNumber ?? 0) > 0 ? lhs.discNumber! : 1
            let rd = (rhs.discNumber ?? 0) > 0 ? rhs.discNumber! : 1
            if ld != rd { return ld < rd }
            let lt = (lhs.trackNumber ?? 0) > 0 ? lhs.trackNumber! : Int.max
            let rt = (rhs.trackNumber ?? 0) > 0 ? rhs.trackNumber! : Int.max
            if lt != rt { return lt < rt }
            if let lu = lhs.url, let ru = rhs.url {
                let order = lu.lastPathComponent.localizedStandardCompare(ru.lastPathComponent)
                if order != .orderedSame { return order == .orderedAscending }
            }
            let order = lhs.title.localizedStandardCompare(rhs.title)
            return order == .orderedSame ? lhs.id < rhs.id : order == .orderedAscending
        }
    }
}
