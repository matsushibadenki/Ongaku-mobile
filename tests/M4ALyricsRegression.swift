import Foundation
import AVFoundation

@main
struct M4ALyricsRegression {
    static let text = "[00:00.00]Original validation verse\n[00:00.50]日本語と简体中文のテスト\n[00:00.75]A & B + C"
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count >= 3 else { fatalError("file and root required") }
        let file = URL(fileURLWithPath: arguments[1]), root = URL(fileURLWithPath: arguments[2])
        let before = try Data(contentsOf: file)
        if arguments.contains("--reject") {
            do { try LyricsTagEditor.embed(text, url: file, root: root); fatalError("unsupported MP4 accepted") }
            catch { }
            guard try Data(contentsOf: file) == before else { fatalError("rejected original changed") }
            print("PASS: rejected \(file.lastPathComponent) without changing original")
            return
        }
        try LyricsTagEditor.embed(text, url: file, root: root)
        guard try LyricsTagEditor.read(url: file) == text else { fatalError("M4A lyric roundtrip") }
        let first = try Data(contentsOf: file)
        try LyricsTagEditor.embed(text, url: file, root: root)
        guard try Data(contentsOf: file) == first else { fatalError("repeat embedding grew or changed file") }
        if !arguments.contains("--structural-only") {
            let appleText = try await AVURLAsset(url: file).load(.lyrics)
            guard appleText == text else { fatalError("AVFoundation did not read the embedded lyric") }
        }
        for site in JapaneseLyricsSite.allCases {
            let url = site.searchURL(title: "日本語 A+B & #?", artist: "歌手/名")!
            guard url.scheme == "https", url.fragment == nil, url.absoluteString.contains("%2B") else { fatalError("unsafe search URL") }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
            guard items.contains(where: { $0.value == "日本語 A+B & #?" }) else { fatalError("search text changed") }
            guard site.searchURL(title: "  ", artist: "\n") == nil else { fatalError("empty search") }
            guard site.searchURL(title: "", artist: "歌手") != nil else { fatalError("artist-only search") }
        }
        print("PASS: \(file.lastPathComponent), Unicode LRC, repeated write, Japanese search URL encoding")
    }
}
