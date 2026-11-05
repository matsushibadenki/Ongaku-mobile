import Foundation

/// Browser searches only. These sites do not supply the app's stored LRC records.
nonisolated enum JapaneseLyricsSite: String, CaseIterable, Identifiable, Sendable {
    case utaNet, utaTen, genius, smule
    var id: String { rawValue }
    var name: String {
        switch self {
        case .utaNet: "歌ネット"
        case .utaTen: "UtaTen"
        case .genius: "Genius"
        case .smule: "Smule"
        }
    }

    func searchURL(title: String, artist: String) -> URL? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        var url: URLComponents
        switch self {
        case .utaNet:
            url = URLComponents(string: "https://www.uta-net.com/search/")!
            url.queryItems = [
                URLQueryItem(name: "Aselect", value: title.isEmpty ? "1" : "2"),
                URLQueryItem(name: "Bselect", value: "3"),
                URLQueryItem(name: "Keyword", value: title.isEmpty ? artist : title)
            ]
        case .utaTen:
            url = URLComponents(string: "https://utaten.com/lyric/search")!
            url.queryItems = [URLQueryItem(name: "title", value: title), URLQueryItem(name: "artist_name", value: artist)]
        case .genius, .smule:
            url = URLComponents(string: self == .genius ? "https://genius.com/search" : "https://www.smule.com/search")!
            let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
            url.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        // Query endpoints use form-style decoding where a literal + means a space.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url
    }
}
