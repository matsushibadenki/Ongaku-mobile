import Foundation

/// Lossless metadata replacement: audio bytes are streamed unchanged into a sibling
/// file, then atomically replaced. Complex/unknown ID3 layouts are left untouched.
nonisolated enum LyricsTagEditor {
    static let extensions: Set<String> = ["mp3", "flac", "m4a", "alac"]
    private static let limit = 32 * 1024 * 1024
    private struct Tag {
        var prefix: Data
        var audioOffset: UInt64
        var lyrics: String?
    }

    static func canEmbed(url: URL?, root: URL) -> Bool {
        guard let url, url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else { return false }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        return resolved.path.hasPrefix(base) && FileManager.default.isWritableFile(atPath: resolved.path)
    }

    static func read(url: URL) throws -> String? {
        guard url.isFileURL, extensions.contains(url.pathExtension.lowercased()) else { return nil }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        return try read(file, extension: url.pathExtension.lowercased())
    }

    static func embed(_ text: String, url: URL, root: URL) throws {
        guard !text.isEmpty, text.utf8.count <= 1_000_000 else { throw LyricsError.tooLarge }
        guard canEmbed(url: url, root: root) else { throw LyricsError.notWritable }
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try replace(text, url: coordinatedURL, root: root) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private static func replace(_ text: String, url: URL, root: URL) throws {
        guard canEmbed(url: url, root: root) else { throw LyricsError.notWritable }
        let fm = FileManager.default
        let original = try fm.attributesOfItem(atPath: url.path)
        guard original[.type] as? FileAttributeType == .typeRegular else { throw LyricsError.notWritable }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".ongaku-lyrics-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: nil) else { throw LyricsError.notWritable }
        let output = try FileHandle(forWritingTo: temporary)
        do {
            if ["m4a", "alac"].contains(url.pathExtension.lowercased()) {
                try M4ALyricsTagEditor.rewrite(input, to: output, lyrics: text)
            } else {
                let parsed = try tag(input, extension: url.pathExtension.lowercased(), replacement: text)
                try output.write(contentsOf: parsed.prefix)
                try input.seek(toOffset: parsed.audioOffset)
                while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                    try Task.checkCancellation()
                    try output.write(contentsOf: chunk)
                }
            }
            try output.synchronize()
            try output.close()
        } catch { try? output.close(); throw error }
        try Task.checkCancellation()
        let current = try fm.attributesOfItem(atPath: url.path)
        for key: FileAttributeKey in [.size, .modificationDate, .systemFileNumber] {
            guard (current[key] as? NSObject) == (original[key] as? NSObject) else { throw LyricsError.fileChanged }
        }
        // Verify the new tag before replacing the original. Audio bytes were copied verbatim.
        let check = try FileHandle(forReadingFrom: temporary)
        defer { try? check.close() }
        guard try read(check, extension: url.pathExtension.lowercased()) == text else {
            throw LyricsError.invalidResponse
        }
        _ = try fm.replaceItemAt(url, withItemAt: temporary)
    }

    private static func read(_ file: FileHandle, extension ext: String) throws -> String? {
        if ["m4a", "alac"].contains(ext) { return try M4ALyricsTagEditor.read(file) }
        return try tag(file, extension: ext, replacement: nil).lyrics
    }

    private static func tag(_ file: FileHandle, extension ext: String, replacement: String?) throws -> Tag {
        try file.seek(toOffset: 0)
        switch ext {
        case "mp3": return try id3(file, replacement: replacement)
        case "flac": return try flac(file, replacement: replacement)
        default: throw LyricsError.unsupportedTag
        }
    }
    private static func read(_ file: FileHandle, _ count: Int) throws -> [UInt8] {
        guard count >= 0, count <= limit else { throw LyricsError.tooLarge }
        let data = try file.read(upToCount: count) ?? Data()
        guard data.count == count else { throw LyricsError.unsupportedTag }
        return Array(data)
    }
    private static func number(_ bytes: ArraySlice<UInt8>, sync: Bool = false, little: Bool = false) throws -> Int {
        if sync && bytes.contains(where: { $0 >= 128 }) { throw LyricsError.unsupportedTag }
        return (little ? Array(bytes.reversed()) : Array(bytes)).reduce(0) { ($0 << (sync ? 7 : 8)) | Int($1) }
    }
    private static func encode(_ n: Int, count: Int = 4, sync: Bool = false, little: Bool = false) -> [UInt8] {
        let shift = sync ? 7 : 8
        let values = (0..<count).reversed().map { UInt8((n >> ($0 * shift)) & (sync ? 127 : 255)) }
        return little ? values.reversed() : values
    }
    private static func id3(_ file: FileHandle, replacement: String?) throws -> Tag {
        let header = try read(file, 10)
        let hasTag = Array(header[0..<3]) == Array("ID3".utf8)
        var version: UInt8 = 4, offset: UInt64 = 0, frames = [UInt8](), lyrics: String?
        if hasTag {
            version = header[3]
            // Refuse unsynchronised, extended-header, footer and experimental tags;
            // preserving such layouts requires recomputing their additional contracts.
            guard [3, 4].contains(version), header[4] == 0, header[5] == 0 else { throw LyricsError.unsupportedTag }
            let count = try number(header[6..<10], sync: true)
            let body = try read(file, count)
            offset = UInt64(count + 10)
            var i = 0
            while i < body.count {
                if body[i] == 0 {
                    guard body[i...].allSatisfy({ $0 == 0 }) else { throw LyricsError.unsupportedTag }
                    break
                }
                guard i + 10 <= body.count,
                      body[i..<i+4].allSatisfy({ (65...90).contains($0) || (48...57).contains($0) }) else { throw LyricsError.unsupportedTag }
                let name = String(bytes: body[i..<i+4], encoding: .ascii)!
                let length = try number(body[i+4..<i+8], sync: version == 4)
                guard length > 0, length <= body.count - i - 10 else { throw LyricsError.unsupportedTag }
                // Unknown transformations/read-only restrictions are not rewritten.
                guard body[i+8] == 0, body[i+9] == 0 else { throw LyricsError.unsupportedTag }
                let end = i + 10 + length
                if name == "USLT", let value = decodeUSLT(Array(body[i+10..<end])) {
                    if lyrics == nil || !LRCParser.parse(value).isEmpty { lyrics = value }
                }
                if replacement == nil || (name != "USLT" && name != "SYLT") { frames += body[i..<end] }
                i = end
            }
        }
        // Confirm an MPEG frame sync before treating an untagged/renamed file as MP3.
        try file.seek(toOffset: offset)
        let audio = try read(file, 2)
        guard audio[0] == 0xff, audio[1] & 0xe0 == 0xe0 else { throw LyricsError.unsupportedTag }
        if let replacement {
            let payload: [UInt8]
            if version == 3 {
                // UTF-16 BOM for both the empty descriptor and lyric text.
                payload = [1] + Array("und".utf8) + [0xff, 0xfe, 0, 0, 0xff, 0xfe] +
                    Array(replacement.data(using: .utf16LittleEndian)!)
            } else { payload = [3] + Array("und".utf8) + [0] + Array(replacement.utf8) }
            frames += Array("USLT".utf8) + encode(payload.count, sync: version == 4) + [0, 0] + payload
        }
        guard frames.count <= limit else { throw LyricsError.tooLarge }
        let prefix = Data(Array("ID3".utf8) + [version, 0, 0] + encode(frames.count, sync: true) + frames)
        return Tag(prefix: prefix, audioOffset: offset, lyrics: lyrics)
    }

    private static func decodeUSLT(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 5 else { return nil }
        let encoding: String.Encoding
        switch bytes[0] {
        case 0: encoding = .isoLatin1
        case 1: encoding = .utf16
        case 2: encoding = .utf16BigEndian
        case 3: encoding = .utf8
        default: return nil
        }
        let stride = [1, 2].contains(bytes[0]) ? 2 : 1
        var end = 4
        while end + stride <= bytes.count {
            if bytes[end..<end+stride].allSatisfy({ $0 == 0 }) {
                return String(data: Data(bytes[(end+stride)...]), encoding: encoding)?.trimmingCharacters(in: .init(charactersIn: "\0"))
            }
            end += stride
        }
        return nil
    }

    private static func flac(_ file: FileHandle, replacement: String?) throws -> Tag {
        guard try read(file, 4) == Array("fLaC".utf8) else { throw LyricsError.unsupportedTag }
        var blocks: [(UInt8, [UInt8])] = [], total = 4, lyrics: String?, foundComments = false
        while true {
            let header = try read(file, 4)
            let kind = header[0] & 127
            let size = try number(header[1..<4])
            total += 4 + size
            guard total <= limit, kind < 127 else { throw LyricsError.tooLarge }
            var body = try read(file, size)
            if blocks.isEmpty && (kind != 0 || size != 34) { throw LyricsError.unsupportedTag }
            if kind == 4 {
                guard !foundComments else { throw LyricsError.unsupportedTag }
                foundComments = true
                var index = 0
                func next() throws -> [UInt8] {
                    guard index + 4 <= body.count else { throw LyricsError.unsupportedTag }
                    let count = try number(body[index..<index+4], little: true)
                    index += 4
                    guard count <= body.count - index else { throw LyricsError.unsupportedTag }
                    defer { index += count }
                    return Array(body[index..<index+count])
                }
                let vendor = try next()
                guard index + 4 <= body.count else { throw LyricsError.unsupportedTag }
                let count = try number(body[index..<index+4], little: true)
                index += 4
                guard count <= (body.count - index) / 4 else { throw LyricsError.unsupportedTag }
                var comments: [[UInt8]] = []
                for _ in 0..<count {
                    let comment = try next()
                    let value = String(bytes: comment, encoding: .utf8) ?? ""
                    let key = value.split(separator: "=", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
                    let isLyrics = ["LYRICS", "SYNCEDLYRICS", "UNSYNCEDLYRICS"].contains(key)
                    if isLyrics, let separator = value.firstIndex(of: "=") {
                        let content = String(value[value.index(after: separator)...])
                        if lyrics == nil || !LRCParser.parse(content).isEmpty { lyrics = content }
                    }
                    if replacement == nil || !isLyrics { comments.append(comment) }
                }
                guard index == body.count else { throw LyricsError.unsupportedTag }
                if let replacement { comments.append(Array(("LYRICS=" + replacement).utf8)) }
                body = encode(vendor.count, little: true) + vendor + encode(comments.count, little: true)
                for comment in comments { body += encode(comment.count, little: true) + comment }
            }
            blocks.append((kind, body))
            if header[0] & 128 != 0 { break }
        }
        if !foundComments, let replacement {
            let vendor = Array("Ongaku".utf8), comment = Array(("LYRICS=" + replacement).utf8)
            blocks.append((4, encode(vendor.count, little: true) + vendor + encode(1, little: true) + encode(comment.count, little: true) + comment))
        }
        var prefix = Data("fLaC".utf8)
        for (index, block) in blocks.enumerated() {
            guard block.1.count < 1 << 24 else { throw LyricsError.tooLarge }
            prefix.append(contentsOf: [block.0 | (index == blocks.count - 1 ? 128 : 0)] + encode(block.1.count, count: 3) + block.1)
        }
        return Tag(prefix: prefix, audioOffset: UInt64(total), lyrics: lyrics)
    }
}
