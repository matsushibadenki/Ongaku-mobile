import Foundation

@main
struct LyricsRegression {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    @MainActor static func main() async throws {
        let lrc = "[ar:Example]\n[00:02.50][00:05.125]日本語 简体中文\n[00:02.50]Translation\n[00:04.0]\n[00:99.0]invalid\n[offset:+500]"
        let lines = LRCParser.parse(lrc)
        require(lines.count == 3, "timestamps, metadata and invalid times")
        require(lines[0].time == 2 && lines[0].text == "日本語 简体中文\nTranslation", "offset and simultaneous translations")
        require(lines[1].time == 3.5 && lines[1].text.isEmpty, "instrumental gap")
        require(lines[2].time == 4.625, "millisecond precision")
        require(LRCParser.activeLine(in: lines, at: 1.99) == nil, "intro")
        require(LRCParser.activeLine(in: lines, at: 4) == 1, "gap index")
        require(LRCParser.activeLine(in: lines, at: 2) == 0, "backwards seek")
        require(LRCParser.activeLine(in: lines, at: .nan) == nil, "invalid clock")
        require(LRCParser.parse("[offset:-1000]\n[00:01]later")[0].time == 2, "negative offset")
        require(LRCParser.parse("plain lyrics").isEmpty, "plain fallback")
        let synced = LyricsRecord(id: 2, trackName: "Example", artistName: "Artist", albumName: "Album", duration: 200, instrumental: false, plainLyrics: "plain", syncedLyrics: lrc)
        let plain = LyricsRecord(id: 1, trackName: "Example", artistName: "Artist", albumName: "Album", duration: 180, instrumental: false, plainLyrics: "plain", syncedLyrics: "bad LRC")
        require(LyricsRecord.ranked([plain, synced], duration: 180).first?.id == 2, "prefer valid synced result")
        require(plain.text == "plain", "invalid LRC falls back")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LyricsTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LyricsStore(directory: root.appendingPathComponent("store"))
        try await store.save(synced, key: "systemMusic:123")
        let loaded = try await store.load(key: "systemMusic:123")
        require(loaded == synced, "persistent Unicode lyric record")
        let missing = try await store.load(key: "ongakuManaged:123")
        require(missing == nil, "library source isolation")

        let audio = Data([0xff, 0xfb] + Array(repeating: UInt8(0x32), count: 4096))
        func size(_ n: Int, sync: Bool = false) -> [UInt8] {
            (0..<4).reversed().map { UInt8((n >> ($0 * (sync ? 7 : 8))) & (sync ? 127 : 255)) }
        }
        for version: UInt8 in [3, 4] {
            let frame = Array("TIT2".utf8) + size(6, sync: version == 4) + [0, 0, 0] + Array("Title".utf8)
            let data = Data(Array("ID3".utf8) + [version, 0, 0] + size(frame.count + 20, sync: true) + frame + Array(repeating: 0, count: 20)) + audio
            let url = root.appendingPathComponent("v\(version).mp3")
            try data.write(to: url)
            try LyricsTagEditor.embed(lrc, url: url, root: root)
            let embedded = try LyricsTagEditor.read(url: url)
            require(embedded == lrc, "ID3 v\(version) Unicode roundtrip")
            let result = try Data(contentsOf: url)
            require(result.suffix(audio.count) == audio, "MP3 audio payload unchanged")
            require(result.range(of: Data(frame)) != nil, "ID3 title preserved")
            try LyricsTagEditor.embed("[00:01]replacement", url: url, root: root)
            let replaced = try LyricsTagEditor.read(url: url)
            require(replaced == "[00:01]replacement", "replace rather than append stale lyrics")
        }
        let bare = root.appendingPathComponent("bare.mp3")
        try audio.write(to: bare)
        try LyricsTagEditor.embed(lrc, url: bare, root: root)
        let bareText = try LyricsTagEditor.read(url: bare)
        require(bareText == lrc, "new ID3 tag")

        let flac = root.appendingPathComponent("test.flac")
        // STREAMINFO + picture/application metadata + opaque audio payload.
        let prefix = Data(Array("fLaC".utf8) + [0, 0, 0, 34] + Array(repeating: 0, count: 34) + [130, 0, 0, 4, 1, 2, 3, 4])
        try (prefix + audio).write(to: flac)
        try LyricsTagEditor.embed(lrc, url: flac, root: root)
        let flacText = try LyricsTagEditor.read(url: flac)
        require(flacText == lrc, "FLAC Unicode roundtrip")
        let flacData = try Data(contentsOf: flac)
        require(flacData.suffix(audio.count) == audio, "FLAC audio preserved")
        require(flacData.range(of: Data([2, 0, 0, 4, 1, 2, 3, 4])) != nil, "FLAC other metadata preserved")
        try LyricsTagEditor.embed("plain replacement", url: flac, root: root)
        let flacReplaced = try LyricsTagEditor.read(url: flac)
        require(flacReplaced == "plain replacement", "FLAC replace existing comments")

        // Flagged ID3 and truncated metadata must fail without changing one byte.
        for (name, bytes) in [("flagged", Data([73,68,51,4,0,128,0,0,0,0]) + audio),
                              ("truncated", Data([73,68,51,4,0,0,0,0,127,127]))] {
            let file = root.appendingPathComponent(name + ".mp3")
            try bytes.write(to: file)
            do { try LyricsTagEditor.embed(lrc, url: file, root: root); fatalError("unsafe tag accepted") }
            catch { }
            let unchanged = try Data(contentsOf: file)
            require(unchanged == bytes, "original preserved after failed embedding")
        }
        let outside = root.appendingPathComponent("outside.mp3")
        require(!LyricsTagEditor.canEmbed(url: outside, root: root.appendingPathComponent("nested")), "managed root restriction")
        let link = root.appendingPathComponent("link.mp3")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        require(!LyricsTagEditor.canEmbed(url: link, root: root), "symlink escape restriction")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LyricsStubProtocol.self]
        let client = LRCLIBClient(session: URLSession(configuration: config))
        LyricsStubProtocol.payload = try JSONEncoder().encode([synced, plain])
        let results = try await client.search(title: "日本語 & test", artist: "a/b")
        require(results.count == 2, "decode search records")
        let query = URLComponents(url: LyricsStubProtocol.lastURL!, resolvingAgainstBaseURL: false)!.queryItems!
        require(query.first(where: { $0.name == "track_name" })?.value == "日本語 & test", "safe Unicode URL encoding")
        LyricsStubProtocol.status = 429
        do { _ = try await client.search(title: "test", artist: ""); fatalError("HTTP error accepted") }
        catch LyricsError.server(429) { }
        LyricsStubProtocol.status = 200; LyricsStubProtocol.payload = Data("not JSON".utf8)
        do { _ = try await client.search(title: "test", artist: ""); fatalError("invalid JSON accepted") }
        catch is DecodingError { }
        LyricsStubProtocol.payload = try JSONEncoder().encode([synced, plain])
        let model = LyricsViewModel(store: store, client: client)
        let song = SystemSong(id: 123, title: "Example", artist: "Artist", album: "Album", artistID: nil, albumID: nil, discNumber: nil, trackNumber: nil, duration: 180, url: nil)
        await model.load(song: song)
        require(model.record == synced && !model.loading, "model loads persisted lyric record")
        model.setTimingOffset(1200)
        await model.waitForTimingSave()
        require(LRCParser.activeLine(in: model.lines, at: LyricsTiming.displayClock(3.19, offset: model.timingOffsetMilliseconds)) == nil, "positive timing delays highlight")
        require(LRCParser.activeLine(in: model.lines, at: LyricsTiming.displayClock(3.2, offset: model.timingOffsetMilliseconds)) == 0, "shifted highlight boundary")
        require(abs(LyricsTiming.playbackTime(for: 2, offset: 1200) - 3.2) < 0.000001, "seek uses shifted timestamp")
        require(LyricsTiming.playbackTime(for: 0.5, offset: -1200) == 0, "early seek clamps to track start")
        require(LyricsTiming.normalized(Int.max) == 10000 && LyricsTiming.normalized(Int.min) == -10000, "timing bounds")
        let reopened = LyricsViewModel(store: store, client: client)
        await reopened.load(song: song)
        require(reopened.timingOffsetMilliseconds == 1200 && reopened.record == synced, "timing survives reopen without rewriting lyrics")
        for offset in stride(from: -2000, through: 2000, by: 100) { reopened.setTimingOffset(offset) }
        await reopened.waitForTimingSave()
        let latestOffset = try await store.loadTiming(key: song.overlayKey)
        require(latestOffset == 2000, "rapid adjustment preserves latest save")
        let otherSong = SystemSong(id: 124, title: "Other", artist: "Artist", album: "Album", artistID: nil, albumID: nil, discNumber: nil, trackNumber: nil, duration: 180, url: nil)
        await reopened.load(song: otherSong)
        require(reopened.timingOffsetMilliseconds == 0 && reopened.record == nil, "song switch clears old lines and timing")
        await reopened.load(song: song)
        reopened.setTimingOffset(0)
        await reopened.waitForTimingSave()
        let resetOffset = try await store.loadTiming(key: song.overlayKey)
        require(resetOffset == 0, "timing reset persists")
        print("PASS: per-song timing, display/seek direction, bounds, rapid edits, reset and lyric preservation")
        model.search(title: "slow", artist: "", duration: 180)
        try await Task.sleep(for: .milliseconds(20))
        model.cancelSearch()
        try await Task.sleep(for: .milliseconds(300))
        require(model.results.isEmpty && !model.searching, "cancelled result cannot update model")
        model.search(title: "slow", artist: "", duration: 180)
        try await Task.sleep(for: .milliseconds(20))
        model.search(title: "fast", artist: "", duration: 180)
        try await Task.sleep(for: .milliseconds(350))
        require(model.searched && model.results.first?.id == 2 && !model.searching, "newest search wins and prioritizes synced lyrics")
        let selected = await model.select(plain, song: song)
        require(selected && model.record == plain && model.lines.isEmpty, "selection resets synchronized lines")
        let reloaded = try await store.load(key: song.overlayKey)
        require(reloaded == plain, "selected lyrics survive reopen")
        print("PASS: cancellation, latest search, persisted selection and line-state replacement")
        print("PASS: LRC parsing/seek/gaps, sync priority, persistence, HTTP handling, MP3 v2.3/v2.4 and FLAC lossless tag replacement, unsafe-file rejection")
        if CommandLine.arguments.count == 3 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            try LyricsTagEditor.embed(lrc, url: url, root: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("PASS: external audio fixture embedded")
        }
    }
}

final class LyricsStubProtocol: URLProtocol, @unchecked Sendable {
    static var payload = Data()
    static var status = 200
    static var lastURL: URL?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastURL = request.url
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let payload = Self.payload
        let delay = request.url!.absoluteString.contains("track_name=slow") ? 0.2 : 0
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            lock.lock(); defer { lock.unlock() }
            guard !stopped else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: payload)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    private let lock = NSLock()
    private var stopped = false
    override func stopLoading() { lock.lock(); stopped = true; lock.unlock() }
}
