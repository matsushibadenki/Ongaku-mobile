import Foundation

nonisolated final class GoogleDriveLibraryStore: @unchecked Sendable {
    static let shared = GoogleDriveLibraryStore()
    static let urlScheme = "ongaku-google-drive"

    private let lock = NSLock()
    private let defaultsKey = "googleDrive.audioFiles.v1"
    private(set) var files: [GoogleDriveAudioFile] {
        get { lock.withLock { storedFiles } }
        set { lock.withLock { storedFiles = newValue } }
    }
    private var storedFiles: [GoogleDriveAudioFile]

    private init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([GoogleDriveAudioFile].self, from: data) {
            storedFiles = decoded
        } else {
            storedFiles = []
        }
    }

    func replace(with files: [GoogleDriveAudioFile]) {
        let unique = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { _, newest in newest })
            .values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.files = unique
        if let data = try? JSONEncoder().encode(unique) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func localTracks() -> [LocalTrackMetadata] {
        files.compactMap { file in
            guard let url = Self.url(for: file.id) else { return nil }
            return LocalTrackMetadata(
                url: url,
                title: URL(fileURLWithPath: file.name).deletingPathExtension().lastPathComponent,
                artist: L10n.tr("library.google_drive.unknown_artist"),
                album: "Google Drive",
                duration: 0,
                trackNumber: nil,
                discNumber: nil
            )
        }
    }

    func byteSource(for url: URL) -> GoogleDriveAudioByteSource? {
        guard url.scheme == Self.urlScheme,
              let id = url.pathComponents.last,
              let file = files.first(where: { $0.id == id }) else { return nil }
        return GoogleDriveAudioByteSource(file: file, tokenProvider: GoogleOAuthTokenStore.shared)
    }

    private static func url(for id: String) -> URL? {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "file"
        components.path = "/" + id
        return components.url
    }
}
