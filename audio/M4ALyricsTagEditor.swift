import Foundation

/// Edits only the iTunes lyric item. Keeping all media byte offsets unchanged
/// avoids rewriting chunk tables, codec data, chapter tracks or private tags.
nonisolated enum M4ALyricsTagEditor {
    private static let limit = 32 * 1024 * 1024
    private static let lyricType = Data([0xa9, 0x6c, 0x79, 0x72]) // ©lyr
    private struct Box {
        let type: Data
        let start: UInt64
        let size: UInt64
        let header: Int
        let extendsToEnd: Bool
        var end: UInt64 { start + size }
        func isType(_ name: String) -> Bool { type == Data(name.utf8) }
    }
    private struct Layout {
        let boxes: [Box]
        let movie: Box
        let movieData: Data
        let fileSize: UInt64
    }

    static func read(_ file: FileHandle) throws -> String? {
        let layout = try layout(file)
        return try lyric(in: layout.movieData)
    }

    static func rewrite(_ file: FileHandle, to output: FileHandle, lyrics: String) throws {
        let layout = try layout(file)
        let replacement = try replacingLyrics(in: layout.movieData, text: lyrics)
        guard replacement.count <= limit else { throw LyricsError.tooLarge }
        for box in layout.boxes {
            try Task.checkCancellation()
            if box.start == layout.movie.start {
                if box.end == layout.fileSize {
                    // Subsequent edits replace the tail moov, avoiding repeated growth.
                    try output.write(contentsOf: replacement)
                } else {
                    // A fast-start moov becomes same-size free space. mdat and every
                    // stco/co64 offset remain in their original locations.
                    try output.write(contentsOf: word(box.size, width: box.header == 16 ? 8 : 4, type: "free"))
                    var remaining = box.size - UInt64(box.header)
                    while remaining > 0 {
                        let count = Int(min(remaining, 1024 * 1024))
                        try output.write(contentsOf: Data(repeating: 0, count: count))
                        remaining -= UInt64(count)
                    }
                }
            } else {
                try file.seek(toOffset: box.start)
                var remaining = box.size
                while remaining > 0 {
                    try Task.checkCancellation()
                    let count = Int(min(remaining, 1024 * 1024))
                    let data = try exact(file, count)
                    try output.write(contentsOf: data)
                    remaining -= UInt64(count)
                }
            }
        }
        if layout.movie.end != layout.fileSize { try output.write(contentsOf: replacement) }
    }

    private static func layout(_ file: FileHandle) throws -> Layout {
        let size = try file.seekToEnd()
        var boxes: [Box] = [], offset: UInt64 = 0
        while offset < size {
            guard boxes.count < 4096, size - offset >= 8 else { throw LyricsError.unsupportedTag }
            try file.seek(toOffset: offset)
            let header = try exact(file, 8)
            let shortSize = integer(header, 0, 4)
            let type = header.subdata(in: 4..<8)
            let width = shortSize == 1 ? 16 : 8
            let length: UInt64
            if shortSize == 1 { length = integer(try exact(file, 8), 0, 8) }
            else { length = shortSize == 0 ? size - offset : shortSize }
            guard length >= UInt64(width), length <= size - offset else { throw LyricsError.unsupportedTag }
            let box = Box(type: type, start: offset, size: length, header: width, extendsToEnd: shortSize == 0)
            // Zero-sized media extends to EOF and would swallow an appended moov.
            guard !box.extendsToEnd || box.isType("moov") else { throw LyricsError.unsupportedTag }
            guard !["moof", "mfra", "sidx", "meta"].contains(where: box.isType) else { throw LyricsError.unsupportedTag }
            boxes.append(box); offset = box.end
        }
        let movies = boxes.filter { $0.isType("moov") }
        guard movies.count == 1, let movie = movies.first,
              boxes.contains(where: { $0.isType("ftyp") }), boxes.contains(where: { $0.isType("mdat") }) else { throw LyricsError.unsupportedTag }
        guard movie.size <= UInt64(limit) else { throw LyricsError.tooLarge }
        try file.seek(toOffset: movie.start)
        let data = try exact(file, Int(movie.size))
        let children = try childBoxes(data, from: movie.header)
        guard children.contains(where: { $0.isType("trak") }),
              !children.contains(where: { $0.isType("cmov") || $0.isType("mvex") || $0.isType("meta") }) else { throw LyricsError.unsupportedTag }
        try validateTracks(data, children: children, media: boxes.filter { $0.isType("mdat") })
        return Layout(boxes: boxes, movie: movie, movieData: data, fileSize: size)
    }

    private static func validateTracks(_ movie: Data, children: [Box], media: [Box]) throws {
        func required(_ name: String, in data: Data) throws -> Data {
            let matches = try childBoxes(data, from: 0).filter { $0.isType(name) }
            guard matches.count == 1, let match = matches.first else { throw LyricsError.unsupportedTag }
            return payload(data, match)
        }
        var audioTracks = 0
        for track in children where track.isType("trak") {
            let mdia = try required("mdia", in: payload(movie, track))
            let handler = try required("hdlr", in: mdia)
            guard handler.count >= 12 else { throw LyricsError.unsupportedTag }
            let kind = handler.subdata(in: 8..<12)
            guard ["soun", "text", "sbtl", "subt"].contains(where: { kind == Data($0.utf8) }) else { throw LyricsError.unsupportedTag }
            let table = try required("stbl", in: required("minf", in: mdia))
            let entries = try childBoxes(table, from: 0)
            if kind == Data("soun".utf8) {
                audioTracks += 1
                let description = try required("stsd", in: table)
                guard description.count >= 8 else { throw LyricsError.unsupportedTag }
                let codecs = try childBoxes(description, from: 8)
                guard !codecs.isEmpty, UInt64(codecs.count) == integer(description, 4, 4),
                      codecs.allSatisfy({ $0.isType("mp4a") || $0.isType("alac") }) else { throw LyricsError.unsupportedTag }
            }
            // Only self-contained chunks in mdat are supported. In particular,
            // relocating moov must not invalidate media stored inside that atom.
            let offsets = entries.filter { $0.isType("stco") || $0.isType("co64") }
            guard offsets.count == 1, let offsets = offsets.first else { throw LyricsError.unsupportedTag }
            let data = payload(table, offsets), width = offsets.isType("stco") ? 4 : 8
            guard data.count >= 8, integer(data, 0, 4) == 0,
                  integer(data, 4, 4) == UInt64((data.count - 8) / width), (data.count - 8) % width == 0 else { throw LyricsError.unsupportedTag }
            for index in stride(from: 8, to: data.count, by: width) {
                let offset = integer(data, index, width)
                guard media.contains(where: { offset >= $0.start + UInt64($0.header) && offset < $0.end }) else { throw LyricsError.unsupportedTag }
            }
        }
        guard audioTracks > 0 else { throw LyricsError.unsupportedTag }
    }

    private static func childBoxes(_ data: Data, from start: Int) throws -> [Box] {
        guard start <= data.count else { throw LyricsError.unsupportedTag }
        var result: [Box] = [], index = start
        while index < data.count {
            guard result.count < 100_000, data.count - index >= 8 else { throw LyricsError.unsupportedTag }
            let shortSize = integer(data, index, 4)
            let header = shortSize == 1 ? 16 : 8
            guard data.count - index >= header else { throw LyricsError.unsupportedTag }
            let size = shortSize == 1 ? integer(data, index + 8, 8) : shortSize
            // Nested to-end boxes are ambiguous when adding siblings; don't modify them.
            guard size >= UInt64(header), size <= UInt64(data.count - index) else { throw LyricsError.unsupportedTag }
            result.append(Box(type: data.subdata(in: index+4..<index+8), start: UInt64(index), size: size, header: header, extendsToEnd: false))
            index += Int(size)
        }
        return result
    }
    private static func payload(_ data: Data, _ box: Box) -> Data {
        data.subdata(in: Int(box.start)+box.header..<Int(box.end))
    }
    private static func bytes(_ data: Data, _ box: Box) -> Data { data.subdata(in: Int(box.start)..<Int(box.end)) }
    private static func headerSize(_ data: Data) -> Int { integer(data, 0, 4) == 1 ? 16 : 8 }

    private static func metadata(_ movie: Data) throws -> Data? {
        let boxes = try childBoxes(movie, from: headerSize(movie)).filter { $0.isType("udta") }
        guard boxes.count <= 1 else { throw LyricsError.unsupportedTag }
        guard let udta = boxes.first else { return nil }
        let data = payload(movie, udta)
        let metas = try childBoxes(data, from: 0).filter { $0.isType("meta") }
        guard metas.count <= 1 else { throw LyricsError.unsupportedTag }
        return metas.first.map { bytes(data, $0) }
    }
    private static func metadataChildren(_ meta: Data) throws -> [Box] {
        let header = headerSize(meta)
        guard meta.count >= header + 4, meta.subdata(in: header..<header+4) == Data(repeating: 0, count: 4) else { throw LyricsError.unsupportedTag }
        let children = try childBoxes(meta, from: header + 4)
        let handlers = children.filter { $0.isType("hdlr") }
        guard handlers.count == 1, let handler = handlers.first else { throw LyricsError.unsupportedTag }
        let data = payload(meta, handler)
        // mdta numeric-key metadata is a different format and must not be mixed.
        guard data.count >= 12, data.subdata(in: 8..<12) == Data("mdir".utf8),
              !children.contains(where: { $0.isType("keys") }),
              children.filter({ $0.isType("ilst") }).count <= 1 else { throw LyricsError.unsupportedTag }
        return children
    }
    private static func lyric(in movie: Data) throws -> String? {
        guard let meta = try metadata(movie), let list = try metadataChildren(meta).first(where: { $0.isType("ilst") }) else { return nil }
        let data = payload(meta, list)
        var plain: String?
        for item in try childBoxes(data, from: 0) where item.type == lyricType {
            let itemData = payload(data, item)
            for value in try childBoxes(itemData, from: 0) where value.isType("data") {
                let body = payload(itemData, value)
                guard body.count >= 8 else { throw LyricsError.unsupportedTag }
                let kind = integer(body, 0, 4)
                let encoding: String.Encoding
                if kind == 1 { encoding = .utf8 }
                else if kind == 2 { encoding = .utf16BigEndian }
                else { continue }
                if let text = String(data: body.dropFirst(8), encoding: encoding) {
                    if !LRCParser.parse(text).isEmpty { return text }
                    plain = plain ?? text
                }
            }
        }
        return plain
    }
    private static func replacingLyrics(in movie: Data, text: String) throws -> Data {
        let lyric = box(lyricType, Data(box(Data("data".utf8), Data([0,0,0,1,0,0,0,0]) + Data(text.utf8))))
        func editMeta(_ meta: Data?) throws -> Data {
            guard let meta else {
                let handler = box(Data("hdlr".utf8), Data(repeating: 0, count: 8) + Data("mdir".utf8) + Data(repeating: 0, count: 13))
                return box(Data("meta".utf8), Data(repeating: 0, count: 4) + handler + box(Data("ilst".utf8), lyric))
            }
            let children = try metadataChildren(meta)
            var content = Data(repeating: 0, count: 4), found = false
            for child in children {
                if child.isType("ilst") {
                    let items = payload(meta, child)
                    var kept = Data()
                    for item in try childBoxes(items, from: 0) where item.type != lyricType { kept.append(bytes(items, item)) }
                    content.append(box(Data("ilst".utf8), kept + lyric)); found = true
                } else { content.append(bytes(meta, child)) }
            }
            if !found { content.append(box(Data("ilst".utf8), lyric)) }
            return box(Data("meta".utf8), content)
        }
        let newMeta = try editMeta(metadata(movie))
        let children = try childBoxes(movie, from: headerSize(movie))
        var content = Data(), found = false
        for child in children {
            if child.isType("udta") {
                let old = payload(movie, child)
                var updated = Data(), hasMeta = false
                for entry in try childBoxes(old, from: 0) {
                    if entry.isType("meta") { updated.append(newMeta); hasMeta = true }
                    else { updated.append(bytes(old, entry)) }
                }
                if !hasMeta { updated.append(newMeta) }
                content.append(box(Data("udta".utf8), updated)); found = true
            } else { content.append(bytes(movie, child)) }
        }
        if !found { content.append(box(Data("udta".utf8), newMeta)) }
        return box(Data("moov".utf8), content)
    }
    private static func exact(_ file: FileHandle, _ size: Int) throws -> Data {
        let data = try file.read(upToCount: size) ?? Data()
        guard data.count == size else { throw LyricsError.unsupportedTag }
        return data
    }
    private static func integer(_ data: Data, _ index: Int, _ count: Int) -> UInt64 {
        data[index..<index+count].reduce(0) { ($0 << 8) | UInt64($1) }
    }
    private static func bigEndian(_ value: UInt64, _ width: Int) -> Data {
        Data((0..<width).reversed().map { UInt8((value >> ($0 * 8)) & 255) })
    }
    private static func word(_ size: UInt64, width: Int, type: String) -> Data {
        width == 8 ? bigEndian(1, 4) + Data(type.utf8) + bigEndian(size, 8) : bigEndian(size, 4) + Data(type.utf8)
    }
    private static func box(_ type: Data, _ payload: Data) -> Data { bigEndian(UInt64(payload.count + 8), 4) + type + payload }
}
