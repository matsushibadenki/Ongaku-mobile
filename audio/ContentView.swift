//
//  ContentView.swift
//  audio
//
//  Created by Antigravity on 2026/04/07.
//

import SwiftUI
import Combine
import MusicKit
import UniformTypeIdentifiers

private enum RootTab: Hashable {
    case nowPlaying, library, effects, search
}

private enum SearchScope: String, CaseIterable, Identifiable {
    case all, playlists, artists, albums, songs
    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return L10n.tr("search.scope.all")
        case .playlists: return L10n.tr("library.playlists")
        case .artists: return L10n.tr("library.artists")
        case .albums: return L10n.tr("library.albums")
        case .songs: return L10n.tr("library.songs")
        }
    }
}

private enum LibraryCategory: String, CaseIterable, Identifiable {
    case playlists, artists, albums, songs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playlists: return L10n.tr("library.playlists")
        case .artists: return L10n.tr("library.artists")
        case .albums: return L10n.tr("library.albums")
        case .songs: return L10n.tr("library.songs")
        }
    }
}

private let bottomTabBarContentInset: CGFloat = 132

private extension View {
    func reservingTabBarSpace() -> some View {
        safeAreaInset(edge: .bottom) {
            Color.clear
                .frame(height: bottomTabBarContentInset)
        }
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let player: AudioPlayerViewModel
    @State private var accentColor: Color
    @State private var errorMessage: String?
    @State private var presentedErrorMessage: String?
    @State private var selectedTab: RootTab = .nowPlaying
    @State private var artworkMode: ArtworkMode = .thumbnail
    @State private var isShowingSettings = false
    @State private var isShowingAppearance = false
    @State private var isShowingNowPlayingLyrics = false
    @State private var isShowingDesktopSync = false
    @State private var libraryPath: [LibraryRoute] = []
    @State private var searchPath: [LibraryRoute] = []
    @State private var pendingAlbumNavigation: SystemAlbum?
    @State private var isAlbumEnteringFromLeading = false
    @State private var hasPreparedEffectsScreen = false
    @State private var shouldRenderEffectsControls = false
    @State private var effectsControlsRenderID = UUID()
    @State private var pendingEffectsActivationWorkItem: DispatchWorkItem?
    
    init(player: AudioPlayerViewModel) {
        self.player = player
        _accentColor = State(initialValue: player.accentColor)
        _errorMessage = State(initialValue: player.errorMessage)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = .clear
        appearance.titleTextAttributes = [.foregroundColor: UIColor.label]
        appearance.largeTitleTextAttributes = [.foregroundColor: UIColor.label]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
    
    var body: some View {
        GeometryReader { viewport in
            let safeFrame = viewport.frame(in: .global)
            let vuFrame = CGRect(x: safeFrame.minX - viewport.safeAreaInsets.leading,
                                 y: safeFrame.minY - viewport.safeAreaInsets.top,
                                 width: safeFrame.width + viewport.safeAreaInsets.leading + viewport.safeAreaInsets.trailing,
                                 height: safeFrame.height + viewport.safeAreaInsets.top + viewport.safeAreaInsets.bottom)
            VStack(spacing: 0) {
                RetainedTabContent(selection: selectedTab) { tab in
                    switch tab {
                    case .nowPlaying:
                        // NOW PLAYING
                        NowPlayingView(player: player, artworkMode: $artworkMode, onGoToAlbum: { album in
                            openNowPlayingAlbum(album, fromArtworkSwipe: false)
                        }, onSwipeUpToAlbum: { album in
                            openNowPlayingAlbum(album, fromArtworkSwipe: true)
                        }, vuScreenFrame: vuFrame)

                    case .library:
                        // Navigation owners do not observe playback telemetry. Observed
                        // content sits inside each stack, below destination registration.
                        GeometryReader { geometry in
                            NavigationStack(path: $libraryPath) {
                                LibraryTabContent(player: player, onPlay: { selectedTab = .nowPlaying })
                                    .toolbarBackground(.hidden, for: .navigationBar)
                                    .toolbar { settingsToolbar(for: .library) }
                                    .navigationDestination(for: LibraryRoute.self) { route in
                                        LibraryDestinationView(route: route, player: player,
                                                               onPlay: { selectedTab = .nowPlaying })
                                    }
                            }
                            .offset(x: isAlbumEnteringFromLeading ? -geometry.size.width : 0)
                        }
                    case .effects:
                        NavigationStack {
                            EffectsTabContent(player: player,
                                              isPresented: selectedTab == .effects,
                                              shouldRenderControls: shouldRenderEffectsControls,
                                              controlsRenderID: effectsControlsRenderID)
                                .toolbarBackground(.hidden, for: .navigationBar)
                                .toolbar { settingsToolbar(for: .effects) }
                        }
                    case .search:
                        NavigationStack(path: $searchPath) {
                            SearchTabContent(player: player, onPlay: { selectedTab = .nowPlaying })
                                .toolbarBackground(.hidden, for: .navigationBar)
                                .toolbar { settingsToolbar(for: .search) }
                                .navigationDestination(for: LibraryRoute.self) { route in
                                    LibraryDestinationView(route: route, player: player,
                                                           onPlay: { selectedTab = .nowPlaying })
                                }
                        }
                    }
                }
                // The custom menu is the only tab bar. The content container
                // receives the remaining height above the fixed controls.
                VStack(spacing: 16) {
                    if selectedTab == .nowPlaying {
                        VStack(spacing: 4) {
                            PlaybackControlsView(player: player)
                            PlaybackModeButtonsView(player: player, onLyrics: { isShowingNowPlayingLyrics = true })
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                    }
                    CustomTabBar(selectedTab: $selectedTab, accentColor: accentColor, onAppearance: { isShowingAppearance = true })
                }
                .background {
                    if !(selectedTab == .nowPlaying && artworkMode == .vuMeter) {
                        AppBackground().ignoresSafeArea()
                    }
                }
            }
            .background {
                if selectedTab == .nowPlaying && artworkMode == .vuMeter {
                    NowPlayingVUBackground(player: player).ignoresSafeArea()
                } else {
                    AppBackground().ignoresSafeArea()
                }
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
            .environment(\.appBackgroundFrame, vuFrame)
        }
        .preferredColorScheme(Theme.appearance.colorScheme)
        .tint(accentColor)
        .alert(L10n.tr("common.error"), isPresented: errorBinding) {
            Button(L10n.tr("common.ok"), role: .cancel) { dismissPresentedError() }
        } message: {
            Text(presentedErrorMessage ?? "")
        }
        .sheet(isPresented: $isShowingNowPlayingLyrics) {
            NowPlayingLyricsView(player: player)
        }
        .sheet(isPresented: $isShowingAppearance) {
            AppearanceView()
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(player: player, isShowing: $isShowingSettings)
        }
        .sheet(isPresented: $isShowingDesktopSync) {
            DesktopSyncView()
        }
        .onAppear {
            player.startInitialBootstrapIfNeeded()
            scheduleEffectsPresentationUpdate()
        }
        .onChange(of: Theme.appearance) { _, _ in
            accentColor = player.accentColor
        }
        .onChange(of: selectedTab) { _, newValue in
            PlaybackDebugLogger.event("ui.navigation.tab selected=\(newValue)")
            if newValue != .library {
                pendingAlbumNavigation = nil
                isAlbumEnteringFromLeading = false
            }
            scheduleEffectsPresentationUpdate()
        }
        .onChange(of: scenePhase) { _, newPhase in
            scheduleEffectsPresentationUpdate()
        }
        .onReceive(player.$errorMessage.removeDuplicates()) { message in
            errorMessage = message
            if let message { PlaybackDebugLogger.warning("ui.playback.error received=\(message)") }
        }
        .task(id: PlaybackErrorPresentationRequest(message: errorMessage, isActive: scenePhase == .active)) {
            presentedErrorMessage = nil
            let request = PlaybackErrorPresentationRequest(message: errorMessage, isActive: scenePhase == .active)
            guard request.isActive, request.message != nil else { return }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard request.shouldPresent(currentMessage: player.errorMessage,
                                        isActive: scenePhase == .active, cancelled: Task.isCancelled) else { return }
            presentedErrorMessage = request.message
        }
        .onChange(of: libraryPath) { _, path in
            PlaybackDebugLogger.event("ui.navigation.path source=library depth=\(path.count)")
        }
        .onChange(of: searchPath) { _, path in
            PlaybackDebugLogger.event("ui.navigation.path source=search depth=\(path.count)")
        }
        .task(id: pendingAlbumNavigation?.id) {
            guard selectedTab == .library, let requestedAlbum = pendingAlbumNavigation else { return }
            // Let the destination NavigationStack mount before replacing its path.
            await Task.yield()
            guard !Task.isCancelled, selectedTab == .library else { return }
            let album = player.systemAlbums.first { $0.id == requestedAlbum.id } ?? requestedAlbum
            var path: [LibraryRoute] = []
            if let artist = player.findArtist(for: album) {
                path.append(.artist(artist))
            }
            path.append(.album(album))
            if isAlbumEnteringFromLeading {
                // The artwork gesture moves up the hierarchy. Prepare the
                // destination without the NavigationStack's forward push,
                // then reveal the retained Library stack from the left.
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    if libraryPath != path { libraryPath = path }
                }
                await Task.yield()
                guard !Task.isCancelled, selectedTab == .library else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    isAlbumEnteringFromLeading = false
                }
            } else if libraryPath != path {
                libraryPath = path
            }
            pendingAlbumNavigation = nil
        }
    }

    private func openNowPlayingAlbum(_ album: SystemAlbum, fromArtworkSwipe: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isAlbumEnteringFromLeading = fromArtworkSwipe && !reduceMotion
            pendingAlbumNavigation = album
            selectedTab = .library
        }
    }

    private func activateEffectsScreen() {
        guard selectedTab == .effects, scenePhase == .active else { return }

        player.setEffectScreenActive(true)

        if hasPreparedEffectsScreen {
            if !shouldRenderEffectsControls {
                shouldRenderEffectsControls = true
            }
            return
        }

        if shouldRenderEffectsControls {
            shouldRenderEffectsControls = false
        }
        let workItem = DispatchWorkItem {
            hasPreparedEffectsScreen = true
            shouldRenderEffectsControls = true
        }
        pendingEffectsActivationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55, execute: workItem)
    }

    private func scheduleEffectsPresentationUpdate() {
        pendingEffectsActivationWorkItem?.cancel()
        pendingEffectsActivationWorkItem = nil

        let shouldActivate = selectedTab == .effects && scenePhase == .active
        if shouldActivate {
            DispatchQueue.main.async {
                activateEffectsScreen()
            }
        } else {
            if shouldRenderEffectsControls && !hasPreparedEffectsScreen {
                shouldRenderEffectsControls = false
            }
            player.setEffectScreenActive(false)
        }
    }

    private func settingsToolbar(for tab: RootTab) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            if tab == .library {
                Button {
                    isShowingDesktopSync = true
                } label: {
                    Image(systemName: "desktopcomputer.and.arrow.down")
                        .foregroundStyle(player.accentColor)
                        .scaleEffect(0.70)
                        .offset(x: 3)
                }
                .accessibilityLabel(L10n.tr("settings.sync.title"))
            }
            Button { isShowingSettings = true } label: {
                Image(systemName: "person.crop.circle")
                    .scaleEffect(0.85)
                    .offset(x: tab == .library ? -3 : 0)
            }
        }
    }

    private func dismissPresentedError() {
        if player.errorMessage == presentedErrorMessage { player.errorMessage = nil }
        presentedErrorMessage = nil
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { presentedErrorMessage != nil }, set: { if !$0 { dismissPresentedError() } })
    }
}

private struct LibraryTabContent: View {
    let player: AudioPlayerViewModel
    let onPlay: () -> Void
    @StateObject private var updates: CoalescedViewUpdates
    @State private var selectedLibraryCategory: LibraryCategory = .artists
    @State private var isCreatingOngakuPlaylist = false
    @State private var newOngakuPlaylistName = ""

    init(player: AudioPlayerViewModel, onPlay: @escaping () -> Void) {
        self.player = player
        self.onPlay = onPlay
        _updates = StateObject(wrappedValue: CoalescedViewUpdates(events: player.libraryPresentationEvents))
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader
                .padding(.horizontal, Theme.horizontalPadding)

            if player.mediaLibraryAccess == .authorized || player.systemSongs.contains(where: { $0.url != nil }) {
                if player.isLibraryBootstrapInProgress {
                    HStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                            .tint(player.accentColor)
                        Text(L10n.tr("now_playing.loading.badge"))
                            .font(.appCaption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                }
                Picker(L10n.tr("library.picker"), selection: $selectedLibraryCategory) {
                    ForEach(LibraryCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: Theme.maxContentWidth)
                .padding(.horizontal, Theme.horizontalPadding)
                .padding(.vertical, 8)

                if player.isLibraryBootstrapInProgress && player.systemSongs.isEmpty {
                    LoadingStateView(
                        title: L10n.tr("now_playing.loading.title"),
                        subtitle: L10n.tr("now_playing.loading.subtitle"),
                        accentColor: player.accentColor
                    )
                } else {
                    libraryRoot
                        .scrollContentBackground(.hidden)
                }
            } else {
                MediaLibraryPermissionView(
                    state: player.mediaLibraryAccess,
                    accentColor: player.accentColor,
                    isLoading: player.isRequestingSystemLibraryAccess
                ) {
                    player.requestSystemLibraryAccess()
                }
            }
        }
        .background(AppBackground().ignoresSafeArea())
    }

    private var libraryHeader: some View {
        HStack(spacing: 10) {
            Text(L10n.tr("library.title"))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 5)
        .padding(.bottom, 10)
    }
    
    @ViewBuilder
    private var libraryRoot: some View {
        switch selectedLibraryCategory {
        case .playlists: playlistsView
        case .artists: artistsView
        case .albums: albumsView
        case .songs: songsView
        }
    }
    
    private var playlistsView: some View {
        Group {
            if player.systemPlaylists.isEmpty && player.ongakuPlaylists.isEmpty {
                VStack(spacing: 16) {
                    Button {
                        newOngakuPlaylistName = ""
                        isCreatingOngakuPlaylist = true
                    } label: {
                        Label(
                            L10n.tr("library.ongaku_playlist.create"),
                            systemImage: "plus.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(player.accentColor)

                    emptyStateView(message: L10n.tr("empty.playlists"))
                }
                .padding(.horizontal, 16)
            } else {
                List {
                    Section {
                        Button {
                            newOngakuPlaylistName = ""
                            isCreatingOngakuPlaylist = true
                        } label: {
                            Label(L10n.tr("library.ongaku_playlist.create"), systemImage: "plus.circle.fill")
                                .foregroundStyle(player.accentColor)
                        }
                    }

                    if !player.ongakuPlaylists.isEmpty {
                        Section(L10n.tr("library.ongaku_playlist.section")) {
                            ForEach(player.ongakuPlaylists) { playlist in
                                NavigationLink(value: LibraryRoute.ongakuPlaylist(playlist)) {
                                    playlistRow(
                                        name: playlist.name,
                                        count: player.songs(in: playlist).count,
                                        systemImage: "waveform.badge.plus"
                                    )
                                }
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        player.deleteOngakuPlaylist(playlist)
                                    } label: {
                                        Label(L10n.tr("common.delete"), systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }

                    if !player.systemPlaylists.isEmpty {
                        Section(L10n.tr("library.music_playlist.section")) {
                            ForEach(player.systemPlaylists) { playlist in
                                NavigationLink(value: LibraryRoute.playlist(playlist)) {
                                    playlistRow(
                                        name: playlist.name,
                                        count: playlist.songCount,
                                        systemImage: "music.note.list"
                                    )
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .reservingTabBarSpace()
            }
        }
        .alert(L10n.tr("library.ongaku_playlist.create"), isPresented: $isCreatingOngakuPlaylist) {
            TextField(L10n.tr("library.ongaku_playlist.name"), text: $newOngakuPlaylistName)
            Button(L10n.tr("common.create")) {
                _ = player.createOngakuPlaylist(named: newOngakuPlaylistName)
            }
            Button(L10n.tr("common.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.tr("library.ongaku_playlist.create_description"))
        }
    }

    private func playlistRow(name: String, count: Int, systemImage: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(player.accentColor)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                MarqueeView(
                    text: name,
                    font: .headline,
                    color: Theme.textPrimary
                )
                Text(L10n.songCount(count))
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
    }
    
    private var artistsView: some View {
        Group {
            if player.systemArtists.isEmpty {
                emptyStateView(message: L10n.tr("empty.artists"))
            } else {
                List(player.systemArtists) { artist in
                    NavigationLink(value: LibraryRoute.artist(artist)) {
                        HStack(spacing: 16) {
                            // アーティストサムネイル（円形）
                            LibraryArtworkImage(
                                fallback: player.artistArtwork(for: artist, size: CGSize(width: 80, height: 80)),
                                urls: player.songs(for: artist).compactMap(\.url).filter(\.isFileURL),
                                placeholder: "person.fill"
                            )
                            .frame(width: 44, height: 44)
                            .clipShape(Circle())
                            .overlay(Circle().stroke(Theme.border, lineWidth: 1))

                            VStack(alignment: .leading, spacing: 4) {
                                MarqueeView(text: artist.name, font: .system(size: 17, weight: .regular), color: Theme.textPrimary)
                                Text(L10n.albumAndSongCount(albums: artist.albumCount, songs: artist.songCount))
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .reservingTabBarSpace()
            }
        }
    }
    
    private var albumsView: some View {
        Group {
            if player.systemAlbums.isEmpty {
                emptyStateView(message: L10n.tr("empty.albums"))
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                        ForEach(player.systemAlbums) { album in
                            NavigationLink(value: LibraryRoute.album(album)) {
                                AlbumTileView(album: album, artwork: player.albumArtwork(for: album), artworkURLs: player.albumArtworkURLs(for: album))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.vertical, 20)
                    .padding(.bottom, bottomTabBarContentInset)
                    .frame(maxWidth: .infinity)
                }
                .reservingTabBarSpace()
            }
        }
    }
    
    private var songsView: some View {
        Group {
            if player.systemSongs.isEmpty {
                emptyStateView(message: L10n.tr("empty.songs"))
            } else {
                List(player.systemSongs) { song in
                    SongRowView(
                        song: song,
                        isActive: player.isSongActive(song),
                        isPlaying: player.isPlaying,
                        isProcessing: player.isLoading,
                        artwork: player.songArtwork(for: song),
                        accentColor: player.accentColor,
                        overlay: player.overlay(for: song),
                        ongakuPlaylists: player.ongakuPlaylists,
                        onFavoriteChange: { player.setFavorite($0, for: song) },
                        onRatingChange: { player.setRating($0, for: song) },
                        onTagsChange: { player.setDisplayTags($0, for: song) },
                        onAddToPlaylist: { player.add(song, to: $0) },
                        onPlay: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                player.playSystemSong(song)
                                onPlay()
                            }
                        }
                    )
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .reservingTabBarSpace()
            }
        }
    }
    
    private func emptyStateView(message: String) -> some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 30, weight: .thin))
                .foregroundStyle(Theme.textSecondary.opacity(0.3))
            Text(message)
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
        }
        .frame(maxWidth: Theme.maxContentWidth)
    }

}

private struct SearchTabContent: View {
    @Environment(\.openURL) private var openURL
    let player: AudioPlayerViewModel
    let onPlay: () -> Void
    @StateObject private var updates: CoalescedViewUpdates
    @State private var selectedSearchScope: SearchScope = .songs
    @State private var isSearchPresented = false

    init(player: AudioPlayerViewModel, onPlay: @escaping () -> Void) {
        self.player = player
        self.onPlay = onPlay
        _updates = StateObject(wrappedValue: CoalescedViewUpdates(events: player.searchPresentationEvents))
    }

    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()
            searchRoot
                .scrollContentBackground(.hidden)
                .scrollDismissesKeyboard(.interactively)
        }
        .navigationTitle(L10n.tr("search.title"))
        .searchable(text: Binding(get: { player.searchText }, set: { player.searchText = $0 }),
                    isPresented: $isSearchPresented,
                    prompt: L10n.tr("search.prompt"))
        .onSubmit(of: .search) { isSearchPresented = false }
        .onDisappear { isSearchPresented = false }
    }

    private var searchRoot: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(player.searchResultCountSummary)
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)

                    Picker(L10n.tr("search.scope.picker"), selection: $selectedSearchScope) {
                        ForEach(SearchScope.allCases) { scope in
                            Text(scope.title).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: Theme.maxContentWidth)

                    Button {
                        if let url = URL(string: "music://") { openURL(url) }
                    } label: {
                        Label(L10n.tr("search.open_music"), systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 4)
            }
            .listRowBackground(Color.clear)

            if !player.hasActiveSearch {
                Section(L10n.tr("search.section.discover")) {
                    Text(L10n.tr("search.cross_library_hint"))
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                        .padding(.vertical, 6)
                }
            }

            if player.mediaLibraryAccess == .authorized || player.systemSongs.contains(where: { $0.url != nil }) {
                if selectedSearchScope == .all || selectedSearchScope == .playlists {
                    Section(L10n.tr("library.playlists")) {
                        if player.filteredSystemPlaylists.isEmpty {
                            searchEmptyRow
                        } else {
                            ForEach(player.filteredSystemPlaylists.prefix(6)) { playlist in
                                NavigationLink(value: LibraryRoute.playlist(playlist)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "music.note.list")
                                            .foregroundStyle(player.accentColor)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(playlist.name)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(L10n.songCount(playlist.songCount))
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }

                if selectedSearchScope == .all || selectedSearchScope == .artists {
                    Section(L10n.tr("library.artists")) {
                        if player.filteredSystemArtists.isEmpty {
                            searchEmptyRow
                        } else {
                            ForEach(player.filteredSystemArtists.prefix(8)) { artist in
                                NavigationLink(value: LibraryRoute.artist(artist)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "person.crop.circle.fill")
                                            .foregroundStyle(player.accentColor)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(artist.name)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(L10n.albumAndSongCount(albums: artist.albumCount, songs: artist.songCount))
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }

                if selectedSearchScope == .all || selectedSearchScope == .albums {
                    Section(L10n.tr("library.albums")) {
                        if player.filteredSystemAlbums.isEmpty {
                            searchEmptyRow
                        } else {
                            ForEach(player.filteredSystemAlbums.prefix(8)) { album in
                                NavigationLink(value: LibraryRoute.album(album)) {
                                    HStack(spacing: 12) {
                                        Image(systemName: "square.stack.fill")
                                            .foregroundStyle(player.accentColor)
                                            .frame(width: 24)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(album.title)
                                                .foregroundStyle(Theme.textPrimary)
                                            Text(album.artist)
                                                .font(.caption)
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                    }
                                    .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                                }
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }

                if selectedSearchScope == .all || selectedSearchScope == .songs {
                    Section(L10n.tr("library.songs")) {
                        if player.filteredSystemSongs.isEmpty {
                            searchEmptyRow
                        } else {
                            ForEach(player.filteredSystemSongs.prefix(24)) { song in
                                SongRowView(
                                    song: song,
                                    isActive: player.isSongActive(song),
                                    isPlaying: player.isPlaying,
                                    isProcessing: player.isLoading,
                                    artwork: player.songArtwork(for: song),
                                    accentColor: player.accentColor,
                                    overlay: player.overlay(for: song),
                                    ongakuPlaylists: player.ongakuPlaylists,
                                    onFavoriteChange: { player.setFavorite($0, for: song) },
                                    onRatingChange: { player.setRating($0, for: song) },
                                    onTagsChange: { player.setDisplayTags($0, for: song) },
                                    onAddToPlaylist: { player.add(song, to: $0) },
                                    onPlay: {
                                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                            player.playSystemSong(song)
                                            onPlay()
                                        }
                                    }
                                )
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
            } else {
                Section(L10n.tr("search.section.local_library")) {
                    MediaLibraryPermissionInlineCard(
                        title: L10n.tr("search.local_library_locked"),
                        description: L10n.tr("search.local_library_locked_detail"),
                        accentColor: player.accentColor,
                        actionTitle: L10n.tr("permission.allow_access"),
                        isLoading: player.isRequestingSystemLibraryAccess,
                        action: { player.requestSystemLibraryAccess() }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                }
            }

            Section(L10n.tr("search.section.apple_music")) {
                if player.appleMusicAccessStatus != .authorized {
                    MediaLibraryPermissionInlineCard(
                        title: L10n.tr("apple_music.permission.title"),
                        description: L10n.tr("apple_music.permission.description"),
                        accentColor: player.accentColor,
                        actionTitle: L10n.tr("permission.allow_access"),
                        isLoading: player.isRequestingAppleMusicAccess,
                        action: { player.requestAppleMusicAccess() }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                    .listRowBackground(Color.clear)
                } else {
                    if let statusMessage = player.appleMusicStatusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(Color.orange.opacity(0.92))
                            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                            .padding(.vertical, 4)
                    }

                    if player.isSearchingAppleMusicCatalog {
                        HStack(spacing: 12) {
                            ProgressView()
                                .tint(player.accentColor)
                            Text(L10n.tr("apple_music.searching"))
                                .font(.caption)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                        .padding(.vertical, 6)
                    } else if !player.hasActiveSearch {
                        Text(L10n.tr("apple_music.search_hint"))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                            .padding(.vertical, 6)
                    } else if player.appleMusicCatalogAlbums.isEmpty && player.appleMusicCatalogSongs.isEmpty {
                        Text(L10n.tr("apple_music.empty"))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                            .padding(.vertical, 6)
                    } else {
                        if !player.appleMusicCatalogAlbums.isEmpty {
                            appleMusicSubsectionHeader(L10n.tr("library.albums"))
                            ForEach(player.appleMusicCatalogAlbums) { album in
                                AppleMusicCatalogAlbumRow(
                                    album: album,
                                    canAdd: player.canModifyAppleMusicLibrary,
                                    isAdding: player.isAddingAppleMusicItemIDs.contains(album.id),
                                    isAdded: player.addedAppleMusicItemIDs.contains(album.id),
                                    accentColor: player.accentColor,
                                    onAdd: { player.addAppleMusicAlbumToLibrary(album) }
                                )
                                .listRowInsets(EdgeInsets(top: 6, leading: Theme.horizontalPadding, bottom: 6, trailing: Theme.horizontalPadding))
                                .listRowBackground(Color.clear)
                            }
                        }

                        if !player.appleMusicCatalogSongs.isEmpty {
                            appleMusicSubsectionHeader(L10n.tr("library.songs"))
                            ForEach(player.appleMusicCatalogSongs) { song in
                                AppleMusicCatalogSongRow(
                                    song: song,
                                    canAdd: player.canModifyAppleMusicLibrary,
                                    isAdding: player.isAddingAppleMusicItemIDs.contains(song.id),
                                    isAdded: player.addedAppleMusicItemIDs.contains(song.id),
                                    accentColor: player.accentColor,
                                    onAdd: { player.addAppleMusicSongToLibrary(song) }
                                )
                                .listRowInsets(EdgeInsets(top: 6, leading: Theme.horizontalPadding, bottom: 6, trailing: Theme.horizontalPadding))
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .reservingTabBarSpace()
    }

    private func appleMusicSubsectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
            .padding(.top, 4)
    }

    private var searchEmptyRow: some View {
        Text(player.hasActiveSearch ? L10n.tr("search.empty.active") : L10n.tr("search.empty.idle"))
            .font(.caption)
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
            .padding(.vertical, 6)
    }
    

}

private struct EffectsTabContent: View {
    @ObservedObject var player: AudioPlayerViewModel
    let isPresented: Bool
    let shouldRenderControls: Bool
    let controlsRenderID: UUID
    @State private var isShowingModeHelp = false

    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()

            ScrollViewReader { proxy in
                ScrollView {
                    // This is a bounded set of controls, including a tall nested
                    // stack. Measure its actual height instead of restoring an
                    // offset against LazyVStack's estimates after tab changes.
                    VStack(spacing: 32) {
                        SectionHeader(
                            title: L10n.tr("effects.realtime_processing"),
                            subtitle: player.realtimeEffectsStatusText
                        )
                        .overlay(alignment: .topTrailing) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(player.accentColor)
                                .padding(.trailing, 16)
                                .padding(.top, 4)
                                .opacity(
                                    player.isEffectProcessing || player.isSpatialProcessing
                                        ? 1
                                        : 0
                                )
                                .accessibilityLabel(L10n.tr("effects.realtime_processing"))
                                .accessibilityHidden(
                                    !(player.isEffectProcessing || player.isSpatialProcessing)
                                )
                                .animation(
                                    .easeInOut(duration: 0.15),
                                    value: player.isEffectProcessing || player.isSpatialProcessing
                                )
                        }
                        .id("effects.top")

                        if !player.supportsRealtimeEffects {
                            HStack(spacing: 8) {
                                Text(player.realtimeEffectsAvailabilityDetail)
                                    .font(.appCaption())
                                    .foregroundStyle(Theme.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if player.canRetrySystemAssetRecovery {
                                    Button(action: player.retrySystemAssetRecovery) {
                                        Image(systemName: "arrow.clockwise")
                                            .frame(width: 44, height: 44)
                                    }
                                    .tint(player.accentColor)
                                    .accessibilityLabel(L10n.tr("effects.preparation.retry"))
                                    .help(L10n.tr("effects.preparation.retry"))
                                }
                            }
                            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                            .padding(.horizontal, 20)
                        }

                        if shouldRenderControls {
                            effectsControlsContent
                                .id(controlsRenderID)
                        } else {
                            VStack(spacing: 14) {
                                ProgressView()
                                    .tint(player.accentColor)
                                    .scaleEffect(0.8)
                                Text(L10n.tr("effects.preparing"))
                                    .font(.system(size: 13, weight: .light))
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: Theme.maxContentWidth)
                            .padding(.vertical, 36)
                            .background(Theme.secondaryBackground)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                        }

                        if !player.isLoading {
                            Text(player.localPlaybackFormatDescription)
                                .font(.appCaption())
                                .foregroundStyle(Theme.textSecondary.opacity(0.4))
                                .padding(.top, 10)
                                .frame(maxWidth: Theme.maxContentWidth)
                                .lineLimit(1)
                        }

                        Text(player.signalDiagnosticsSummary)
                            .font(.appCaption())
                            .foregroundStyle(Theme.textSecondary.opacity(0.55))
                            .frame(maxWidth: Theme.maxContentWidth)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        Text(player.audioRenderHealthSummary)
                            .font(.appCaption())
                            .foregroundStyle(
                                player.audioRenderHealth.isStalled
                                    ? Color.red
                                    : Theme.textSecondary.opacity(0.55)
                            )
                            .frame(maxWidth: Theme.maxContentWidth)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)

                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(L10n.tr("effects.auto_dsp.title"))
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text(player.selectedEffectPageTab == .off ? L10n.tr("effects.tab.off") : "\(Int(player.automaticDSPStrength * 100))%")
                                    .font(.system(size: 12, weight: .regular, design: .monospaced))
                                    .foregroundStyle(Theme.textSecondary)
                            }

                            AppearanceSlider(
                                value: Binding(
                                    get: { player.automaticDSPStrength },
                                    set: { player.setAutomaticDSPStrength($0) }
                                ),
                                in: 0...1.5, accent: player.accentColor
                            )
                            .tint(player.accentColor)
                            .accessibilityLabel(L10n.tr("effects.auto_dsp.title"))
                            .disabled(!player.supportsRealtimeEffects || player.selectedEffectPageTab == .off)

                            Picker("DSP", selection: Binding(
                                get: { player.automaticDSPVoicing },
                                set: { player.setAutomaticDSPVoicing($0) }
                            )) {
                                Text("Natural").tag(AutomaticDSPVoicing.natural)
                                Text("Reference").tag(AutomaticDSPVoicing.reference)
                                Text("Immersive").tag(AutomaticDSPVoicing.immersive)
                                Text("Safe").tag(AutomaticDSPVoicing.safe)
                            }
                            .pickerStyle(.segmented)
                            .disabled(!player.supportsRealtimeEffects || player.selectedEffectPageTab == .off)

                            Button {
                                player.toggleABReferenceMode()
                            } label: {
                                Label(
                                    player.isABReferenceMode ? "Reference" : "A/B Compare",
                                    systemImage: player.isABReferenceMode ? "waveform" : "arrow.left.arrow.right"
                                )
                                .frame(maxWidth: .infinity)
                                .padding(.horizontal)
                            }
                            .buttonStyle(.bordered)
                            .tint(player.isABReferenceMode ? player.accentColor : Theme.textSecondary)
                            .disabled(!player.supportsRealtimeEffects || player.selectedEffectPageTab == .off)

                            Text(player.automaticDSPSummary)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary.opacity(0.58))
                                .lineLimit(nil)
                                .multilineTextAlignment(.leading)
                        }
                        .padding(12)
                        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                        .background(Theme.secondaryBackground)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))

                        Text(player.effectAuditSummaryText)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundStyle(Theme.textSecondary.opacity(0.58))
                            .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
                            .lineLimit(nil)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.vertical, 10)
                    .padding(.bottom, 16)
                    .frame(maxWidth: .infinity)
                }
                .task(id: isPresented && shouldRenderControls) {
                    guard isPresented, shouldRenderControls else { return }
                    // Run after the retained tab (or initial deferred controls)
                    // mounts. Never recreate controls or reset on meter updates.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo("effects.top", anchor: .top)
                    }
                }
            }
        }
        .navigationTitle(L10n.tr("effects.title"))
    }

    private var effectsControlsContent: some View {
        VStack(spacing: 20) {
            HStack(spacing: 8) {
                EffectModeSelector(
                    selection: player.selectedEffectPageTab,
                    accentColor: player.accentColor,
                    onSelect: player.selectEffectPageTab
                )

                Button {
                    isShowingModeHelp = true
                } label: {
                    Image(systemName: "info.circle")
                        .frame(width: 44, height: 44)
                }
                .foregroundStyle(Theme.textSecondary)
                .buttonStyle(.plain)
                .accessibilityLabel(L10n.tr("effects.tab.accessibility_label"))
                .help(L10n.tr("effects.tab.selected_only_footer"))
                .popover(isPresented: $isShowingModeHelp) {
                    Text(L10n.tr("effects.tab.selected_only_footer"))
                        .font(.body)
                        .padding(20)
                        .presentationCompactAdaptation(.popover)
                }
            }
            .frame(maxWidth: Theme.maxContentWidth)

            if player.selectedEffectPageTab == .pro {
                HeadphoneSpatialCard(
                    isEnabled: player.headphoneSpatialSettings.isEnabled,
                    preset: player.headphoneSpatialSettings.preset,
                    spatial: player.headphoneSpatialSettings.spatial,
                    crossfeed: player.headphoneSpatialSettings.crossfeed,
                    isInteractive: player.supportsRealtimeEffects,
                    onToggle: { player.setHeadphoneSpatialEnabled($0) },
                    onPresetChange: { player.setHeadphoneHRTFPreset($0) },
                    onParameterChange: { key, value in
                        player.setHeadphoneSpatialParameter(value, key: key)
                    },
                    accentColor: player.accentColor
                )
            }

            ForEach(player.visibleEffectSettings) { effect in
                EffectCard(
                    kind: effect.kind,
                    isEnabled: effect.isEnabled,
                    parameters: effect.parameters,
                    isInteractive: player.supportsRealtimeEffects,
                    onToggle: { player.setEffectEnabled($0, for: effect.kind) },
                    onParameterChange: { key, value in
                        player.setEffectParameter(value, key: key, for: effect.kind)
                    },
                    accentColor: player.accentColor
                )
            }
        }
        // Keep hit targets and selection feedback stable during rapid taps.
        // Audio processing has its own ramps; it does not need a UI transition.
    }
    
}

private struct LibraryDestinationView: View {
    let route: LibraryRoute
    let player: AudioPlayerViewModel
    let onPlay: () -> Void
    @StateObject private var updates: CoalescedViewUpdates

    init(route: LibraryRoute, player: AudioPlayerViewModel, onPlay: @escaping () -> Void) {
        self.route = route
        self.player = player
        self.onPlay = onPlay
        _updates = StateObject(wrappedValue: CoalescedViewUpdates(events: player.libraryPresentationEvents))
    }

    var body: some View {
        switch route {
        case .artist(let artist):
            ArtistAlbumsView(artist: player.systemArtists.first { $0.id == artist.id } ?? artist,
                             player: player, updates: updates, onPlay: onPlay)
        case .album(let album):
            AlbumSongsView(album: player.systemAlbums.first { $0.id == album.id } ?? album,
                           player: player, updates: updates, onPlay: onPlay)
        case .playlist(let playlist):
            PlaylistSongsView(playlist: player.systemPlaylists.first { $0.id == playlist.id } ?? playlist,
                              player: player, updates: updates, onPlay: onPlay)
        case .ongakuPlaylist(let playlist):
            OngakuPlaylistSongsView(playlist: playlist, player: player, updates: updates, onPlay: onPlay)
        }
    }
}

// MARK: - Navigation Views

struct ArtistAlbumsView: View {
    let artist: SystemArtist
    let player: AudioPlayerViewModel
    @ObservedObject var updates: CoalescedViewUpdates
    let onPlay: () -> Void
    
    var body: some View {
        ZStack {
            AppBackground().ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                        ForEach(player.albums(for: artist)) { album in
                            NavigationLink(value: LibraryRoute.album(album)) {
                                AlbumTileView(album: album, artwork: player.albumArtwork(for: album), artworkURLs: player.albumArtworkURLs(for: album))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Theme.horizontalPadding)
                    .padding(.vertical, 20)
                    .padding(.bottom, bottomTabBarContentInset)
                }
                .frame(maxWidth: .infinity)
            }
            .reservingTabBarSpace()
        }
        .navigationTitle(artist.name)
    }
}

struct AlbumSongsView: View {
    let album: SystemAlbum
    let player: AudioPlayerViewModel
    @ObservedObject var updates: CoalescedViewUpdates
    let onPlay: () -> Void
    
    var body: some View {
        let songs = player.songs(for: album)
        ScrollViewReader { proxy in
            List {
                HeaderSection(album: album, artwork: player.albumArtwork(for: album), count: songs.count, artworkURLs: player.albumArtworkURLs(for: album))
                    .listRowBackground(Color.clear)
                
                Section(L10n.tr("album.track_list")) {
                    ForEach(songs) { song in
                        SongRowView(
                            song: song,
                            isActive: player.isSongActive(song),
                            isPlaying: player.isPlaying,
                            isProcessing: player.isLoading,
                            artwork: player.songArtwork(for: song),
                            accentColor: player.accentColor,
                            overlay: player.overlay(for: song),
                            ongakuPlaylists: player.ongakuPlaylists,
                            onFavoriteChange: { player.setFavorite($0, for: song) },
                            onRatingChange: { player.setRating($0, for: song) },
                            onTagsChange: { player.setDisplayTags($0, for: song) },
                            onAddToPlaylist: { player.add(song, to: $0) },
                            onPlay: {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                                    player.playSystemQueue(songs, startAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0, title: album.title)
                                    onPlay()
                                }
                            }
                        )
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .id(song.id)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppBackground().ignoresSafeArea())
            .listStyle(.plain)
            .reservingTabBarSpace()
            .navigationTitle(album.title)
            .onAppear {
                if let activeSong = songs.first(where: { player.isSongActive($0) }) {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation {
                            proxy.scrollTo(activeSong.id, anchor: .center)
                        }
                    }
                }
            }
        }
    }
}

struct PlaylistSongsView: View {
    let playlist: SystemPlaylist
    let player: AudioPlayerViewModel
    @ObservedObject var updates: CoalescedViewUpdates
    let onPlay: () -> Void
    
    var body: some View {
        let songs = player.songs(in: playlist)
        List(songs) { song in
            SongRowView(
                song: song,
                isActive: player.isSongActive(song),
                isPlaying: player.isPlaying,
                isProcessing: player.isLoading,
                artwork: player.songArtwork(for: song),
                accentColor: player.accentColor,
                overlay: player.overlay(for: song),
                ongakuPlaylists: player.ongakuPlaylists,
                onFavoriteChange: { player.setFavorite($0, for: song) },
                onRatingChange: { player.setRating($0, for: song) },
                onTagsChange: { player.setDisplayTags($0, for: song) },
                onAddToPlaylist: { player.add(song, to: $0) },
                onPlay: {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        player.playSystemQueue(songs, startAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0, title: playlist.name)
                        onPlay()
                    }
                }
            )
            .buttonStyle(.plain)
            .listRowBackground(Color.clear)
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground().ignoresSafeArea())
        .listStyle(.plain)
        .reservingTabBarSpace()
        .navigationTitle(playlist.name)
    }
}

struct OngakuPlaylistSongsView: View {
    let playlist: OngakuPlaylist
    let player: AudioPlayerViewModel
    @ObservedObject var updates: CoalescedViewUpdates
    let onPlay: () -> Void

    var body: some View {
        let currentPlaylist = player.ongakuPlaylist(id: playlist.id) ?? playlist
        let songs = player.songs(in: currentPlaylist)
        Group {
            if songs.isEmpty {
                ContentUnavailableView(
                    L10n.tr("library.ongaku_playlist.empty"),
                    systemImage: "music.note.list",
                    description: Text(L10n.tr("library.ongaku_playlist.empty_description"))
                )
            } else {
                List(songs) { song in
                    SongRowView(
                        song: song,
                        isActive: player.isSongActive(song),
                        isPlaying: player.isPlaying,
                        isProcessing: player.isLoading,
                        artwork: player.songArtwork(for: song),
                        accentColor: player.accentColor,
                        overlay: player.overlay(for: song),
                        ongakuPlaylists: player.ongakuPlaylists,
                        onFavoriteChange: { player.setFavorite($0, for: song) },
                        onRatingChange: { player.setRating($0, for: song) },
                        onTagsChange: { player.setDisplayTags($0, for: song) },
                        onAddToPlaylist: { player.add(song, to: $0) },
                        onPlay: {
                            player.playSystemQueue(
                                songs,
                                startAt: songs.firstIndex(where: { $0.id == song.id }) ?? 0,
                                title: currentPlaylist.name
                            )
                            onPlay()
                        }
                    )
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            player.remove(song, from: currentPlaylist.id)
                        } label: {
                            Label(L10n.tr("library.ongaku_playlist.remove"), systemImage: "minus.circle")
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground().ignoresSafeArea())
        .reservingTabBarSpace()
        .navigationTitle(currentPlaylist.name)
    }
}

// MARK: - Supporting Components

private struct MediaLibraryPermissionInlineCard: View {
    let title: String
    let description: String
    let accentColor: Color
    let actionTitle: String
    var isLoading = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(description)
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: action) {
                LoadingButtonLabel(
                    title: actionTitle,
                    isLoading: isLoading,
                    accentColor: Theme.onAccent
                )
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.onAccent)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(accentColor)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
        }
        .padding(18)
        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
        .background(Theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct AppleMusicCatalogSongRow: View {
    let song: AppleMusicCatalogSongResult
    let canAdd: Bool
    let isAdding: Bool
    let isAdded: Bool
    let accentColor: Color
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppleMusicArtworkView(url: song.artworkURL, accentColor: accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(song.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(song.artistName)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            AppleMusicAddButton(
                canAdd: canAdd,
                isAdding: isAdding,
                isAdded: isAdded,
                accentColor: accentColor,
                action: onAdd
            )
        }
        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
    }
}

private struct AppleMusicCatalogAlbumRow: View {
    let album: AppleMusicCatalogAlbumResult
    let canAdd: Bool
    let isAdding: Bool
    let isAdded: Bool
    let accentColor: Color
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AppleMusicArtworkView(url: album.artworkURL, accentColor: accentColor)

            VStack(alignment: .leading, spacing: 3) {
                Text(album.title)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(albumSubtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            AppleMusicAddButton(
                canAdd: canAdd,
                isAdding: isAdding,
                isAdded: isAdded,
                accentColor: accentColor,
                action: onAdd
            )
        }
        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
    }

    private var albumSubtitle: String {
        if let trackCount = album.trackCount, trackCount > 0 {
            return "\(album.artistName) • \(L10n.songCount(trackCount))"
        }
        return album.artistName
    }
}

private struct AppleMusicArtworkView: View {
    let url: URL?
    let accentColor: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.secondaryBackground)
                .frame(width: 48, height: 48)

            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .empty:
                        ProgressView()
                            .tint(accentColor)
                            .frame(width: 48, height: 48)
                    default:
                        Image(systemName: "music.note")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(accentColor.opacity(0.85))
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(accentColor.opacity(0.85))
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Theme.border, lineWidth: 1)
        )
    }
}

private struct AppleMusicAddButton: View {
    let canAdd: Bool
    let isAdding: Bool
    let isAdded: Bool
    let accentColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isAdding {
                    ProgressView()
                        .tint(Theme.onAccent)
                        .frame(width: 18, height: 18)
                } else if isAdded {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.onAccent)
                } else {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canAdd ? Theme.onAccent : Theme.textSecondary)
                }
            }
            .frame(width: 34, height: 34)
            .background(canAdd ? accentColor : Theme.secondaryBackground)
            .clipShape(Circle())
            .overlay(
                Circle()
                    .stroke(canAdd ? accentColor.opacity(0.22) : Theme.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canAdd || isAdding || isAdded)
    }
}

struct HeaderSection: View {
    let album: SystemAlbum
    let artwork: UIImage?
    let count: Int
    var artworkURLs: [URL] = []
    
    var body: some View {
        HStack(spacing: 20) {
            LibraryArtworkImage(fallback: artwork, urls: artworkURLs)
                .frame(width: 80, height: 80)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                MarqueeView(text: album.title, font: .headline, color: Theme.textPrimary)
                MarqueeView(text: album.artist, font: .subheadline, color: Theme.textSecondary)
                Text(L10n.songCount(count)).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 8)
        .frame(maxWidth: Theme.maxContentWidth)
    }
}

struct SectionHeader: View {
    let title: String
    let subtitle: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            
            Text(subtitle)
                .font(.system(size: 12, weight: .light))
                .foregroundStyle(Theme.textSecondary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: Theme.maxContentWidth, alignment: .leading)
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case info, sync, library, network, audio, notices

    var id: String { rawValue }

    var titleKey: String {
        switch self {
        case .info: "settings.section.info"
        case .sync: "settings.section.sync"
        case .library: "library.title"
        case .network: "settings.section.network"
        case .audio: "settings.section.audio"
        case .notices: "settings.section.about"
        }
    }

    var icon: String {
        switch self {
        case .info: "info.circle"
        case .sync: "desktopcomputer"
        case .library: "music.note.list"
        case .network: "network"
        case .audio: "waveform"
        case .notices: "bell"
        }
    }
}

struct SettingsView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var desktopSync: DesktopSyncController
    @ObservedObject var player: AudioPlayerViewModel
    @Binding var isShowing: Bool
    @State private var selectedSettingsTab = SettingsTab.info
    @State private var isShowingCacheDeletionConfirmation = false
    @State private var isShowingDesktopSync = false
    @StateObject private var remoteSources = RemoteMusicSourcesViewModel()
    @StateObject private var googleDrive = GoogleDriveConnectionController()
    @State private var isChoosingRemoteDirectory = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                settingsTabs
                List {
                    switch selectedSettingsTab {
                    case .info: infoSections
                    case .sync: syncSections
                    case .library: librarySections
                    case .network: networkSections
                    case .audio: audioSections
                    case .notices: noticesSections
                    }
                }
                .id(selectedSettingsTab)
            }
            .preferredColorScheme(Theme.appearance.colorScheme)
            .scrollContentBackground(.hidden)
            .background(AppBackground().ignoresSafeArea())
            .listStyle(.insetGrouped)
            .navigationTitle(L10n.tr("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(L10n.tr("common.close")) { isShowing = false } } }
            .onAppear {
                player.refreshAudioOutputPreferences()
                player.refreshPreparedAudioCacheStatistics()
                remoteSources.reload()
                Task { await googleDrive.refreshConnectionState() }
            }
            .fileImporter(
                isPresented: $isChoosingRemoteDirectory,
                allowedContentTypes: [.folder]
            ) { result in
                guard case .success(let url) = result else { return }
                if remoteSources.addDirectory(url) {
                    player.scanLocalLibrary()
                }
            }
            .alert(
                L10n.tr("settings.remote_sources.error.title"),
                isPresented: Binding(
                    get: { remoteSources.errorMessage != nil },
                    set: { if !$0 { remoteSources.errorMessage = nil } }
                )
            ) {
                Button(L10n.tr("common.close"), role: .cancel) {}
            } message: {
                Text(remoteSources.errorMessage ?? "")
            }
            .alert(
                L10n.tr("settings.google_drive.error.title"),
                isPresented: Binding(
                    get: { googleDrive.errorMessage != nil },
                    set: { if !$0 { googleDrive.errorMessage = nil } }
                )
            ) {
                Button(L10n.tr("common.close"), role: .cancel) {}
            } message: {
                Text(googleDrive.errorMessage ?? "")
            }
            .sheet(isPresented: $isShowingDesktopSync) {
                DesktopSyncView()
                    .environmentObject(desktopSync)
            }
            .confirmationDialog(
                L10n.tr("settings.audio_cache.clear_confirmation.title"),
                isPresented: $isShowingCacheDeletionConfirmation,
                titleVisibility: .visible
            ) {
                Button(L10n.tr("settings.audio_cache.clear"), role: .destructive) {
                    player.clearPreparedAudioCache()
                }
                Button(L10n.tr("common.cancel"), role: .cancel) {}
            } message: {
                Text(L10n.tr("settings.audio_cache.clear_confirmation.message"))
            }
        }
    }

    private var settingsTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(SettingsTab.allCases) { tab in
                        Button {
                            selectedSettingsTab = tab
                        } label: {
                            Label(L10n.tr(tab.titleKey), systemImage: tab.icon)
                                .font(.subheadline.weight(.semibold))
                                .fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 14)
                                .frame(minHeight: 44)
                                .foregroundStyle(selectedSettingsTab == tab ? Theme.onAccent : Theme.textPrimary)
                                .background(selectedSettingsTab == tab ? player.accentColor : Theme.secondaryBackground, in: Capsule())
                                .overlay(Capsule().strokeBorder(Theme.border, lineWidth: selectedSettingsTab == tab ? 0 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings.tab.\(tab.rawValue)")
                        .accessibilityAddTraits(selectedSettingsTab == tab ? .isSelected : [])
                        .id(tab)
                    }
                }
                .padding(.vertical, 4)
            }
            .scrollIndicators(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .onChange(of: selectedSettingsTab) { _, tab in
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
                    proxy.scrollTo(tab, anchor: .center)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private var infoSections: some View {
        Section(L10n.tr("settings.section.info")) {
            LabeledContent(L10n.tr("settings.access_status"), value: player.mediaLibraryAccess.description)
            LabeledContent(L10n.tr("settings.current_track"), value: player.trackTitle)
        }
        .listRowBackground(Theme.secondaryBackground)
    }

    private var syncSections: some View {
        Section(L10n.tr("settings.section.sync")) {
            Button {
                isShowingDesktopSync = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "desktopcomputer.and.arrow.down")
                        .foregroundStyle(player.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L10n.tr("settings.sync.title"))
                            .foregroundStyle(Theme.textPrimary)
                        Text(L10n.tr("settings.sync.detail"))
                            .font(.appCaption())
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .listRowBackground(Theme.secondaryBackground)
    }

    private var librarySections: some View {
        Section(L10n.tr("library.title")) {
            Button {
                player.reloadSystemLibrary()
            } label: {
                LibraryActionLabel(
                    title: L10n.tr("settings.reload_library"),
                    detail: L10n.tr("settings.library_feedback.system_detail"),
                    workingTitle: L10n.tr("settings.system_library_loading"),
                    feedback: player.systemLibraryFeedback,
                    accentColor: player.accentColor
                )
            }
            .disabled(player.systemLibraryFeedback == .working)

            Button {
                player.scanLocalLibraryFromSettings()
            } label: {
                LibraryActionLabel(
                    title: L10n.tr("settings.scan_local_library"),
                    detail: L10n.tr("settings.library_feedback.local_detail"),
                    workingTitle: L10n.tr("settings.local_library_scanning"),
                    feedback: player.localLibraryFeedback,
                    accentColor: player.accentColor
                )
            }
            .disabled(player.localLibraryFeedback == .working)

            if let loadingMessage = player.libraryLoadingMessage {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                        .tint(player.accentColor)
                    Text(loadingMessage)
                        .font(.appCaption())
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 4)
            }
        }
        .listRowBackground(Theme.secondaryBackground)
    }

    private var networkSections: some View {
        Group {
            Section(L10n.tr("settings.section.network")) {
                Button {
                    isChoosingRemoteDirectory = true
                } label: {
                    Label(
                        L10n.tr("settings.remote_sources.add"),
                        systemImage: "externaldrive.connected.to.line.below"
                    )
                }
                .disabled(player.isPlaying || player.isPlaybackStarting)

                ForEach(remoteSources.directories) { directory in
                    HStack(spacing: 12) {
                        Image(systemName: "network")
                            .foregroundStyle(player.accentColor)
                        Text(directory.displayName)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            if remoteSources.removeDirectory(id: directory.id) {
                                player.scanLocalLibrary()
                            }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(L10n.tr("settings.remote_sources.remove"))
                    }
                }

                Text(L10n.tr("settings.remote_sources.footer"))
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.secondaryBackground)

            Section(L10n.tr("settings.google_drive.section")) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.icloud")
                        .foregroundStyle(player.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(googleDrive.isConnected
                             ? L10n.tr("settings.google_drive.connected")
                             : L10n.tr("settings.google_drive.disconnected"))
                            .foregroundStyle(Theme.textPrimary)
                        if googleDrive.isConnected {
                            Text(L10n.tr("settings.google_drive.track_count", googleDrive.trackCount))
                                .font(.appCaption())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    if googleDrive.isWorking { ProgressView().controlSize(.small) }
                }

                if googleDrive.isConnected {
                    Button(L10n.tr("settings.google_drive.refresh")) {
                        Task {
                            if await googleDrive.refreshLibrary() { player.scanLocalLibrary() }
                        }
                    }
                    Button(L10n.tr("settings.google_drive.disconnect"), role: .destructive) {
                        Task {
                            if await googleDrive.disconnect() { player.scanLocalLibrary() }
                        }
                    }
                } else {
                    Button(L10n.tr("settings.google_drive.connect")) {
                        Task {
                            if await googleDrive.connectAndSync() { player.scanLocalLibrary() }
                        }
                    }
                }

                Text(L10n.tr("settings.google_drive.footer"))
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(googleDrive.isWorking || player.isPlaying || player.isPlaybackStarting)
            .listRowBackground(Theme.secondaryBackground)
        }
    }

    private var audioSections: some View {
        Section(L10n.tr("settings.section.audio")) {
            AudioOutputSettingsRows(
                output: Binding(get: { player.audioOutputOverride }, set: { player.setAudioOutputOverride($0) }),
                compensationEnabled: Binding(get: { player.loudnessCompensationEnabled }, set: { player.setLoudnessCompensationEnabled($0) })
            )
            LabeledContent(
                L10n.tr("settings.upsampling_mode"),
                value: L10n.upsamplingModeTitle(player.upsamplingMode)
            )
            .foregroundStyle(Theme.textPrimary)
            Text(L10n.tr("settings.upsampling_footer"))
                .font(.appCaption())
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.tr("settings.audio_cache.title"))
                    .foregroundStyle(Theme.textPrimary)
                Text(player.preparedAudioCacheSummary)
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(role: .destructive) {
                isShowingCacheDeletionConfirmation = true
            } label: {
                HStack(spacing: 10) {
                    Text(L10n.tr("settings.audio_cache.clear"))
                    Spacer()
                    if player.isClearingPreparedAudioCache {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(
                player.isClearingPreparedAudioCache
                    || player.preparedAudioCacheStatistics.byteCount == 0
            )

            Text(L10n.tr("settings.audio_cache.footer"))
                .font(.appCaption())
                .foregroundStyle(Theme.textSecondary)
        }
        .listRowBackground(Theme.secondaryBackground)
    }

    private var noticesSections: some View {
        Section(L10n.tr("settings.section.about")) {
            Link(destination: URL(string: "https://apps.apple.com/jp/app/ongaku-desktop/id6807717764?mt=12")!) {
                Label("Ongaku Desktop", systemImage: "desktopcomputer")
            }
            Link(destination: URL(string: "https://xs927991.xsrv.jp/")!) {
                Label("MATSUSHIBA", systemImage: "globe")
            }
            Link("Cue", destination: URL(string: "https://cue.college/")!)
        }
        .listRowBackground(Theme.secondaryBackground)
    }
}

private struct LibraryActionLabel: View {
    let title: String
    let detail: String
    let workingTitle: String
    let feedback: LibraryActionFeedback
    let accentColor: Color

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                switch feedback {
                case .working:
                    ProgressView().tint(accentColor)
                case .completed:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                case .notice:
                    Image(systemName: "info.circle.fill").foregroundStyle(.orange)
                case .idle:
                    Image(systemName: "arrow.clockwise.circle").foregroundStyle(accentColor)
                }
            }
            .frame(width: 22, height: 22)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 6) {
                Text(feedback == .working ? workingTitle : title)
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.appCaption())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch feedback {
                case .completed(let count):
                    Text(L10n.tr("settings.library_feedback.completed", count))
                        .font(.appCaption())
                        .foregroundStyle(.green)
                        .fixedSize(horizontal: false, vertical: true)
                case .notice(let message):
                    Text(message)
                        .font(.appCaption())
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                default:
                    EmptyView()
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
        .sensoryFeedback(.success, trigger: feedback) { _, value in
            if case .completed = value { return true }
            return false
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            SettingsView(
                player: AudioPlayerViewModel(),
                isShowing: .constant(true)
            )
            .environmentObject(DesktopSyncController())
            .previewDevice("iPhone SE (3rd generation)")

            SettingsView(
                player: AudioPlayerViewModel(),
                isShowing: .constant(true)
            )
            .environmentObject(DesktopSyncController())
            .previewDevice("iPhone 16 Pro Max")
        }
    }
}

// MARK: - Custom Tab Bar

private struct CustomTabBar: View {
    @Binding var selectedTab: RootTab
    let accentColor: Color
    
    var onAppearance: () -> Void = {}
    
    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            // Appearance (formerly the Music shortcut)
            TabBarButton(
                icon: "circle.lefthalf.filled",
                title: L10n.tr("appearance.title"),
                isActive: false,
                accentColor: accentColor
            ) {
                onAppearance()
            }
            
            
            // Library
            TabBarButton(
                icon: "music.note.house.fill",
                title: L10n.tr("library.title"),
                isActive: selectedTab == .library,
                accentColor: accentColor
            ) { selectedTab = .library }
            
            
            TabBarButton(
                icon: "radio.fill",
                title: L10n.tr("tab.now_playing"),
                isActive: selectedTab == .nowPlaying,
                accentColor: accentColor
            ) { selectedTab = .nowPlaying }

            
            // Effects
            TabBarButton(
                icon: "waveform.path.ecg",
                title: L10n.tr("effects.title"),
                isActive: selectedTab == .effects,
                accentColor: accentColor
            ) { selectedTab = .effects }
            
            
            // Search
            TabBarButton(
                icon: "magnifyingglass",
                title: L10n.tr("search.title"),
                isActive: selectedTab == .search,
                accentColor: accentColor
            ) { selectedTab = .search }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background {
            if Theme.isRealistic {
                HardwarePanel(radius: 36)
            } else if #available(iOS 26.0, *) {
                Capsule(style: .circular)
                    .fill(.clear)
                    .glassEffect(.regular, in: Capsule(style: .circular))
            } else {
                Capsule(style: .circular)
                    .fill(Theme.secondaryBackground.opacity(0.86))
                    .background(.ultraThinMaterial, in: Capsule(style: .circular))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

private struct TabBarButton: View {
    let icon: String
    let title: String
    let isActive: Bool
    let accentColor: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 20, height: 20)
                
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(isActive ? accentColor : Theme.textSecondary.opacity(0.7))
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct CustomTabBar_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview.previewDevice("iPhone SE (3rd generation)")
            preview.previewDevice("iPhone 16 Pro Max")
        }
    }

    private static var preview: some View {
        Color.black
            .safeAreaInset(edge: .bottom) {
                CustomTabBar(selectedTab: .constant(.nowPlaying), accentColor: .orange)
            }
            .preferredColorScheme(Theme.appearance.colorScheme)
    }
}


private struct EffectsTabContent_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            preview.previewDevice("iPhone SE (3rd generation)")
            preview.previewDevice("iPhone 16 Pro Max")
        }
    }

    private static var preview: some View {
        NavigationStack {
            EffectsTabContent(player: AudioPlayerViewModel(), isPresented: true, shouldRenderControls: true, controlsRenderID: UUID())
        }
        .preferredColorScheme(Theme.appearance.colorScheme)
    }
}
