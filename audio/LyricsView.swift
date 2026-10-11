import SwiftUI

struct NowPlayingLyricsView: View {
    @ObservedObject var player: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Group {
                if let song = player.lyricsPlaybackSong {
                    SongLyricsView(song: song, currentTime: player.lyricsPlaybackTime) { time in
                        player.seekLyrics(to: time, songKey: song.overlayKey)
                    }
                    .id(song.overlayKey)
                    .toolbar {
                        ToolbarItem(placement: .bottomBar) {
                            Button { player.togglePlayback() } label: {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .frame(width: 44, height: 44)
                            }
                            .accessibilityLabel(L10n.tr(player.isPlaying ? "lyrics.pause" : "lyrics.play"))
                        }
                    }
                } else {
                    ContentUnavailableView(L10n.tr("lyrics.no_track"), systemImage: "music.note")
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button(L10n.tr("common.close")) { dismiss() } }
            }
        }
        .tint(player.accentColor)
        .preferredColorScheme(.dark)
    }
}

struct SongLyricsView: View {
    let song: SystemSong
    var currentTime: TimeInterval? = nil
    var seek: ((TimeInterval) -> Void)? = nil
    @StateObject private var model = LyricsViewModel()
    @State private var showingSearch = false
    @State private var following = true
    @State private var canEmbed = false

    private var activeID: Int? {
        currentTime.flatMap { LRCParser.activeLine(in: model.lines, at: $0) }
    }

    var body: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(song.title).font(.headline).fixedSize(horizontal: false, vertical: true)
                Text(song.artist).font(.subheadline).foregroundStyle(.secondary)
                if model.record != nil {
                    Text(L10n.tr(model.lines.isEmpty ? "lyrics.plain" : "lyrics.synced"))
                        .font(.caption).foregroundStyle(.tint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)

            if model.loading { ProgressView().padding() }
            else if let record = model.record {
                if record.instrumental && model.lines.isEmpty && record.text.isEmpty {
                    ContentUnavailableView(L10n.tr("lyrics.instrumental"), systemImage: "pianokeys")
                } else if !model.lines.isEmpty {
                    syncedLyrics
                } else {
                    ScrollView {
                        Text(record.text).font(.title3).lineSpacing(10).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 20)
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(L10n.tr("lyrics.empty"), systemImage: "text.quote")
                } description: { Text(L10n.tr("lyrics.empty.detail")) } actions: {
                    Button(L10n.tr("lyrics.search.title")) { showingSearch = true }.buttonStyle(.borderedProminent)
                }
            }

            if let error = model.error { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal, 16) }
            if let notice = model.notice { Text(notice).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16) }
            if let record = model.record {
                VStack(spacing: 8) {
                    if record.id >= 0 {
                        Link("LRCLIB", destination: URL(string: "https://lrclib.net")!).font(.caption)
                    }
                    if canEmbed && !record.text.isEmpty {
                        Button { Task { await model.embed(song: song, root: LocalMediaManager.shared.libraryDirectoryURL) } } label: {
                            Label(L10n.tr("lyrics.embed"), systemImage: "square.and.arrow.down")
                        }
                        .buttonStyle(.bordered).disabled(model.saving)
                        Text(L10n.tr("lyrics.embed.detail")).font(.caption).foregroundStyle(.secondary)
                    } else { Text(L10n.tr("lyrics.app_only")).font(.caption).foregroundStyle(.secondary) }
                    if model.saving { ProgressView() }
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
            }
        }
        .padding(.top, 12)
        .background(Theme.background)
        .navigationTitle(L10n.tr("lyrics.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { showingSearch = true } label: { Image(systemName: "magnifyingglass") }
                    .accessibilityLabel(L10n.tr("lyrics.search.title"))
                    .disabled(model.loading || model.saving)
            }
        }
        .task(id: song.overlayKey) {
            canEmbed = LyricsTagEditor.canEmbed(url: song.url, root: LocalMediaManager.shared.libraryDirectoryURL)
            await model.load(song: song)
        }
        .onChange(of: model.record) { _, _ in following = true }
        .sheet(isPresented: $showingSearch) { LyricsSearchView(song: song, model: model) }
    }

    private var syncedLyrics: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(model.lines) { line in
                            Button {
                                if let seek { following = true; seek(line.time) }
                            } label: {
                                Text(line.text.isEmpty ? "♪" : line.text)
                                    .font(.title3.weight(line.id == activeID ? .bold : .regular))
                                    .foregroundStyle(line.id == activeID ? Color.accentColor : .secondary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16).padding(.vertical, 8)
                                    .background(line.id == activeID ? Color.accentColor.opacity(0.10) : .clear)
                            }
                            .buttonStyle(.plain).disabled(seek == nil)
                            .accessibilityAddTraits(line.id == activeID ? .isSelected : [])
                            .id(line.id)
                        }
                    }.padding(.vertical, 32)
                }
                .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in following = false })
                if !following && currentTime != nil {
                    Button(L10n.tr("lyrics.follow")) {
                        following = true
                        if let activeID { withAnimation { proxy.scrollTo(activeID, anchor: .center) } }
                    }.buttonStyle(.bordered).padding(8)
                }
            }
            .onChange(of: activeID, initial: true) { _, id in
                guard following, let target = id ?? model.lines.first?.id else { return }
                withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }
}

struct LyricsSearchView: View {
    let song: SystemSong
    @ObservedObject var model: LyricsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var artist: String
    @State private var candidate: LyricsRecord?

    init(song: SystemSong, model: LyricsViewModel) {
        self.song = song; self.model = model
        _title = State(initialValue: song.title); _artist = State(initialValue: song.artist)
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField(L10n.tr("lyrics.track"), text: $title)
                    TextField(L10n.tr("lyrics.artist"), text: $artist)
                    Button(L10n.tr("lyrics.search")) { search() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.searching)
                } footer: { Text(L10n.tr("lyrics.search.detail")) }
                Section {
                    ForEach(JapaneseLyricsSite.allCases) { site in
                        if let url = site.searchURL(title: title, artist: artist) {
                            Link(destination: url) {
                                HStack {
                                    Text(site.name)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                }
                            }
                            .accessibilityLabel(L10n.tr("lyrics.web.open", site.name))
                        } else {
                            Text(site.name).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text(L10n.tr("lyrics.web.title")) }
                  footer: { Text(L10n.tr("lyrics.web.detail")) }
                if model.searching { ProgressView() }
                if let error = model.error { Text(error).foregroundStyle(.red) }
                if model.searched && model.results.isEmpty { Text(L10n.tr("lyrics.no_results")) }
                ForEach(model.results) { result in
                    Button { candidate = result } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(result.trackName).font(.headline).foregroundStyle(.primary)
                            Text(L10n.joinedMetadata([result.artistName, result.albumName]))
                                .font(.subheadline).foregroundStyle(.secondary)
                            Text("\(L10n.tr(result.isSynced ? "lyrics.synced" : (result.instrumental ? "lyrics.instrumental" : "lyrics.plain"))) · \(Int(result.duration) / 60):\(String(format: "%02d", Int(result.duration) % 60))")
                                .font(.caption).foregroundStyle(.tint)
                        }.padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(L10n.tr("lyrics.search.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.tr("common.close")) { dismiss() } } }
            .sheet(item: $candidate) { record in
                NavigationStack {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(record.trackName).font(.headline)
                            Text(L10n.joinedMetadata([record.artistName, record.albumName])).foregroundStyle(.secondary)
                            Text(record.instrumental && record.text.isEmpty ? L10n.tr("lyrics.instrumental") :
                                    (record.isSynced ? record.lines.map(\.text).joined(separator: "\n") : record.text))
                                .lineSpacing(8).textSelection(.enabled)
                            if let error = model.error { Text(error).foregroundStyle(.red) }
                            Button(L10n.tr("lyrics.use")) {
                                Task {
                                    if await model.select(record, song: song) { candidate = nil; dismiss() }
                                }
                            }.buttonStyle(.borderedProminent).disabled(model.saving)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 16).padding(.vertical, 20)
                    }
                    .navigationTitle(L10n.tr("lyrics.preview"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.tr("common.close")) { candidate = nil } } }
                }
            }
            .onDisappear { model.cancelSearch() }
        }
    }
    private func search() { model.search(title: title, artist: artist, duration: song.duration) }
}

struct LyricsView_Previews: PreviewProvider {
    static var previews: some View {
        let song = SystemSong(id: 1, title: "A song with a longer title", artist: "Artist", album: "Album",
                              artistID: nil, albumID: nil, discNumber: nil, trackNumber: nil, duration: 180, url: nil)
        Group {
            NavigationStack { SongLyricsView(song: song) }.previewDevice("iPhone SE (3rd generation)")
            NavigationStack { SongLyricsView(song: song) }.previewDevice("iPhone 16 Pro Max")
        }.preferredColorScheme(.dark)
    }
}
