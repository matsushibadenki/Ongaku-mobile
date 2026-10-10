import Foundation

// The standalone audit uses the shipping models, cache decoder and index.
enum L10n { static func tr(_ key: String) -> String { key } }

@main
struct LibraryIndexRegression {
    static func song(_ id: UInt64, _ artist: String, artistID: UInt64? = nil,
                     albumID: UInt64? = nil, local: Bool = false,
                     album: String = "Album", albumArtist: String? = nil) -> SystemSong {
        SystemSong(id: id, title: "Track \(id)", artist: artist, album: album,
                   artistID: artistID, albumID: albumID, discNumber: nil,
                   trackNumber: nil, duration: 120,
                   url: local ? URL(fileURLWithPath: "/music/\(id).flac") : nil,
                   albumArtist: albumArtist)
    }

    static func main() throws {
        let high = UInt64(1) << 63
        let tracks = [song(1, "High ID", artistID: high + 17, albumID: UInt64.max),
                      song(2, "Low ID", artistID: 17, albumID: 24)]
        let index = SystemLibraryIndex(songs: tracks)
        precondition(index.artists.count == 2 && index.albums.count == 2)
        precondition(index.artists.contains { $0.id == high + 17 })
        precondition(index.albums.contains { $0.id == UInt64.max })
        print("PASS: full-width Apple artist and album IDs remain visible")

        // Reproduce a cache whose song list survived but whose high-bit rows
        // were stripped by the old implementation.
        let damagedCache = CachedSystemLibrarySnapshot(songs: tracks, artists: [], albums: [])
        let encoded = try JSONEncoder().encode(damagedCache)
        let decoded = try JSONDecoder().decode(CachedSystemLibrarySnapshot.self, from: encoded)
        let repaired = SystemLibraryIndex(songs: decoded.songs.filter { $0.url == nil })
        precondition(repaired.artists.count == 2 && repaired.albums.count == 2)
        print("PASS: damaged derived cache indexes recover from retained songs")

        let compilation = [
            song(3, "Performer A", artistID: high, albumID: 30, albumArtist: "Various Artists"),
            song(4, "Performer B", artistID: high, albumID: 30, albumArtist: "Various Artists")
        ]
        let compilationIndex = SystemLibraryIndex(songs: compilation)
        precondition(compilationIndex.artists.count == 2)
        precondition(Set(compilationIndex.artists.map(\.id)).count == 2)
        for artist in compilationIndex.artists {
            precondition(compilation.filter { SystemLibraryIndex.contains($0, artist: artist) }.count == 1)
        }
        precondition(compilationIndex.albums.count == 1)
        precondition(compilationIndex.albums[0].artist == "Various Artists")
        precondition(compilationIndex.albums[0].songCount == 2)
        print("PASS: compilation performers stay distinct even with legacy shared artist IDs")

        let mixed = tracks + [song(5, "High ID", local: true, album: "Local Album"),
                              song(6, "Local Only", local: true)]
        let mixedIndex = SystemLibraryIndex(songs: mixed)
        let shared = mixedIndex.artists.first { $0.name == "High ID" }!
        precondition(shared.songCount == 2 && shared.albumCount == 2)
        precondition(mixed.filter { SystemLibraryIndex.contains($0, artist: shared) }.count == 2)
        let systemIndex = SystemLibraryIndex(songs: mixed.filter { $0.url == nil })
        precondition(systemIndex.artists.count == 2)
        precondition(!systemIndex.artists.contains { $0.name == "Local Only" })
        print("PASS: local removal uses song source and preserves all system artists")

        let missingIDs = [song(7, "Same Artist", album: "No ID"),
                          song(8, "Same Artist", albumID: 40, album: "Known ID")]
        let missingIndex = SystemLibraryIndex(songs: missingIDs)
        precondition(missingIndex.artists[0].albumCount == 2)
        for album in missingIndex.albums {
            precondition(missingIDs.filter { SystemLibraryIndex.contains($0, album: album) }.count == 1)
        }
        precondition(missingIndex.artists.map(\.id) == SystemLibraryIndex(songs: missingIDs.reversed()).artists.map(\.id))
        print("PASS: albums with missing IDs remain reachable and fallback IDs are stable")

        // Older JSON has no albumArtist field; it must remain decodable.
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(compilation[0])) as! [String: Any]
        legacyJSON.removeValue(forKey: "albumArtist")
        let legacySong = try JSONDecoder().decode(SystemSong.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        precondition(legacySong.albumArtist == nil)
        print("PASS: pre-fix song cache remains compatible")

        // The playing track survives in the queue while a library snapshot is
        // replaced. Album navigation must work before and after that refresh.
        let localCompilation = song(12, "Guest", local: true, album: "Collection", albumArtist: "Various Artists")
        let provisional = SystemLibraryIndex.album(for: localCompilation, in: [])
        precondition(provisional.artist == "Various Artists")
        precondition(SystemLibraryIndex.contains(localCompilation, album: provisional))
        let refreshedAlbums = SystemLibraryIndex(songs: [localCompilation]).albums
        let refreshedAlbum = SystemLibraryIndex.album(for: localCompilation, in: refreshedAlbums)
        precondition(provisional.id == refreshedAlbum.id)
        precondition(refreshedAlbum == refreshedAlbums[0])
        let systemFallback = SystemLibraryIndex.album(for: compilation[0], in: [])
        precondition(systemFallback.id == 30 && systemFallback.artist == "Various Artists")
        print("PASS: playing album remains navigable across deferred refresh and compilation metadata")

        precondition(SystemLibraryIndex.acceptsSearchResult(query: "Guest", currentQuery: "Guest",
            revision: 4, currentRevision: 4, request: 8, currentRequest: 8))
        precondition(!SystemLibraryIndex.acceptsSearchResult(query: "Guest", currentQuery: "Guest",
            revision: 3, currentRevision: 4, request: 8, currentRequest: 8))
        precondition(!SystemLibraryIndex.acceptsSearchResult(query: "Guest", currentQuery: "Other",
            revision: 4, currentRevision: 4, request: 8, currentRequest: 8))
        precondition(!SystemLibraryIndex.acceptsSearchResult(query: "Guest", currentQuery: "Guest",
            revision: 4, currentRevision: 4, request: 7, currentRequest: 8))
        print("PASS: queued search results cannot overwrite a newer library, query, or request")
    }
}
