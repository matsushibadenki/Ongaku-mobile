import Foundation
import Combine
import AVFoundation

@MainActor
final class LyricsViewModel: ObservableObject {
    @Published private(set) var record: LyricsRecord?
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var results: [LyricsRecord] = []
    @Published private(set) var loading = false
    @Published private(set) var searching = false
    @Published private(set) var saving = false
    @Published private(set) var searched = false
    @Published private(set) var timingOffsetMilliseconds = 0
    @Published var error: String?
    @Published var notice: String?
    private var searchTask: Task<Void, Never>?
    private var searchID = UUID()
    private let store: LyricsStore
    private let client: LRCLIBClient
    private var loadedKey: String?
    private var loadID = UUID()
    private var timingSaveID = UUID()
    private var timingSaveTask: Task<Void, Never>?

    init(store: LyricsStore = .shared, client: LRCLIBClient = LRCLIBClient()) {
        self.store = store; self.client = client
    }
    deinit { searchTask?.cancel() }

    func load(song: SystemSong) async {
        let id = UUID(); loadID = id; loadedKey = song.overlayKey
        cancelSearch()
        record = nil; lines = []; timingOffsetMilliseconds = 0; error = nil; notice = nil
        loading = true
        defer { if loadID == id { loading = false } }
        do {
            await timingSaveTask?.value
            let offset = (try? await store.loadTiming(key: song.overlayKey)) ?? 0
            try Task.checkCancellation()
            guard loadID == id else { return }
            timingOffsetMilliseconds = offset
            if let saved = try await store.load(key: song.overlayKey) {
                try Task.checkCancellation()
                guard loadID == id else { return }
                install(saved); return
            }
            guard let url = song.url, url.isFileURL else { return }
            let embedded = await Task.detached(priority: .utility) { try? LyricsTagEditor.read(url: url) }.value
            let text: String?
            if let embedded { text = embedded }
            else { text = try? await AVURLAsset(url: url).load(.lyrics) }
            try Task.checkCancellation()
            guard loadID == id else { return }
            if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { install(.embedded(text)) }
        } catch is CancellationError { }
        catch { if loadID == id { self.error = error.localizedDescription } }
    }

    func setTimingOffset(_ milliseconds: Int) {
        guard let key = loadedKey else { return }
        let value = LyricsTiming.normalized(milliseconds)
        timingOffsetMilliseconds = value
        timingSaveTask?.cancel()
        let request = UUID(); timingSaveID = request
        timingSaveTask = Task { [weak self, store] in
            guard !Task.isCancelled else { return }
            do { try await store.saveTiming(value, key: key) }
            catch {
                guard let self, self.loadedKey == key, self.timingSaveID == request else { return }
                self.error = error.localizedDescription
            }
        }
    }

    func waitForTimingSave() async { await timingSaveTask?.value }

    func search(title: String, artist: String, duration: Double) {
        cancelSearch()
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let id = UUID(); searchID = id
        searching = true; searched = false; results = []; error = nil
        let client = client
        searchTask = Task { [weak self] in
            do {
                let records = try await client.search(title: title, artist: artist.trimmingCharacters(in: .whitespacesAndNewlines))
                try Task.checkCancellation()
                guard let self, self.searchID == id else { return }
                self.results = LyricsRecord.ranked(records, duration: duration)
                self.searching = false; self.searched = true
            } catch {
                guard let self, self.searchID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.searching = false
            }
        }
    }
    func cancelSearch() {
        searchID = UUID(); searchTask?.cancel(); searchTask = nil; searching = false
    }
    func select(_ record: LyricsRecord, song: SystemSong) async -> Bool {
        guard !saving else { return false }
        saving = true; error = nil; notice = nil
        defer { saving = false }
        do {
            try await store.save(record, key: song.overlayKey)
            guard loadedKey == song.overlayKey else { return false }
            install(record); notice = L10n.tr("lyrics.saved")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func embed(song: SystemSong, root: URL) async {
        guard !saving, let record, !record.text.isEmpty, let url = song.url else { return }
        saving = true; error = nil; notice = nil
        defer { saving = false }
        do {
            try await Task.detached(priority: .utility) {
                try LyricsTagEditor.embed(record.text, url: url, root: root)
            }.value
            notice = L10n.tr("lyrics.embedded")
        } catch { self.error = error.localizedDescription }
    }
    private func install(_ record: LyricsRecord) { self.record = record; lines = record.lines }
}

