import Foundation
import ImageIO

enum L10n { static func tr(_ key: String) -> String { key } }

@main struct LocalLibraryRegression {
    static func song(_ id: UInt64, _ track: LocalTrackMetadata) -> SystemSong {
        SystemSong(id: id, title: track.title, artist: track.artist, album: track.album,
                   artistID: nil, albumID: nil, discNumber: track.discNumber, trackNumber: track.trackNumber,
                   duration: track.duration, url: track.url, albumArtist: track.albumArtist)
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        for ext in ["mp3", "m4a", "flac", "aiff", "wav"] {
            let url = root.appendingPathComponent("Tagged/track.\(ext)")
            let track = try await LocalMediaMetadataReader.read(url)
            precondition(track.title == "Song Z" && track.artist == "Guest A" && track.album == "Collection", "\(ext): text tags \(track)")
            precondition(track.trackNumber == 2, "\(ext): track number")
            if ext != "wav" {
                precondition(track.discNumber == 1 && track.albumArtist == "Various Artists", "\(ext): album/disc tags")
            }
            let artwork = await LocalMediaMetadataReader.artworkData(url)
            precondition(artwork != nil && CGImageSourceCreateWithData(artwork! as CFData, nil) != nil, "\(ext): artwork")
            if ext != "wav" {
                let isolated = root.appendingPathComponent("Embedded/\(ext)/track.\(ext)")
                try FileManager.default.createDirectory(at: isolated.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: isolated)
                let embedded = await LocalMediaMetadataReader.artworkData(isolated)
                precondition(embedded != nil && CGImageSourceCreateWithData(embedded! as CFData, nil) != nil,
                             "\(ext): embedded artwork without a folder image")
            }
            print("PASS: \(ext) metadata and decodable artwork")
        }
        let a = try await LocalMediaMetadataReader.read(root.appendingPathComponent("Compilation/10 B.mp3"))
        let b = try await LocalMediaMetadataReader.read(root.appendingPathComponent("Compilation/2 A.mp3"))
        let compilation = [song(1, a), song(2, b)]
        let index = SystemLibraryIndex(songs: compilation)
        precondition(index.albums.count == 1 && index.albums[0].songCount == 2)
        precondition(index.artists.count == 2)
        precondition(SystemLibraryIndex.orderedAlbumSongs(compilation).map(\.id) == [2, 1])
        precondition(compilation.allSatisfy { SystemLibraryIndex.contains($0, album: index.albums[0]) })
        print("PASS: mixed performers in one folder form one album, with numbered tracks ordered")

        var other = a
        other = LocalTrackMetadata(url: root.appendingPathComponent("Other/10 B.mp3"), title: a.title,
            artist: a.artist, album: a.album, duration: a.duration, trackNumber: a.trackNumber, discNumber: a.discNumber)
        precondition(SystemLibraryIndex(songs: compilation + [song(3, other)]).albums.count == 2)
        print("PASS: separate folders with identical album titles remain separate")

        let disc1 = try await LocalMediaMetadataReader.read(root.appendingPathComponent("Untagged/CD1/10.wav"))
        let disc2 = try await LocalMediaMetadataReader.read(root.appendingPathComponent("Untagged/CD2/2.wav"))
        let disc1First = try await LocalMediaMetadataReader.read(root.appendingPathComponent("Untagged/CD1/2.wav"))
        let discs = [song(4, disc2), song(5, disc1), song(6, disc1First)]
        precondition(disc1.album == "Untagged" && disc2.discNumber == 2)
        precondition(SystemLibraryIndex(songs: discs).albums.count == 1)
        precondition(SystemLibraryIndex.orderedAlbumSongs(discs).map(\.id) == [6, 5, 4])
        let discArtwork = await LocalMediaMetadataReader.artworkData(disc2.url)
        precondition(discArtwork != nil)
        print("PASS: disc directories group together; untagged files use natural numeric filename order and parent-folder artwork")

        let unart = root.appendingPathComponent("Empty/none.wav")
        let missingArtwork = await LocalMediaMetadataReader.artworkData(unart)
        precondition(missingArtwork == nil)
        let malformed = root.appendingPathComponent("Empty/malformed.flac")
        try Data([0x66,0x4c,0x61,0x43,0x84,0,0,4,255,255,255,255]).write(to: malformed)
        let malformedArtwork = await LocalMediaMetadataReader.artworkData(malformed)
        precondition(malformedArtwork == nil)
        print("PASS: missing artwork and truncated metadata fail safely")
        let encoded = try JSONEncoder().encode(index.albums[0])
        let decoded = try JSONDecoder().decode(SystemAlbum.self, from: encoded)
        precondition(decoded.localIdentity == index.albums[0].localIdentity)
        print("PASS: local album identity survives cache round-trip")
    }
}
