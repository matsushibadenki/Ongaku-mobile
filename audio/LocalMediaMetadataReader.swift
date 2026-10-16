import Foundation
import AVFoundation

nonisolated struct LocalTrackMetadata: Sendable {
    let url: URL
    let title: String
    let artist: String
    let album: String
    let duration: TimeInterval
    let trackNumber: Int?
    let discNumber: Int?
    var albumArtist: String? = nil
}

/// Shared by the scanner and artwork loading. No audio graph or UI work here.
nonisolated enum LocalMediaMetadataReader {
    static func read(_ url: URL) async throws -> LocalTrackMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        var items = try await asset.load(.metadata)
        items += (try? await asset.load(.commonMetadata)) ?? []
        var title: String?, artist: String?, album: String?, albumArtist: String?
        var track: Int?, disc: Int?
        for item in items {
            try Task.checkCancellation()
            let identifier = item.identifier?.rawValue.lowercased() ?? ""
            let key = (item.key as? String ?? "").lowercased()
            let value = try? await item.load(.value)
            let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = string.flatMap { $0.isEmpty ? nil : $0 }
            switch item.commonKey {
            case .commonKeyTitle: title = title ?? text
            case .commonKeyArtist: artist = artist ?? text
            case .commonKeyAlbumName: album = album ?? text
            default: break
            }
            if identifier.contains("tpe2") || identifier.contains("aart") || ["albumartist", "album artist", "album_artist"].contains(key) {
                albumArtist = albumArtist ?? text
            }
            if identifier.contains("trck") || identifier.contains("trkn") || ["tracknumber", "track", "track_number"].contains(key) {
                track = track ?? number(value, binary: identifier.contains("trkn"))
            }
            if identifier.contains("tpos") || identifier.contains("disk") || ["discnumber", "disc", "disc_number"].contains(key) {
                disc = disc ?? number(value, binary: identifier.contains("disk"))
            }
        }
        // AVFoundation does not expose Vorbis comments consistently across OS releases.
        let comments = try flacComments(url)
        title = title ?? comments["TITLE"]
        artist = artist ?? comments["ARTIST"]
        album = album ?? comments["ALBUM"]
        albumArtist = albumArtist ?? comments["ALBUMARTIST"] ?? comments["ALBUM ARTIST"]
        track = track ?? positiveNumber(comments["TRACKNUMBER"])
        disc = disc ?? positiveNumber(comments["DISCNUMBER"])
        let info = try waveInfo(url)
        title = title ?? info["INAM"]
        artist = artist ?? info["IART"]
        album = album ?? info["IPRD"]
        track = track ?? positiveNumber(info["ITRK"] ?? info["IPRT"])
        return LocalTrackMetadata(url: url, title: title ?? url.deletingPathExtension().lastPathComponent,
                                  artist: artist ?? "Unknown Artist",
                                  album: album ?? LocalAlbumFiles.albumDirectory(for: url).lastPathComponent,
                                  duration: duration.isFinite ? max(0, duration) : 0,
                                  trackNumber: track, discNumber: disc ?? LocalAlbumFiles.discNumber(for: url),
                                  albumArtist: albumArtist)
    }

    static func positiveNumber(_ string: String?) -> Int? {
        guard let string, let number = Int(string.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""), number > 0 else { return nil }
        return number
    }

    private static func number(_ value: (any NSCopying & NSObjectProtocol)?, binary: Bool) -> Int? {
        if let n = value as? NSNumber { return n.intValue > 0 ? n.intValue : nil }
        if let text = value as? String { return positiveNumber(text) }
        if let data = value as? Data {
            // iTunes trkn/disk: two reserved bytes, big-endian index, then total.
            if binary, data.count >= 4 {
                let bytes = [UInt8](data.prefix(4))
                let n = Int(bytes[2]) << 8 | Int(bytes[3])
                return n > 0 ? n : nil
            }
            return positiveNumber(String(data: data, encoding: .utf8))
        }
        return nil
    }

    static func artworkData(_ url: URL) async -> Data? {
        guard url.isFileURL, !Task.isCancelled else { return nil }
        let asset = AVURLAsset(url: url)
        let items = (try? await asset.load(.commonMetadata)) ?? []
        for item in items where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        // Native FLAC picture blocks are the fallback when commonMetadata omits them.
        if let data = try? flacPicture(url) { return data }
        for directory in [url.deletingLastPathComponent(), LocalAlbumFiles.albumDirectory(for: url)] {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            let names = ["cover", "folder", "front", "artwork", directory.lastPathComponent.lowercased()]
            for name in names {
                for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
                where file.deletingPathExtension().lastPathComponent.lowercased() == name &&
                    ["jpg", "jpeg", "png", "heic", "webp"].contains(file.pathExtension.lowercased()) {
                    if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 32 * 1024 * 1024,
                       let data = try? Data(contentsOf: file), !data.isEmpty { return data }
                }
            }
        }
        return nil
    }

    // Read metadata blocks only; never load the full audio file into memory.
    private static func flacBlock(_ url: URL, type: UInt8) throws -> Data? {
        guard url.pathExtension.lowercased() == "flac" else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard try handle.read(upToCount: 4) == Data("fLaC".utf8) else { return nil }
        for _ in 0..<256 {
            try Task.checkCancellation()
            guard let header = try handle.read(upToCount: 4), header.count == 4 else { return nil }
            let bytes = [UInt8](header)
            let length = Int(bytes[1]) << 16 | Int(bytes[2]) << 8 | Int(bytes[3])
            if bytes[0] & 0x7f == type {
                guard length <= 16 * 1024 * 1024 else { return nil }
                return try handle.read(upToCount: length)
            }
            try handle.seek(toOffset: handle.offset() + UInt64(length))
            if bytes[0] & 0x80 != 0 { break }
        }
        return nil
    }

    private static func flacComments(_ url: URL) throws -> [String: String] {
        guard let data = try flacBlock(url, type: 4) else { return [:] }
        let bytes = [UInt8](data)
        var cursor = 0
        func integer() -> Int? {
            guard cursor + 4 <= bytes.count else { return nil }
            defer { cursor += 4 }
            return Int(bytes[cursor]) | Int(bytes[cursor + 1]) << 8 | Int(bytes[cursor + 2]) << 16 | Int(bytes[cursor + 3]) << 24
        }
        guard let vendorLength = integer(), vendorLength <= bytes.count - cursor else { return [:] }
        cursor += vendorLength
        guard let count = integer(), count <= 100_000 else { return [:] }
        var result: [String: String] = [:]
        for _ in 0..<count {
            guard let length = integer(), length <= bytes.count - cursor else { break }
            let text = String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self)
            cursor += length
            let pair = text.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2, !pair[1].isEmpty { result[pair[0].uppercased()] = pair[1] }
        }
        return result
    }

    private static func flacPicture(_ url: URL) throws -> Data? {
        guard let data = try flacBlock(url, type: 6) else { return nil }
        let bytes = [UInt8](data)
        var cursor = 4 // picture type
        func integer() -> Int? {
            guard cursor + 4 <= bytes.count else { return nil }
            defer { cursor += 4 }
            return Int(bytes[cursor]) << 24 | Int(bytes[cursor + 1]) << 16 | Int(bytes[cursor + 2]) << 8 | Int(bytes[cursor + 3])
        }
        for _ in 0..<2 { // MIME and description
            guard let length = integer(), length <= bytes.count - cursor else { return nil }
            cursor += length
        }
        cursor += 16 // width, height, depth and palette count
        guard let length = integer(), length <= bytes.count - cursor else { return nil }
        return Data(bytes[cursor..<(cursor + length)])
    }

    private static func waveInfo(_ url: URL) throws -> [String: String] {
        guard url.pathExtension.lowercased() == "wav" else { return [:] }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.prefix(4) == Data("RIFF".utf8), header.suffix(4) == Data("WAVE".utf8) else { return [:] }
        func length(_ bytes: [UInt8], _ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }
        for _ in 0..<256 {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 8), chunk.count == 8 else { break }
            let count = length([UInt8](chunk), 4)
            let next = try handle.offset() + UInt64(count + count % 2)
            if chunk.prefix(4) == Data("LIST".utf8), count <= 1024 * 1024,
               let data = try handle.read(upToCount: count), data.prefix(4) == Data("INFO".utf8) {
                let bytes = [UInt8](data)
                var cursor = 4
                var result: [String: String] = [:]
                while cursor + 8 <= bytes.count {
                    let key = String(decoding: bytes[cursor..<(cursor + 4)], as: UTF8.self)
                    let size = length(bytes, cursor + 4)
                    cursor += 8
                    guard size <= bytes.count - cursor else { break }
                    let value = String(decoding: bytes[cursor..<(cursor + size)], as: UTF8.self)
                        .trimmingCharacters(in: .controlCharacters.union(.whitespacesAndNewlines))
                    if !value.isEmpty { result[key] = value }
                    cursor += size + size % 2
                }
                return result
            }
            try handle.seek(toOffset: next)
        }
        return [:]
    }
}
