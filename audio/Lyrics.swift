import Foundation

nonisolated struct LyricLine: Identifiable, Equatable, Sendable {
    let id: Int
    let time: TimeInterval
    let text: String
}

nonisolated enum LRCParser {
    // Multiple timestamps, fractional seconds and a file-wide millisecond offset.
    // Blank timed lines are retained so instrumental gaps clear the highlight.
    static func parse(_ text: String) -> [LyricLine] {
        guard text.utf8.count <= 1_000_000 else { return [] }
        let stamp = try! NSRegularExpression(pattern: #"\[(\d{1,3}):([0-5]\d)(?:[\.:](\d{1,3}))?\]"#)
        let offsetPattern = try! NSRegularExpression(pattern: #"(?im)^\s*\[offset:([+-]?\d+)\]\s*$"#)
        let ns = text as NSString
        let offset = offsetPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).last
            .flatMap { Double(ns.substring(with: $0.range(at: 1))) }.map { $0 / 1000 } ?? 0
        var parsed: [(Double, String, Int)] = []
        for raw in text.components(separatedBy: .newlines) {
            let row = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "\u{FEFF}"))) as NSString
            var end = 0
            let matches = stamp.matches(in: row as String, range: NSRange(location: 0, length: row.length)).prefix { match in
                guard match.range.location == end else { return false }
                end = NSMaxRange(match.range)
                return true
            }
            guard let last = matches.last else { continue }
            let words = row.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespaces)
            for match in matches {
                let minutes = Double(row.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(row.substring(with: match.range(at: 2))) ?? 0
                let fraction = match.range(at: 3).location == NSNotFound ? 0 :
                    (Double("0." + row.substring(with: match.range(at: 3))) ?? 0)
                parsed.append((max(0, minutes * 60 + seconds + fraction - offset), words, parsed.count))
            }
        }
        // Merge simultaneous translations/voices into one highlighted block.
        let sorted = parsed.sorted { $0.0 == $1.0 ? $0.2 < $1.2 : $0.0 < $1.0 }
        var lines: [LyricLine] = []
        for (time, text, _) in sorted {
            if let last = lines.last, last.time == time {
                lines[lines.count - 1] = LyricLine(id: last.id, time: time,
                    text: [last.text, text].filter { !$0.isEmpty }.joined(separator: "\n"))
            } else { lines.append(LyricLine(id: lines.count, time: time, text: text)) }
        }
        return lines
    }

    static func activeLine(in lines: [LyricLine], at time: TimeInterval) -> Int? {
        guard time.isFinite, !lines.isEmpty, time >= lines[0].time else { return nil }
        var low = 0, high = lines.count
        while low < high {
            let mid = (low + high) / 2
            if lines[mid].time <= time { low = mid + 1 } else { high = mid }
        }
        return lines[low - 1].id
    }
}

nonisolated struct LyricsRecord: Codable, Identifiable, Equatable, Sendable {
    let id: Int
    let trackName: String
    let artistName: String
    let albumName: String
    let duration: Double
    let instrumental: Bool
    let plainLyrics: String?
    let syncedLyrics: String?

    var lines: [LyricLine] { LRCParser.parse(syncedLyrics ?? "") }
    var isSynced: Bool { !lines.isEmpty }
    var text: String {
        if isSynced { return syncedLyrics! }
        return plainLyrics?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    var isUsable: Bool { instrumental || !text.isEmpty }

    static func embedded(_ text: String) -> LyricsRecord {
        LyricsRecord(id: -1, trackName: "", artistName: "", albumName: "", duration: 0,
                     instrumental: false, plainLyrics: text,
                     syncedLyrics: LRCParser.parse(text).isEmpty ? nil : text)
    }

    static func ranked(_ records: [LyricsRecord], duration: Double) -> [LyricsRecord] {
        records.filter(\.isUsable).map { (record: $0, synced: $0.isSynced, distance: abs($0.duration - duration)) }.sorted {
            if $0.synced != $1.synced { return $0.synced }
            return $0.distance == $1.distance ? $0.record.id < $1.record.id : $0.distance < $1.distance
        }.map(\.record)
    }
}

nonisolated enum LyricsError: LocalizedError {
    case server(Int), invalidResponse, unsupportedTag, fileChanged, notWritable, tooLarge
    var errorDescription: String? {
        switch self {
        case .server(let status): return L10n.tr("lyrics.error.server", status)
        case .invalidResponse: return L10n.tr("lyrics.error.response")
        case .unsupportedTag: return L10n.tr("lyrics.error.tag")
        case .fileChanged: return L10n.tr("lyrics.error.changed")
        case .notWritable: return L10n.tr("lyrics.error.writable")
        case .tooLarge: return L10n.tr("lyrics.error.large")
        }
    }
}

nonisolated struct LRCLIBClient: Sendable {
    var session: URLSession = .shared

    func search(title: String, artist: String) async throws -> [LyricsRecord] {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [URLQueryItem(name: "track_name", value: title)]
        if !artist.isEmpty { components.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.setValue("Ongaku/1.0 (iOS lyrics search)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw LyricsError.invalidResponse }
        guard http.statusCode == 200 else { throw LyricsError.server(http.statusCode) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 8_000_000 else { throw LyricsError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return try JSONDecoder().decode([LyricsRecord].self, from: data)
    }
}

actor LyricsStore {
    static let shared = LyricsStore()
    private let directory: URL
    init(directory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PlayerLibrary/Lyrics", isDirectory: true)) { self.directory = directory }

    private func url(for key: String) -> URL {
        // Keys come from SystemSong; do not interpret them as paths.
        let name = Data(key.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent(name).appendingPathExtension("json")
    }
    func load(key: String) throws -> LyricsRecord? {
        let file = url(for: key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(LyricsRecord.self, from: Data(contentsOf: file))
    }
    func save(_ record: LyricsRecord, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: url(for: key), options: .atomic)
    }
}
